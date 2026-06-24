{
  lib,
  stdenv,
  buildNpmPackage,
  fetchgit,
  nodejs_24,
  python3,
  makeWrapper,
  # The Termix source tree. Defaults to the pinned flake input but can be
  # overridden (e.g. with a local checkout) via `.override { src = ...; }`.
  src,
  # npmDepsHash for the npm dependency cache. Update with `nix build` and copy the
  # hash from the mismatch error, or run `prefetch-npm-deps package-lock.json`.
  npmDepsHash ? "sha256-uXE7M8qRldFNCqfJwNkERqNdF3JXDcGltizECA3Ck2A=",
}:

let
  nodejs = nodejs_24;
in
buildNpmPackage {
  pname = "termix";
  # Keep in sync with upstream package.json; surfaced as the app VERSION at runtime.
  version = "2.4.1";

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

  # Upstream's postinstall runs Electron-oriented patches we don't need. The one we
  # *do* need at runtime is patch-guacamole-lite (guacd 1.6.0 protocol support); run
  # it explicitly before building. (Native better-sqlite3 is compiled by npm ci's
  # own install scripts, which buildNpmPackage runs.)
  preBuild = ''
    node scripts/patch-guacamole-lite.cjs || true
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
    # dist/ also contains the compiled backend before pruning; drop it from frontend.
    rm -rf $frontend/backend

    # --- backend output ---
    app=$out/lib/termix
    mkdir -p $app/dist
    cp -r dist/backend $app/dist/backend
    cp package.json $app/package.json

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
