# termix-ssh-nix

A Nix flake that packages [Termix](https://github.com/Termix-SSH/Termix) — a
self-hosted SSH / terminal / remote-desktop manager — and runs it as a NixOS
service **without Docker**.

It tracks the **latest commit** of `Termix-SSH/Termix`, builds the frontend and
backend as Nix derivations, and ships a NixOS module that wires up Termix's own
nginx reverse proxy plus a `guacd` daemon for RDP/VNC/Telnet — configurable
entirely from your NixOS config.

## Build targets

| Target | Contents |
|---|---|
| `nix build .#termix` (default) | Runnable backend bundle: `dist/backend`, pruned `node_modules` (compiled `better-sqlite3`), nginx templates, and a `termix-backend` launcher. |
| `nix build .#termix-backend` | Same as `.#termix`. |
| `nix build .#termix-frontend` | Static Vite SPA assets (the `frontend` output). |

`nix run .#termix` (or `result/bin/termix-backend`) starts the backend directly;
it auto-generates its secrets into `$DATA_DIR/.env` on first run.

## NixOS usage

```nix
{
  inputs.termix.url = "github:youruser/termix-ssh-nix";
  # inputs.termix.inputs.nixpkgs.follows = "nixpkgs"; # optional

  outputs = { nixpkgs, termix, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        termix.nixosModules.default
        ({ ... }: {
          nixpkgs.overlays = [ termix.overlays.default ];

          services.termix = {
            enable = true;
            port = 8080;
            openFirewall = true;
            # guacd (RDP/VNC/Telnet) is managed and enabled by default.
          };
        })
      ];
    };
  };
}
```

Then visit `http://myhost:8080`.

### Configuration

Most Termix environment variables are exposed as options. Highlights:

- **Core**: `port`, `dataDir` (default `/var/lib/termix`), `user`, `group`,
  `logLevel`, `openFirewall`.
- **Database**: `database.encrypt` (encrypt SQLite at rest, default on).
- **Auth**: `allowRegistration`, `allowPasswordLogin`, `allowPasswordReset`.
- **TLS** (Termix's own nginx): `ssl.enable`, `ssl.port`, `ssl.domain`,
  `ssl.certPath`, `ssl.keyPath` (a self-signed cert is generated if absent).
- **Guacamole**: `guacamole.enable` (default true), `guacamole.manageDaemon`
  (run a local guacd, default true), `guacamole.host`, `guacamole.port`.
- **OIDC/SSO**: `oidc.{clientId,clientSecret,issuerUrl,authorizationUrl,tokenUrl,
  userinfoUrl,scopes,identifierPath,namePath,groupClaim,allowedUsers,adminGroup}`.
- **Reverse proxy**: `basePath`, `corsAllowedOrigins`.
- **OPKSSH**: `opkssh.enable` (default true) pre-places the nixpkgs `opkssh`
  binary so Termix doesn't download it from GitHub at runtime; `opkssh.package`
  overrides it.
- **Escape hatch**: `extraEnvironment` (attrset) sets any Termix env var verbatim.

### Secrets

By default Termix auto-generates `JWT_SECRET`, `DATABASE_KEY`, `ENCRYPTION_KEY`,
etc. into `${dataDir}/.env` on first start (zero config). To manage them with
sops/agenix instead, point `environmentFile` at a systemd `EnvironmentFile`:

```nix
services.termix.environmentFile = "/run/secrets/termix.env";
```

### Pointing at an external guacd

```nix
services.termix.guacamole = {
  manageDaemon = false;       # don't run a local guacd
  host = "guacd.internal";
  port = 4822;
};
```

### Fronting with your own reverse proxy

Set `services.termix.nginx.enable = false` and proxy to Termix's internal
services yourself (the backend listens on `127.0.0.1:30001-30010`; see Termix's
`docker/nginx.conf` for the route map). Otherwise the bundled nginx serves the
SPA and proxies everything on `services.termix.port`.

## Updating Termix

```sh
nix flake update termix-src   # bump to the latest Termix commit
nix build .#termix            # rebuild; refresh npmDepsHash if the lockfile changed
```

If `package-lock.json` changed upstream, the build will fail with a hash
mismatch — copy the suggested `sha256-…` into `npmDepsHash` in
`pkgs/termix.nix` (or compute it with
`nix run nixpkgs#prefetch-npm-deps -- path/to/package-lock.json`).

## Testing

`nix build .#checks.x86_64-linux.vm` runs a NixOS VM integration test that boots
the service, guacd, and nginx, and asserts the SPA and API are reachable.

## Notes

- Native build: only `better-sqlite3` is compiled (via node-gyp). The
  `guacamole-lite` runtime patch for guacd 1.6.0 is applied during the build.
- `opkssh` (for OPKSSH auth) is provided from nixpkgs and symlinked into the data
  dir at startup, so a fresh instance works offline without the GitHub download.
  An online Termix may still auto-update it into the (writable) data dir.
- Electron desktop builds, flatpak, and ACME/certbot automation from the
  upstream Docker image are out of scope.

## License

[Apache-2.0](./LICENSE). Termix itself is also Apache-2.0.
