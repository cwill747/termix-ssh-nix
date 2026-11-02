{
  lib,
  stdenv,
  buildNpmPackage,
  fetchgit,
  nodejs_24,
  python3,
  makeWrapper,
  fetchurl,
  # The Termix source tree. Defaults to the pinned flake input but can be
  # overridden (e.g. with a local checkout) via `.override { src = ...; }`.
  src,
  # npmDepsHash for the npm dependency cache. Update with `nix build` and copy the
  # hash from the mismatch error, or run `prefetch-npm-deps package-lock.json`.
  npmDepsHash ? "sha256-hDPBAeSeOnPZHKfHlYwBPIbwjy8nO/QyG1d57X5Qz9M=",
  # Which bundled-plugin tier to ship. Mirrors upstream's Docker image
  # PLUGIN_PROFILE: minimal (only what the app needs to start), standard
  # (the default) or full.
  pluginProfile ? "standard",
}:

let
  nodejs = nodejs_24;

  profileTiers = {
    minimal = [ "minimal" ];
    standard = [
      "minimal"
      "standard"
    ];
    full = [
      "minimal"
      "standard"
      "full"
    ];
  };

  bundledPlugins =
    (builtins.fromJSON (builtins.readFile "${src}/docker/bundled-plugins.json")).plugins;

  selectedPlugins = builtins.filter (
    plugin: builtins.elem (plugin.tier or "full") profileTiers.${pluginProfile}
  ) bundledPlugins;

  # Upstream's build:plugins downloads each pinned .tmxplug from GitHub. Do that
  # as fixed-output derivations instead so the main build stays sandboxed and
  # offline, then seed the same cache file names the build script expects.
  pluginArtifacts = map (plugin: {
    inherit (plugin) id sha256;
    src = fetchurl {
      url = plugin.url;
      hash = builtins.convertHash {
        hash = "sha256:${plugin.sha256}";
        toHashFormat = "sri";
      };
    };
  }) selectedPlugins;

  seedPlugins = lib.concatMapStringsSep "\n" (plugin: ''
    install -m 0644 ${plugin.src} "node_modules/.cache/termix-bundled-plugins/${plugin.sha256}.tmxplug"
  '') pluginArtifacts;
in
buildNpmPackage {
  pname = "termix";
  # Keep in sync with upstream package.json; surfaced as the app VERSION at runtime.
  version = "26.11.0";

  inherit src npmDepsHash nodejs;

  # .npmrc sets legacy-peer-deps=true; mirror it for npm ci.
  npmFlags = [ "--legacy-peer-deps" ];

  # Two outputs from a single build/install: `out` holds the runnable backend
  # (dist/backend + pruned node_modules + nginx templates + a launcher), and
  # `frontend` holds the static Vite assets that nginx serves.
  outputs = [
    "out"
    "frontend"
  ];

  nativeBuildInputs = [
    python3 # node-gyp needs python3 to compile better-sqlite3
    makeWrapper
  ];

  # The Vite build is memory hungry; match the headroom the upstream Dockerfile uses.
  env.NODE_OPTIONS = "--max-old-space-size=4096";

  # Upstream's `npm run build` also stages the bundled plugins by downloading
  # their pinned .tmxplug artifacts. Fill the build script's download cache from
  # the fixed-output derivations above first.
  preBuild = ''
      mkdir -p node_modules/.cache/termix-bundled-plugins
    ${seedPlugins}
  '';

  # `npm run build` = vite build (-> dist) + tsc -p tsconfig.node.json (-> dist/backend)
  # + copy src/backend/package.json into dist/backend (marks it ESM).
  buildPhase = ''
    runHook preBuild
    npm run build
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    # --- frontend output: the static SPA assets ---
    mkdir -p $frontend
    cp -r dist/* $frontend/
    # dist/ also contains the compiled backend and plugins; nginx only serves
    # the SPA assets, while the backend reads those from its own output.
    rm -rf $frontend/backend $frontend/plugins

    # --- backend output ---
    app=$out/lib/termix
    mkdir -p $app/dist
    cp -r dist/backend $app/dist/backend
    cp -r dist/plugins $app/dist/plugins
    cp package.json $app/package.json

    # The plugin SDK is an npm workspace linked from node_modules, and both the
    # core backend and bundled plugins import it at runtime. Ship the workspace
    # package (including its built dist and CLI) next to the copied
    # node_modules, like upstream's Dockerfile.
    mkdir -p $app/packages/plugin-sdk
    cp -r packages/plugin-sdk/. $app/packages/plugin-sdk/
    rm -rf $app/packages/plugin-sdk/node_modules

    # Prune dev dependencies, keeping the compiled better-sqlite3 binding.
    npm prune --omit=dev --legacy-peer-deps
    cp -r node_modules $app/node_modules

    # Bundle Termix's own nginx templates for the NixOS module to consume.
    mkdir -p $out/share/termix/nginx
    cp docker/nginx.conf      $out/share/termix/nginx/nginx.conf.template
    cp docker/nginx-https.conf $out/share/termix/nginx/nginx-https.conf.template

    # Launcher: run the backend starter with the pinned node, resolving node_modules
    # from the bundle and reading package.json (VERSION) from the app dir.
    makeWrapper ${nodejs}/bin/node $out/bin/termix-backend \
      --add-flags "$app/dist/backend/backend/starter.js" \
      --chdir "$app" \
      --set NODE_ENV production

    runHook postInstall
  '';

  # Skip buildNpmPackage's default `npm prune`/rebuild in installPhase (we do our own).
  dontNpmPrune = true;
  dontNpmInstall = true;

  passthru = {
    inherit nodejs;
    nginxTemplates = "share/termix/nginx";
  };

  meta = {
    description = "Termix SSH/terminal/remote-desktop manager (backend + frontend, packaged for Nix)";
    homepage = "https://github.com/Termix-SSH/Termix";
    license = lib.licenses.asl20;
    platforms = lib.platforms.linux;
    mainProgram = "termix-backend";
  };
}
