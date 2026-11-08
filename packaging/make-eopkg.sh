#!/bin/sh
# Builds an installable .eopkg from this folder with solbuild (a clean Solus
# build container), without needing a published release.
#
# One-time setup:
#     sudo eopkg it solbuild
#     sudo solbuild init
#
# Then:
#     ./packaging/make-eopkg.sh
#     sudo eopkg it dist/budgie-classic-alttab-switcher-*.eopkg
#
# SPDX-License-Identifier: GPL-2.0-or-later
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
name=budgie-classic-alttab-switcher
version=$(sed -n "s/^ *version: *'\([^']*\)'.*/\1/p" "$here/meson.build" | head -n1)
release=${RELEASE:-1}
dist="$here/dist"
tarball="$name-$version.tar.gz"

command -v solbuild >/dev/null || {
    echo "solbuild is not installed. Run:  sudo eopkg it solbuild && sudo solbuild init" >&2
    exit 1
}

mkdir -p "$dist"
rm -f "$dist"/*.eopkg "$dist/$tarball"

echo ">> Packing source $version"
tar -C "$(dirname "$here")" \
    --exclude="$(basename "$here")/build" \
    --exclude="$(basename "$here")/dist" \
    --exclude="$(basename "$here")/.git" \
    --transform "s,^$(basename "$here"),$name-$version," \
    -czf "$dist/$tarball" "$(basename "$here")"
sha=$(sha256sum "$dist/$tarball" | cut -d' ' -f1)

echo ">> Writing package.yml"
sed -e "s|^version *:.*|version    : $version|" \
    -e "s|^release *:.*|release    : $release|" \
    -e "s|^    - https://.*\.tar\.gz : .*|    - file://$dist/$tarball : $sha|" \
    "$here/packaging/package.yml" > "$dist/package.yml"

echo ">> Building with solbuild (asks for your password)"
cd "$dist"
sudo solbuild build package.yml

echo
echo "Done. Install with:"
ls "$dist"/*.eopkg | grep -v -- '-dbginfo-' | sed 's/^/    sudo eopkg it /'
