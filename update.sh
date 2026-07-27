#!/usr/bin/env bash
set -euo pipefail

REPO="Termix-SSH/Termix"
ROOT="$(cd "$(dirname "$0")" && pwd)"
PKG_NIX="$ROOT/pkgs/termix.nix"
FAKE_HASH="sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

extract_hash() {
  grep "got:" <<<"$1" | head -1 | awk '{print $2}'
}

# Portable in-place sed (macOS needs -i '', GNU needs -i).
sedi() {
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$@"
  else
    sed -i '' "$@"
  fi
}

cd "$ROOT"

if [[ ${1:-} ]]; then
  tag="${1#refs/tags/}"
else
  tag=$(gh release view --repo "$REPO" --json tagName -q '.tagName')
fi

echo "==> Updating termix-src to latest release ${tag}"
nix flake lock --override-input termix-src "github:${REPO}?ref=${tag}"

src_path=$(nix eval --raw .#termix.src)
version=$(jq -r '.version' "$src_path/package.json")
rev=$(jq -r '.nodes."termix-src".locked.rev' flake.lock)

echo "==> Pinned ${REPO} at ${rev}"
echo "==> Release tag ${tag}"
echo "==> Syncing package version to ${version}"
sedi "s|version = \".*\";|version = \"${version}\";|" "$PKG_NIX"

echo "==> Checking npm dependency hash..."
if nix build .#termix --no-link --print-build-logs; then
  echo "==> Existing npmDepsHash is valid"
else
  echo "==> Refreshing npmDepsHash..."
  sedi "s|npmDepsHash ? \"sha256-.*\"|npmDepsHash ? \"${FAKE_HASH}\"|" "$PKG_NIX"

  build_out=$(nix build .#termix --no-link --print-build-logs 2>&1 || true)
  npm_hash=$(extract_hash "$build_out")
  if [[ -z "$npm_hash" ]]; then
    echo "ERROR: couldn't extract npmDepsHash from build output:" >&2
    echo "$build_out" >&2
    exit 1
  fi

  echo "    npmDepsHash: ${npm_hash}"
  sedi "s|npmDepsHash ? \"${FAKE_HASH}\"|npmDepsHash ? \"${npm_hash}\"|" "$PKG_NIX"
fi

echo "==> Running full build..."
nix build .#termix --no-link --print-build-logs

echo "==> Success: termix ${version} (${rev}) built."
