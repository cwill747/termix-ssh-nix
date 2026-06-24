{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.termix;

  inherit (lib)
    mkEnableOption
    mkOption
    mkIf
    types
    optional
    optionals
    filterAttrs
    mapAttrs
    literalExpression
    mkPackageOption
    ;

  boolStr = b: if b then "true" else "false";

  # Resolve the termix package. If the flake overlay is applied, pkgs.termix exists;
  # otherwise the user must set services.termix.package explicitly.
  defaultPackage = pkgs.termix or null;

  nginxPkg = cfg.nginx.package;

  # Where the writable, base-path-patched copy of the SPA is staged at runtime.
  htmlDir = "/run/termix-nginx/html";

  # Backend environment, mirroring Termix's documented env vars. Null values are
  # dropped so they fall back to Termix's own defaults / auto-generation.
  backendEnv = filterAttrs (_: v: v != null) (
    {
      NODE_ENV = "production";
      DATA_DIR = cfg.dataDir;
      PORT = toString cfg.port;
      LOG_LEVEL = cfg.logLevel;
      ENABLE_GUACAMOLE = boolStr cfg.guacamole.enable;
      GUACD_HOST = cfg.guacamole.host;
      GUACD_PORT = toString cfg.guacamole.port;
      DB_FILE_ENCRYPTION = boolStr cfg.database.encrypt;
      ALLOW_REGISTRATION = boolStr cfg.allowRegistration;
      ALLOW_PASSWORD_LOGIN = boolStr cfg.allowPasswordLogin;
      ALLOW_PASSWORD_RESET = boolStr cfg.allowPasswordReset;
      ENABLE_SSL = boolStr cfg.ssl.enable;
      SSL_PORT = toString cfg.ssl.port;
      SSL_DOMAIN = cfg.ssl.domain;
      SSL_CERT_PATH = cfg.ssl.certPath;
      SSL_KEY_PATH = cfg.ssl.keyPath;
      CORS_ALLOWED_ORIGINS =
        if cfg.corsAllowedOrigins == [ ] then null else lib.concatStringsSep "," cfg.corsAllowedOrigins;
      BASE_PATH = cfg.basePath;
      # OIDC
      OIDC_CLIENT_ID = cfg.oidc.clientId;
      OIDC_CLIENT_SECRET = cfg.oidc.clientSecret;
      OIDC_ISSUER_URL = cfg.oidc.issuerUrl;
      OIDC_AUTHORIZATION_URL = cfg.oidc.authorizationUrl;
      OIDC_TOKEN_URL = cfg.oidc.tokenUrl;
      OIDC_USERINFO_URL = cfg.oidc.userinfoUrl;
      OIDC_SCOPES = cfg.oidc.scopes;
      OIDC_IDENTIFIER_PATH = cfg.oidc.identifierPath;
      OIDC_NAME_PATH = cfg.oidc.namePath;
      OIDC_GROUP_CLAIM = cfg.oidc.groupClaim;
      OIDC_ALLOWED_USERS =
        if cfg.oidc.allowedUsers == [ ] then null else lib.concatStringsSep "," cfg.oidc.allowedUsers;
      OIDC_ADMIN_GROUP = cfg.oidc.adminGroup;
    }
    // (mapAttrs (_: toString) cfg.extraEnvironment)
  );

  # nginx env consumed by the upstream template's envsubst pass.
  nginxEnv = {
    PORT = toString cfg.port;
    SSL_PORT = toString cfg.ssl.port;
    SSL_CERT_PATH = cfg.ssl.certPath;
    SSL_KEY_PATH = cfg.ssl.keyPath;
  };

  templateFile = if cfg.ssl.enable then "nginx-https.conf.template" else "nginx.conf.template";

  # Termix execs opkssh as `${DATA_DIR}/opkssh/opkssh-<os>-<arch>`. Match its naming.
  opksshAsset =
    if pkgs.stdenv.hostPlatform.isAarch64 then "opkssh-linux-arm64" else "opkssh-linux-amd64";

  # Pre-place the nixpkgs opkssh binary so Termix skips its runtime GitHub download.
  # Writing a matching version.txt prevents needless auto-update attempts.
  opksshSetup = pkgs.writeShellApplication {
    name = "termix-opkssh-setup";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      dir='${cfg.dataDir}/opkssh'
      mkdir -p "$dir"
      ln -sfn '${cfg.opkssh.package}/bin/opkssh' "$dir/${opksshAsset}"
      printf 'v%s\n' '${cfg.opkssh.package.version}' > "$dir/version.txt"
    '';
  };

  # Builds /run/termix-nginx/nginx.conf from Termix's bundled template and stages a
  # writable, BASE_PATH-patched copy of the SPA. Mirrors docker/entrypoint.sh.
  nginxPreStart = pkgs.writeShellApplication {
    name = "termix-nginx-prestart";
    runtimeInputs = [
      pkgs.gettext
      pkgs.openssl
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnused
    ];
    text = ''
      runtime="''${RUNTIME_DIRECTORY:-/run/termix-nginx}"
      conf="$runtime/nginx.conf"

      # 1. Render the template (PORT/SSL_PORT/SSL_CERT_PATH/SSL_KEY_PATH) and rewrite
      #    the template's hardcoded container paths to our Nix/runtime paths.
      export PORT='${nginxEnv.PORT}'
      export SSL_PORT='${nginxEnv.SSL_PORT}'
      export SSL_CERT_PATH='${nginxEnv.SSL_CERT_PATH}'
      export SSL_KEY_PATH='${nginxEnv.SSL_KEY_PATH}'
      # shellcheck disable=SC2016  # envsubst takes a literal list of var names
      envsubst '$PORT $SSL_PORT $SSL_CERT_PATH $SSL_KEY_PATH' \
        < ${cfg.package}/share/termix/nginx/${templateFile} > "$conf"
      sed -i \
        -e "s|/app/html|${htmlDir}|g" \
        -e "s|/app/data|${cfg.dataDir}|g" \
        -e "s|/tmp/nginx|$runtime|g" \
        -e "s|/etc/nginx/mime.types|${nginxPkg}/conf/mime.types|g" \
        "$conf"

      # 2. Stage a writable copy of the SPA so we can patch the base-path placeholders
      #    (the store copy is read-only).
      rm -rf "${htmlDir}"
      mkdir -p "${htmlDir}"
      cp -r ${cfg.package.frontend}/. "${htmlDir}/"
      chmod -R u+w "${htmlDir}"

      base='${if cfg.basePath == null then "" else cfg.basePath}'
      base="''${base%/}"
      if [ -n "$base" ]; then
        find "${htmlDir}" -name index.html -exec \
          sed -i "s|window.__TERMIX_BASE_PATH__ = \"\"|window.__TERMIX_BASE_PATH__ = \"$base\"|g" {} +
        find "${htmlDir}" -name sw.js -exec sed -i "s|__TERMIX_SW_BASE_PATH__|$base|g" {} +
      else
        find "${htmlDir}" -name sw.js -exec sed -i "s|__TERMIX_SW_BASE_PATH__||g" {} +
      fi

      # 3. Self-signed certs for ssl.enable when none are present (matches entrypoint).
      ${lib.optionalString cfg.ssl.enable ''
        if [ ! -f '${cfg.ssl.certPath}' ] || [ ! -f '${cfg.ssl.keyPath}' ]; then
          mkdir -p "$(dirname '${cfg.ssl.certPath}')" "$(dirname '${cfg.ssl.keyPath}')"
          openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
            -keyout '${cfg.ssl.keyPath}' -out '${cfg.ssl.certPath}' \
            -subj "/CN=${cfg.ssl.domain}" \
            -addext "subjectAltName=DNS:${cfg.ssl.domain},DNS:localhost,IP:127.0.0.1"
          chmod 600 '${cfg.ssl.keyPath}'
        fi
      ''}

      # Validate the generated config before nginx starts (-e points the bootstrap
      # error log at the runtime dir instead of nginx's unwritable compiled-in path).
      ${nginxPkg}/bin/nginx -t -e "$runtime/error.log" -c "$conf"
    '';
  };
in
{
  options.services.termix = {
    enable = mkEnableOption "Termix SSH/terminal/remote-desktop manager";

    package = mkOption {
      type = types.package;
      default = defaultPackage;
      defaultText = literalExpression "pkgs.termix";
      description = "The Termix package to run (provided by this flake's overlay).";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "HTTP port the Termix web UI (nginx) listens on.";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open the web UI port(s) in the firewall.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/termix";
      description = ''
        Persistent data directory: SQLite database, auto-generated secrets
        (`.env`), uploads, SSL certs.
      '';
    };

    user = mkOption {
      type = types.str;
      default = "termix";
      description = "User the Termix services run as.";
    };

    group = mkOption {
      type = types.str;
      default = "termix";
      description = "Group the Termix services run as.";
    };

    logLevel = mkOption {
      type = types.enum [
        "debug"
        "info"
        "warn"
        "error"
        "success"
      ];
      default = "info";
      description = "Backend log level (LOG_LEVEL).";
    };

    environmentFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/run/secrets/termix.env";
      description = ''
        Optional systemd EnvironmentFile for injecting secrets (JWT_SECRET,
        DATABASE_KEY, ENCRYPTION_KEY, ...) from sops/agenix. If unset, Termix
        auto-generates and persists them into `''${dataDir}/.env`.
      '';
    };

    extraEnvironment = mkOption {
      type = types.attrsOf (types.either types.str types.int);
      default = { };
      example = literalExpression ''{ INTERNAL_AUTH_TOKEN_TTL = "3600"; }'';
      description = "Extra environment variables passed verbatim to the backend (escape hatch for any Termix env var).";
    };

    database.encrypt = mkOption {
      type = types.bool;
      default = true;
      description = "Encrypt the SQLite database file at rest (DB_FILE_ENCRYPTION).";
    };

    allowRegistration = mkOption {
      type = types.bool;
      default = true;
      description = "Allow new user registration (ALLOW_REGISTRATION).";
    };

    allowPasswordLogin = mkOption {
      type = types.bool;
      default = true;
      description = "Allow password-based login (ALLOW_PASSWORD_LOGIN).";
    };

    allowPasswordReset = mkOption {
      type = types.bool;
      default = true;
      description = "Allow password reset (ALLOW_PASSWORD_RESET).";
    };

    corsAllowedOrigins = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "https://termix.example.com" ];
      description = "Allowed CORS origins (CORS_ALLOWED_ORIGINS).";
    };

    basePath = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "/termix";
      description = "URL path prefix when behind a reverse proxy (BASE_PATH).";
    };

    ssl = {
      enable = mkEnableOption "HTTPS on Termix's own nginx (self-signed cert generated if absent)";
      port = mkOption {
        type = types.port;
        default = 8443;
        description = "HTTPS port (SSL_PORT).";
      };
      domain = mkOption {
        type = types.str;
        default = "localhost";
        description = "Domain/CN for the self-signed certificate (SSL_DOMAIN).";
      };
      certPath = mkOption {
        type = types.path;
        default = "${cfg.dataDir}/ssl/termix.crt";
        defaultText = literalExpression ''"''${config.services.termix.dataDir}/ssl/termix.crt"'';
        description = "TLS certificate path (SSL_CERT_PATH).";
      };
      keyPath = mkOption {
        type = types.path;
        default = "${cfg.dataDir}/ssl/termix.key";
        defaultText = literalExpression ''"''${config.services.termix.dataDir}/ssl/termix.key"'';
        description = "TLS private key path (SSL_KEY_PATH).";
      };
    };

    guacamole = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable remote-desktop (RDP/VNC/Telnet) support via guacd (ENABLE_GUACAMOLE).";
      };
      manageDaemon = mkOption {
        type = types.bool;
        default = true;
        description = "Run a local guacd via services.guacamole-server. Disable to point at an external guacd.";
      };
      host = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "guacd host Termix connects to (GUACD_HOST), and the local guacd bind address when managed.";
      };
      port = mkOption {
        type = types.port;
        default = 4822;
        description = "guacd port (GUACD_PORT).";
      };
    };

    opkssh = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = ''
          Pre-place the nixpkgs opkssh binary into the data dir so Termix uses it
          for OPKSSH authentication instead of downloading it from GitHub at
          runtime. (Online instances may still auto-update it into the data dir.)
        '';
      };
      package = mkPackageOption pkgs "opkssh" { };
    };

    oidc = {
      clientId = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_CLIENT_ID.";
      };
      clientSecret = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_CLIENT_SECRET (prefer environmentFile for this).";
      };
      issuerUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_ISSUER_URL.";
      };
      authorizationUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_AUTHORIZATION_URL.";
      };
      tokenUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_TOKEN_URL.";
      };
      userinfoUrl = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_USERINFO_URL.";
      };
      scopes = mkOption {
        type = types.nullOr types.str;
        default = null;
        example = "openid email profile";
        description = "OIDC_SCOPES.";
      };
      identifierPath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_IDENTIFIER_PATH.";
      };
      namePath = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_NAME_PATH.";
      };
      groupClaim = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_GROUP_CLAIM.";
      };
      allowedUsers = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "OIDC_ALLOWED_USERS (comma-joined).";
      };
      adminGroup = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC_ADMIN_GROUP.";
      };
    };

    nginx = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Run Termix's dedicated nginx (serves the SPA and proxies the internal services). Disable to front Termix with your own proxy to the backend ports.";
      };
      package = mkPackageOption pkgs "nginx" { };
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.package != null;
        message = "services.termix.package is null; apply this flake's overlay or set services.termix.package explicitly.";
      }
    ];

    users.users = mkIf (cfg.user == "termix") {
      termix = {
        isSystemUser = true;
        group = cfg.group;
        home = cfg.dataDir;
      };
    };
    users.groups = mkIf (cfg.group == "termix") { termix = { }; };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${cfg.user} ${cfg.group} - -"
    ];

    # Local guacd, when managed.
    services.guacamole-server = mkIf (cfg.guacamole.enable && cfg.guacamole.manageDaemon) {
      enable = true;
      host = cfg.guacamole.host;
      port = cfg.guacamole.port;
    };

    systemd.services.termix = {
      description = "Termix backend";
      wantedBy = [ "multi-user.target" ];
      after = [
        "network.target"
      ]
      ++ optional (cfg.guacamole.enable && cfg.guacamole.manageDaemon) "guacamole-server.service";
      wants = optional (cfg.guacamole.enable && cfg.guacamole.manageDaemon) "guacamole-server.service";
      environment = backendEnv;
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = "${cfg.package}/lib/termix";
        ExecStartPre = optional cfg.opkssh.enable "${opksshSetup}/bin/termix-opkssh-setup";
        ExecStart = "${cfg.package}/bin/termix-backend";
        EnvironmentFile = optional (cfg.environmentFile != null) cfg.environmentFile;
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening.
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        ReadWritePaths = [ cfg.dataDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    systemd.services.termix-nginx = mkIf cfg.nginx.enable {
      description = "Termix nginx (SPA + reverse proxy)";
      wantedBy = [ "multi-user.target" ];
      after = [ "termix.service" ];
      wants = [ "termix.service" ];
      serviceConfig = {
        Type = "simple";
        User = cfg.user;
        Group = cfg.group;
        RuntimeDirectory = "termix-nginx";
        RuntimeDirectoryMode = "0750";
        ExecStartPre = "${nginxPreStart}/bin/termix-nginx-prestart";
        ExecStart = "${nginxPkg}/bin/nginx -c /run/termix-nginx/nginx.conf -e /run/termix-nginx/error.log -g 'daemon off;'";
        ExecReload = "${nginxPkg}/bin/nginx -c /run/termix-nginx/nginx.conf -e /run/termix-nginx/error.log -s reload";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        # nginx binds the web port (and ssl port); allow low ports if configured.
        AmbientCapabilities = optionals (cfg.port < 1024 || (cfg.ssl.enable && cfg.ssl.port < 1024)) [
          "CAP_NET_BIND_SERVICE"
        ];
        CapabilityBoundingSet = optionals (cfg.port < 1024 || (cfg.ssl.enable && cfg.ssl.port < 1024)) [
          "CAP_NET_BIND_SERVICE"
        ];
        ReadWritePaths = [ cfg.dataDir ];
      };
    };

    networking.firewall.allowedTCPPorts = optionals cfg.openFirewall (
      [ cfg.port ] ++ optional cfg.ssl.enable cfg.ssl.port
    );
  };
}
