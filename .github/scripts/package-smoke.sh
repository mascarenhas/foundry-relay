#!/usr/bin/env bash
# Install foundry-relay from this checkout through LuaRocks, run the installed
# executable from outside the checkout without the SDK, toolchain, or Titan
# search overrides, then remove the rock and check that nothing of it remains.
#
# Run from the repository root with the Titan SDK's bin directory first on
# PATH, TITAN_PREFIX naming that SDK, and titan-mk installed into it. On
# Windows (MSYS2 CLANG64) also export LUAROCKS_CONFIG.
# Usage: package-smoke.sh ABSENT_WORKSPACE
set -euxo pipefail

workspace=${1:?usage: package-smoke.sh ABSENT_WORKSPACE}
sdk=${TITAN_PREFIX:?set TITAN_PREFIX to the Titan SDK}
rockspec=foundry-relay-0.1.0-1.rockspec
lib=$sdk/lib/titan/0.6
api_key=package-smoke-api-key
pairing_code=SMOKE1

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

free_port() {
  if ((windows)); then
    # The $ expressions are PowerShell's, not the shell's.
    # shellcheck disable=SC2016
    powershell.exe -NoProfile -NonInteractive -Command \
      '$l = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0); $l.Start(); $l.LocalEndpoint.Port; $l.Stop()' |
      tr -d '\r'
  else
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
  fi
}

# Only the system directories on PATH, and no Titan or Lua search overrides.
# env stays the direct parent of the relay: on Unix it execs the relay itself.
if ((windows)); then
  clean_env=(env -u TITAN_PATH_0_6 -u TITAN_PATH -u TITAN_ROOT -u TITANC
    -u LUA_PATH -u LUA_CPATH -u LUA_PATH_5_5 -u LUA_CPATH_5_5 -u LUA_INIT -u LUA_INIT_5_5
    -u FOUNDRY_REST_API_KEY -u FOUNDRY_PAIRING_CODE PATH=/c/Windows/System32:/c/Windows)
else
  clean_env=(env -i PATH=/usr/bin:/bin HOME="$workspace")
fi

relay=
stop_relay() {
  if [[ -n $relay ]] && kill -0 "$relay" 2> /dev/null; then
    if ((windows)); then
      # MSYS2 runs a native program under a stub; end the whole process tree.
      taskkill //F //T //PID "$(cat "/proc/$relay/winpid")" || true
    else
      kill -KILL "$relay" || true
    fi
    wait "$relay" || true
  fi
  relay=
}
on_exit() {
  local status=$?
  stop_relay
  if ((status != 0)) && [[ -f $workspace/relay.log ]]; then cat "$workspace/relay.log"; fi
}
trap on_exit EXIT

mkdir "$workspace"

# 1. Build and install from the checkout (luarocks make never fetches source.url).
lr make "$rockspec"
rock_dir=$(lr show --rock-dir foundry-relay | tr -d '\r')
if ((windows)); then rock_dir=$(cygpath -u "$rock_dir"); fi
test -d "$rock_dir"
if ((windows)); then
  exe=$sdk/bin/foundry-relay.exe
  test -f "$exe"
  # titan-install published the application DLL beside titan.dll and mk.dll.
  test -f "$lib/foundry_relay.dll"
else
  exe=$sdk/bin/foundry-relay
  test -x "$exe"
  # LuaRocks installed the native executable itself, not a wrapper script.
  test "$(od -An -tx1 -N2 "$exe" | tr -d ' \n')" != 2321
fi

# 2. Run the installed executable from the workspace.
cd "$workspace"
status=0
"${clean_env[@]}" "$exe" > invalid.out 2> invalid.err || status=$?
test "$status" -eq 1
grep -q '"reason":"invalid_configuration"' invalid.err

port=$(free_port)
[[ $port =~ ^[0-9]+$ ]]
database=$workspace/relay.sqlite3
if ((windows)); then database=$(cygpath -w "$database"); fi
"${clean_env[@]}" FOUNDRY_REST_API_KEY="$api_key" FOUNDRY_PAIRING_CODE="$pairing_code" \
  RELAY_HOST=127.0.0.1 RELAY_PORT="$port" RELAY_DATABASE="$database" RELAY_LOG_LEVEL=info \
  "$exe" > relay.out 2> relay.log &
relay=$!
base=http://127.0.0.1:$port
for _ in $(seq 1 150); do
  if curl -fsS -m 2 -o /dev/null "$base/health"; then break; fi
  kill -0 "$relay"
  sleep 0.2
done
test "$(curl -fsS -m 5 "$base/health" | tr -d '\r')" = '{"status":"ok"}'
headers=$(curl -sS -m 5 -o /dev/null -D - "$base/clients" | tr -d '\r')
grep -q '^HTTP/1.1 401' <<< "$headers"
grep -q '^WWW-Authenticate: ApiKey realm="Restricted"$' <<< "$headers"
paired=$(curl -fsS -m 5 -H 'Content-Type: application/json' \
  --data "{\"code\":\"$pairing_code\",\"worldId\":\"package-smoke\",\"worldTitle\":\"Package smoke\"}" \
  "$base/auth/pair")
token=$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' <<< "$paired")
test -n "$token"
curl -fsS -m 5 -H "x-api-key: $api_key" "$base/clients" | grep -q '"package-smoke"'

if ((windows)); then
  # Windows has no SIGTERM; scripts/check-windows.ps1 likewise ends the relay.
  stop_relay
else
  kill -TERM "$relay"
  status=0
  wait "$relay" || status=$?
  relay=
  test "$status" -eq 0
  grep -q '"event":"server_stopped"' relay.log
fi
grep -q '"event":"server_started"' relay.log
test ! -s relay.out
if grep -qF -e "$api_key" -e "$token" relay.log; then exit 1; fi
cd - > /dev/null

# 3. Remove the rock: LuaRocks owns the executable; on Windows titan-uninstall
# also removes the published application DLL.
if ((windows)); then
  MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c "titan-uninstall.bat foundry-relay"
  test ! -e "$lib/foundry_relay.dll"
else
  lr remove foundry-relay
fi
test ! -e "$exe"
test ! -e "$rock_dir"
if lr show foundry-relay > /dev/null 2>&1; then exit 1; fi
echo 'PASS: foundry-relay install, standalone run, and removal'
