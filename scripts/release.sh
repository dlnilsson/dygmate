#!/usr/bin/env sh
# Build and package release artifacts locally, mirroring .github/workflows/release.yml.
# Prints SHA256 hashes for the winget manifest.
# Usage: scripts/release.sh [version]
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"

version=${1:-$(sed -n 's/^ *\.version *= *"\([^"]*\)".*/\1/p' build.zig.zon)}
[ -n "$version" ] || { echo "error: could not read .version from build.zig.zon" >&2; exit 1; }

# make_zip <out.zip> <files...> — files end up at the archive root (winget
# NestedInstallerFiles requirement); falls back to python where zip is absent.
make_zip() {
    if command -v zip >/dev/null 2>&1; then
        zip -j "$@"
    elif python3 -c 'import zipfile' >/dev/null 2>&1; then
        python3 -m zipfile -c "$@"
    elif python -c 'import zipfile' >/dev/null 2>&1; then
        python -m zipfile -c "$@"
    else
        echo "error: need 'zip' or python to create the zip archive" >&2
        return 1
    fi
}

zig build release

mkdir -p dist
(cd zig-out/windows && make_zip "$root/dist/dygmate-$version-windows-x86_64.zip" dygmate.exe dygmate-tray.exe)
tar -czf "dist/dygmate-$version-linux-x86_64.tar.gz" -C zig-out/linux dygmate dygmate-tray

cd dist
sha256sum "dygmate-$version-windows-x86_64.zip" "dygmate-$version-linux-x86_64.tar.gz" | tee SHA256SUMS.txt
