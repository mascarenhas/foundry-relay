param(
  [Parameter(Mandatory = $true)][string]$Application,
  [Parameter(Mandatory = $true)][string]$TestPayload,
  [Parameter(Mandatory = $true)][string]$ReadObj,
  [string]$OpenSSL = $env:RELAY_TEST_OPENSSL,
  [string]$Chrome = $env:RELAY_TEST_CHROME,
  [ValidateRange(1, 600)][int]$TimeoutSeconds = 120
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$Application = (Resolve-Path $Application).Path
$TestPayload = (Resolve-Path $TestPayload).Path
$ReadObj = (Resolve-Path $ReadObj).Path

# --coff-imports includes both regular imports and delay imports. Inspect every
# image in both payloads, including the standard provider and native DLLs.
$private = @('lua-5.5.1.dll', 'libuv-1.dll', 'libllhttp-9.4.dll',
  'libsqlite3-0.dll', 'libcrypto-3-x64.dll', 'libssl-3-x64.dll')
$system = @('kernel32.dll', 'ucrtbase.dll', 'advapi32.dll', 'user32.dll',
  'psapi.dll', 'iphlpapi.dll', 'userenv.dll', 'ws2_32.dll', 'dbghelp.dll',
  'ole32.dll', 'shell32.dll', 'gdi32.dll', 'crypt32.dll', 'bcrypt.dll')
foreach ($payload in @($Application, $TestPayload)) {
  foreach ($name in $private) {
    if (-not (Test-Path "$payload\bin\$name" -PathType Leaf)) {
      throw "Missing adjacent runtime DLL: $name"
    }
  }
  if (-not (Test-Path "$payload\lib\titan\0.6\titan.dll" -PathType Leaf)) {
    throw 'Missing Titan standard provider'
  }
  foreach ($file in (Get-ChildItem $payload -File -Recurse | Where-Object {
      $_.Extension -in @('.exe', '.dll') })) {
    $imports = (& $ReadObj --coff-imports $file.FullName) -join "`n"
    if ($LASTEXITCODE -ne 0 -or $imports -notmatch '(?m)^Format: COFF-x86-64\r?$') {
      throw "Not an inspectable x64 PE image: $($file.Name)"
    }
    $names = [regex]::Matches($imports, '(?m)^  Name: ([^\r\n]+)\r?$')
    if ($names.Count -eq 0) { throw "Missing import table: $($file.Name)" }
    foreach ($entry in $names) {
      $name = $entry.Groups[1].Value.ToLowerInvariant()
      if ($name -notin $private -and $name -notin $system -and
          $name -notmatch '^api-ms-win-crt-[a-z0-9-]+\.dll$') {
        throw "Unpackaged or unexpected dependency in $($file.Name): $name"
      }
    }
    Write-Output "PE imports verified: $($file.Name)"
  }
}

function Start-NativeProcess([string]$Executable, [string]$Directory,
    [hashtable]$Environment) {
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo.FileName = $Executable
  $process.StartInfo.WorkingDirectory = $Directory
  $process.StartInfo.UseShellExecute = $false
  $process.StartInfo.RedirectStandardOutput = $true
  $process.StartInfo.RedirectStandardError = $true
  $process.StartInfo.StandardOutputEncoding = New-Object Text.UTF8Encoding($false)
  $process.StartInfo.StandardErrorEncoding = New-Object Text.UTF8Encoding($false)
  # Deliberately exclude MSYS2, LLVM, the compiler, and SDK module-path overrides.
  $process.StartInfo.EnvironmentVariables['PATH'] = "$env:SystemRoot\System32;$env:SystemRoot"
  foreach ($name in @('LUA_PATH', 'LUA_CPATH', 'LUA_PATH_5_5', 'LUA_CPATH_5_5',
      'LUA_INIT', 'LUA_INIT_5_5', 'TITAN_PATH_0_6', 'TITAN_ROCKS_ROOT')) {
    $process.StartInfo.EnvironmentVariables.Remove($name)
  }
  foreach ($name in $Environment.Keys) {
    $process.StartInfo.EnvironmentVariables[$name] = $Environment[$name]
  }
  if (-not $process.Start()) { $process.Dispose(); throw 'Native launch failed' }
  return $process
}

function Stop-NativeProcess([Diagnostics.Process]$Process) {
  try {
    if (-not $Process.HasExited) {
      $Process.Kill()
      if (-not $Process.WaitForExit(10000)) { throw 'Native process did not terminate' }
    }
  } finally { $Process.Dispose() }
}

$scratch = Join-Path ([IO.Path]::GetTempPath()) ('foundry-relay-' + [Guid]::NewGuid().ToString('N'))
$drive = New-Object IO.DriveInfo([IO.Path]::GetPathRoot($scratch))
if ($drive.DriveFormat -ne 'NTFS') { throw 'Native validation requires local NTFS' }
New-Item -ItemType Directory $scratch | Out-Null
$server = $null
$suite = $null
try {
  # Relocate into a Unicode path and run from another CWD, preserving the native
  # bin/lib layout. Neither payload contains the compiler or its SDK sources.
  $relocated = Join-Path $scratch ('relay Windows ' + [char]0x4E16 + [char]0x754C)
  Copy-Item $Application $relocated -Recurse
  $cwd = Join-Path $scratch 'working directory'
  New-Item -ItemType Directory $cwd | Out-Null
  $probe = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
  $probe.Start()
  $port = $probe.LocalEndpoint.Port
  $probe.Stop()
  $settings = @{
    FOUNDRY_REST_API_KEY = 'windows-smoke-api-key'; FOUNDRY_PAIRING_CODE = 'WIN42A'
    RELAY_HOST = '127.0.0.1'; RELAY_PORT = [string]$port
    RELAY_DATABASE = (Join-Path $cwd 'relay.sqlite3')
    RELAY_PUBLIC_URL = "ws://127.0.0.1:$port/relay"
    RELAY_ALLOWED_ORIGINS = 'http://127.0.0.1:30000'
    RELAY_REQUEST_TIMEOUT_MS = '1000'; RELAY_AUTH_TIMEOUT_MS = '10000'
    RELAY_HEARTBEAT_MS = '30000'; RELAY_MAX_PENDING = '128'
  }
  $server = Start-NativeProcess "$relocated\bin\foundry-relay.exe" $cwd $settings
  $diagnostics = $server.StandardError.ReadToEndAsync()
  $ready = $server.StandardOutput.ReadLineAsync()
  if (-not $ready.Wait(10000) -or $ready.Result -ne "Foundry relay listening on 127.0.0.1:$port") {
    throw 'Relocated Windows application did not become ready'
  }
  $health = Invoke-WebRequest "http://127.0.0.1:$port/health" -UseBasicParsing -TimeoutSec 5
  if ($health.StatusCode -ne 200 -or ($health.Content | ConvertFrom-Json).status -ne 'ok') {
    throw 'Native health check failed'
  }
  $paired = Invoke-WebRequest "http://127.0.0.1:$port/auth/pair" -UseBasicParsing -TimeoutSec 5 `
    -Method Post -ContentType 'application/json' `
    -Body '{"code":"WIN42A","worldId":"windows-process","worldTitle":"Windows"}'
  $identity = $paired.Content | ConvertFrom-Json
  if ($paired.StatusCode -ne 200 -or -not $identity.clientId -or -not $identity.token) {
    throw 'Native SQLite-backed pairing failed'
  }
  $clients = Invoke-WebRequest "http://127.0.0.1:$port/clients" -UseBasicParsing -TimeoutSec 5 `
    -Headers @{'x-api-key' = 'windows-smoke-api-key'}
  if ($clients.StatusCode -ne 200 -or $clients.Content -notmatch 'windows-process') {
    throw 'Native authenticated client listing failed'
  }
  Write-Output 'Relocated application passed health, pairing, and authenticated clients checks without SDK/toolchain PATH'
  $server.Kill()
  if (-not $server.WaitForExit(10000)) { throw 'Application did not terminate after smoke checks' }
  if (-not $diagnostics.Wait(10000) -or $diagnostics.Result -ne '') {
    throw "Application emitted diagnostics: $($diagnostics.Result)"
  }
  Stop-NativeProcess $server
  $server = $null

  $suite = Start-NativeProcess "$TestPayload\bin\relay-tests.exe" $cwd @{
    TMP = $cwd; TEMP = $cwd; RELAY_TEST_OPENSSL = $OpenSSL
    RELAY_TEST_CHROME = $Chrome; RELAY_TEST_BROWSER_PROFILES = $cwd
  }
  $stdout = $suite.StandardOutput.ReadToEndAsync()
  $stderr = $suite.StandardError.ReadToEndAsync()
  if (-not $suite.WaitForExit($TimeoutSeconds * 1000)) { throw 'Windows Titan suite timed out' }
  if (-not $stdout.Wait(10000) -or -not $stderr.Wait(10000)) { throw 'Test output did not close' }
  Write-Output $stdout.Result
  if ($stderr.Result) { Write-Output $stderr.Result }
  if ($suite.ExitCode -ne 0) { throw "Windows Titan suite failed: $($suite.ExitCode)" }
  $summary = $stdout.Result + "`n" + $stderr.Result
  if ($summary -notmatch '\[==========\] [1-9][0-9]* tests ran\.' -or
      $summary -notmatch '\[  PASSED  \]') { throw 'Missing native test summary' }
} finally {
  if ($server) { Stop-NativeProcess $server }
  if ($suite) { Stop-NativeProcess $suite }
  Remove-Item $scratch -Recurse -Force
}
