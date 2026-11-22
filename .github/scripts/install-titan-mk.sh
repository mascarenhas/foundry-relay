#!/usr/bin/env bash
# Install titan-mk at one exact commit into the Titan SDK through LuaRocks and
# check its published provider.
#
# Run with the Titan SDK's bin directory first on PATH and TITAN_PREFIX naming
# that SDK. MK_REPO (owner/name) and MK_COMMIT (a full commit SHA) select the
# source. On Windows (MSYS2 CLANG64) also export LUAROCKS_CONFIG.
# Usage: install-titan-mk.sh ABSENT_WORKSPACE
set -euxo pipefail

workspace=${1:?usage: install-titan-mk.sh ABSENT_WORKSPACE}
sdk=${TITAN_PREFIX:?set TITAN_PREFIX to the Titan SDK}
repo=${MK_REPO:?set MK_REPO to the titan-mk repository (owner/name)}
commit=${MK_COMMIT:?set MK_COMMIT to a full titan-mk commit SHA}
[[ $commit =~ ^[0-9a-f]{40}$ ]]
lib=$sdk/lib/titan/0.6

case $(uname -s) in
  MINGW* | MSYS*) windows=1 ;;
  *) windows=0 ;;
esac

lr() {
  if ((windows)); then
    luarocks.exe --lua-version=5.5 --tree="$(cygpath -m "$sdk")" "$@"
  else
    luarocks "$@"
  fi
}

mkdir "$workspace" "$workspace/mk"
curl -fL --retry 3 -o "$workspace/mk.tar.gz" "https://github.com/$repo/archive/$commit.tar.gz"
tar -xzf "$workspace/mk.tar.gz" --strip-components=1 -C "$workspace/mk"
# luarocks make builds from the unpacked tree and never fetches source.url.
(cd "$workspace/mk" && lr make titan-mk-0.1.0-1.rockspec)

if ((windows)); then
  test -f "$lib/mk.dll"
else
  test -f "$lib/mk.so" && test -f "$lib/mk.a"
fi
lr show titan-mk > /dev/null
echo "PASS: titan-mk $commit installed"
