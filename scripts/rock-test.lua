-- `luarocks test` driver. LuaRocks passes its tool directory (where titanc
-- lives) and the SDK include/library directories; remaining arguments go to
-- the native test runner, except a leading `--coverage`, which builds and
-- runs the instrumented images instead (Linux/macOS).
local scripts_dir, include_dir, library_dir = arg[1], arg[2], arg[3]
if not (scripts_dir and include_dir and library_dir) then
   io.stderr:write("usage: lua scripts/rock-test.lua SCRIPTS_DIR LUA_INCDIR LUA_LIBDIR [--coverage] [runner arguments...]\n")
   os.exit(2)
end
local windows = package.config:sub(1, 1) == "\\"
local coverage = arg[4] == "--coverage"
local runner_args = {}
for index = coverage and 5 or 4, #arg do runner_args[#runner_args + 1] = arg[index] end

local function quote(text)
   if windows then return '"' .. text .. '"' end
   return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function run(command)
   io.stderr:write("+ " .. command .. "\n")
   if not os.execute(command) then os.exit(1) end
end

local function output(command)
   local pipe = assert(io.popen(command))
   local text = pipe:read("a"):gsub("%s+$", "")
   local ok = pipe:close()
   return ok and text or nil
end

local function arguments()
   local quoted = {}
   for index = 1, #runner_args do quoted[index] = quote(runner_args[index]) end
   return #quoted > 0 and (" " .. table.concat(quoted, " ")) or ""
end

if windows then
   if coverage then
      io.stderr:write("rock-test.lua: --coverage is supported on Linux and macOS\n")
      os.exit(2)
   end
   local env = 'set "CC=clang" && set "AR=llvm-ar" && set "RANLIB=llvm-ranlib" && set "RC=llvm-rc" && '
      .. 'set "TITAN_RUNTIME_PREBUILT=1" && set "TITAN_PROBE_CACHE_DISABLE=1" && '
   local titanc = quote(scripts_dir .. "\\titanc.exe") .. " --incremental --output build"
      .. " -DUSING_UV_SHARED=1 -I" .. quote(include_dir) .. " -L" .. quote(library_dir)
      .. " -lcrypto --ldflag=-Wl,--stack,8388608"
   run(env .. titanc .. " --exe build\\bin\\foundry-relay.exe foundry_relay")
   -- The standalone-process test relocates a static executable (Linux/macOS).
   run(env .. titanc .. " --test --tree . --test-dir tests --test-exclude tests.process_test"
      .. " --exe build\\bin\\relay-tests.exe")
   run("build\\bin\\relay-tests.exe" .. arguments())
   os.exit(0)
end

local link_env = ""
if (os.getenv("OPENSSL_MODE") or "system") == "system" then
   local cflags = output("pkg-config --cflags openssl")
   local libs = output("pkg-config --libs openssl")
   if not libs or libs == "" then
      io.stderr:write("rock-test.lua: pkg-config found no OpenSSL; set OPENSSL_MODE=bundled for a bundled-OpenSSL Titan SDK\n")
      os.exit(1)
   end
   link_env = "TITAN_EXTRA_CPPFLAGS=" .. quote(cflags or "") .. " TITAN_EXTRA_LDFLAGS=" .. quote(libs) .. " "
end
local titanc = quote(scripts_dir .. "/titanc")

if not coverage then
   run(link_env .. titanc .. " --incremental --static --output build --exe build/foundry-relay foundry_relay")
   run(link_env .. titanc .. " --incremental --static --output build --test --tree . --test-dir tests"
      .. " --exe build/relay-tests")
   run("RELAY_TEST_EXECUTABLE=build/foundry-relay build/relay-tests" .. arguments())
   os.exit(0)
end

-- Coverage objects live in their own output trees, so ordinary builds are
-- unaffected. The server and the suite reset and dump their counters
-- independently, so each image owns a separate tree.
local root = assert(output("pwd"), "cannot determine the working directory")
-- The relocated server in process_test runs without PATH, so its report
-- needs an absolute gcov (COVERAGE_GCOV, else the gcov found on PATH).
local gcov = os.getenv("COVERAGE_GCOV") or output("command -v gcov")
if not gcov or gcov == "" then
   io.stderr:write("rock-test.lua: --coverage needs gcov on PATH or COVERAGE_GCOV\n")
   os.exit(1)
end
local coverage_flags = " --coverage --coverage-gcov " .. quote(gcov)
local clean_env = "env -u TITAN_FILTER -u GCOV_PREFIX -u GCOV_PREFIX_STRIP "
run("rm -rf build/coverage-app build/coverage-tests")
run(clean_env .. link_env .. titanc .. " --static --output build/coverage-app" .. coverage_flags
   .. " --exe build/coverage-app/foundry-relay foundry_relay")
run(clean_env .. link_env .. titanc .. " --static --output build/coverage-tests" .. coverage_flags
   .. " --test --tree . --test-dir tests --exe build/coverage-tests/relay-tests foundry_relay")
run("mkdir -p build/coverage-app/.coverage/report build/coverage-tests/.coverage/report")
run(clean_env .. "RELAY_TEST_EXECUTABLE=build/coverage-app/foundry-relay RELAY_TEST_COVERAGE_REPORT="
   .. quote(root .. "/build/coverage-app/.coverage/report") .. " build/coverage-tests/relay-tests" .. arguments())
