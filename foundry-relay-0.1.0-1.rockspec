rockspec_format = "3.0"
package = "foundry-relay"
version = "0.1.0-1"
source = {
   url = "git+https://github.com/mascarenhas/foundry-relay.git",
   tag = "v0.1.0",
}
description = {
   summary = "Foundry VTT REST and WebSocket relay written in Titan with titan-mk",
   homepage = "https://github.com/mascarenhas/foundry-relay",
   license = "MIT",
}
dependencies = {
   "lua ~> 5.5",
   "titan ~> 0.6",
   "titan-mk ~> 0.1",
}

-- LuaRocks loads rockspecs with an empty _ENV: only string literals and
-- concatenation below.

-- Linux/macOS link one --static executable. A system-OpenSSL Titan SDK (the
-- default) takes OpenSSL's compile and final-link flags from pkg-config; set
-- OPENSSL_MODE=bundled when the SDK bundles OpenSSL.
local unix_openssl = 'case "${OPENSSL_MODE:-system}" in '
   .. 'system) pkg-config --print-errors --exists "openssl >= 3.0" || exit 1; '
   .. 'TITAN_EXTRA_CPPFLAGS="`pkg-config --cflags openssl`"; '
   .. 'TITAN_EXTRA_LDFLAGS="`pkg-config --libs openssl`"; '
   .. 'export TITAN_EXTRA_CPPFLAGS TITAN_EXTRA_LDFLAGS;; '
   .. 'bundled) ;; '
   .. '*) echo "OPENSSL_MODE must be system or bundled" >&2; exit 1;; '
   .. 'esac; '

-- Windows (MSYS2 CLANG64 SDK) builds a launcher plus its application DLL
-- (`foundry_relay.dll`, named after the root module); --static is
-- unsupported there.
local windows_env = 'set "CC=clang" && set "AR=llvm-ar" && set "RANLIB=llvm-ranlib" && set "RC=llvm-rc" && '
   .. 'set "TITAN_RUNTIME_PREBUILT=1" && set "TITAN_PROBE_CACHE_DISABLE=1" && '
local windows_flags = ' -DUSING_UV_SHARED=1 -I"$(LUA_DIR)\\include" -L"$(LUA_DIR)\\lib" -lcrypto'
   .. ' --ldflag=-Wl,--stack,8388608'

build = {
   type = "command",
   build_command = unix_openssl
      .. '"$(SCRIPTS_DIR)/titanc" --incremental --static --output build --exe build/foundry-relay foundry_relay',
   platforms = {
      unix = {
         install = {
            bin = { ["foundry-relay"] = "build/foundry-relay" },
         },
      },
      windows = {
         build_command = windows_env .. '"$(SCRIPTS_DIR)\\titanc.exe" --incremental --output build'
            .. windows_flags .. ' --exe build\\bin\\foundry-relay.exe foundry_relay',
         -- The launcher finds its DLL through the default Titan path
         -- (`<bin>/../lib/titan/0.6`), where titan-install publishes it.
         install_command = '(if not exist "$(PREFIX)\\dist\\modules" mkdir "$(PREFIX)\\dist\\modules") && '
            .. 'copy /Y build\\lib\\titan\\0.6\\foundry_relay.dll "$(PREFIX)\\dist\\modules\\foundry_relay.dll"',
         install = {
            bin = { ["foundry-relay.exe"] = "build/bin/foundry-relay.exe" },
         },
      },
   },
}

hooks = {
   platforms = {
      windows = {
         post_install = '"$(SCRIPTS_DIR)\\titan-install.bat" --path "$(PREFIX)"',
      },
   },
}

-- `luarocks test [-- --coverage] [-- runner arguments]`: builds the relay and
-- its native suite with the Titan compiler next to LuaRocks, then runs it.
test = {
   type = "command",
   script = "scripts/rock-test.lua",
   flags = { "$(SCRIPTS_DIR)", "$(LUA_DIR)" },
}
