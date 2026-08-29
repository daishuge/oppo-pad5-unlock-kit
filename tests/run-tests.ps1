[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Passed = 0
$script:Failed = 0
$repoRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $repoRoot 'src\UnlockKit.psm1'
$manifestPath = Join-Path $repoRoot 'config\compatibility.json'
$fixtureRoot = Join-Path $PSScriptRoot 'fixtures'

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) {
        throw ('{0}; expected=[{1}] actual=[{2}]' -f $Message, $Expected, $Actual)
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Throws {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if ($null -eq $caught) { throw 'Expected an exception, but no exception was thrown.' }
    if ($caught.Exception.Message -notmatch $Pattern) {
        throw ('Exception did not match /{0}/: {1}' -f $Pattern, $caught.Exception.Message)
    }
}

function It {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
        Write-Host ('PASS  {0}' -f $Name) -ForegroundColor Green
    }
    catch {
        $script:Failed++
        Write-Host ('FAIL  {0}' -f $Name) -ForegroundColor Red
        Write-Host ('      {0}' -f $_.Exception.Message) -ForegroundColor DarkRed
    }
}

if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
    throw ('Expected module is missing: {0}' -f $modulePath)
}
Import-Module -Name $modulePath -Force

function New-FakeReadOnlyRunner {
    param(
        [Parameter(Mandatory = $true)]$Snapshot,
        [string]$DevicesText
    )

    if ([string]::IsNullOrWhiteSpace($DevicesText)) {
        $DevicesText = Get-Content -LiteralPath (Join-Path $fixtureRoot 'adb-devices-single.txt') -Raw
    }
    $values = @{
        'ro.product.model' = [string]$Snapshot.model
        'ro.product.device' = [string]$Snapshot.device
        'ro.build.display.id' = [string]$Snapshot.displayId
        'ro.build.version.ota' = [string]$Snapshot.otaVersion
        'ro.boot.slot_suffix' = [string]$Snapshot.slot
        'ro.boot.flash.locked' = [string]$Snapshot.flashLocked
        'ro.boot.verifiedbootstate' = [string]$Snapshot.verifiedBootState
    }
    $kernel = [string]$Snapshot.kernel
    $battery = [int]$Snapshot.batteryPercent
    $mobileData = [string]$Snapshot.mobileData
    $dataRoaming = [string]$Snapshot.dataRoaming

    return {
        param([string]$FilePath, [string[]]$Arguments)
        $joined = $Arguments -join ' '
        $output = ''
        if ($joined -eq 'devices -l') {
            $output = $DevicesText
        }
        elseif ($joined -match ' shell getprop (\S+)$') {
            $output = [string]$values[$matches[1]]
        }
        elseif ($joined -match ' shell uname -r$') {
            $output = $kernel
        }
        elseif ($joined -match ' shell dumpsys battery$') {
            $output = "AC powered: false`nUSB powered: true`nlevel: $battery`nscale: 100"
        }
        elseif ($joined -match ' shell settings get global mobile_data$') {
            $output = $mobileData
        }
        elseif ($joined -match ' shell settings get global data_roaming$') {
            $output = $dataRoaming
        }
        else {
            return [pscustomobject]@{ ExitCode = 91; Output = ('unexpected mock command: {0}' -f $joined) }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = $output }
    }.GetNewClosure()
}

It 'loads the checked-in compatibility manifest' {
    $manifest = Read-UnlockCompatibilityManifest -Path $manifestPath
    Assert-Equal $manifest.schemaVersion 1 'schemaVersion mismatch'
    Assert-Equal $manifest.profiles.Count 1 'profile count mismatch'
    Assert-Equal $manifest.profiles[0].id 'opd2506-cn-16.0.9.400-b-to-a' 'profile ID mismatch'
}

It 'parses one authorized ADB device' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'adb-devices-single.txt') -Raw
    $devices = @(ConvertFrom-AdbDevices -Text $text)
    Assert-Equal $devices.Count 1 'device count mismatch'
    Assert-Equal $devices[0].Serial 'TESTSERIAL0001' 'serial mismatch'
    Assert-Equal $devices[0].State 'device' 'state mismatch'
    Assert-Equal $devices[0].Model 'OPD2506' 'model mismatch'
}

It 'selects the sole online ADB device when no serial is supplied' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'adb-devices-single.txt') -Raw
    $selected = Select-AdbSerial -Devices @(ConvertFrom-AdbDevices -Text $text)
    Assert-Equal $selected 'TESTSERIAL0001' 'selected serial mismatch'
}

It 'rejects ambiguous ADB transports' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'adb-devices-multiple.txt') -Raw
    $devices = @(ConvertFrom-AdbDevices -Text $text)
    Assert-Throws -Action { Select-AdbSerial -Devices $devices } -Pattern 'multiple.*device|ambiguous'
}

It 'allows an exact serial to disambiguate transports' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'adb-devices-multiple.txt') -Raw
    $selected = Select-AdbSerial -Devices @(ConvertFrom-AdbDevices -Text $text) -Serial 'TESTSERIAL0001'
    Assert-Equal $selected 'TESTSERIAL0001' 'explicit serial mismatch'
}

It 'accepts independent fastboot unlocked and secure readback' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'fastboot-unlocked.txt') -Raw
    $variables = ConvertFrom-FastbootVariables -Text $text
    Assert-True (Test-FastbootUnlocked -Variables $variables) 'verified unlock was rejected'
    Assert-Equal $variables['current-slot'] 'a' 'current slot mismatch'
}

It 'rejects host OKAY when bootloader still reports locked' {
    $text = Get-Content -LiteralPath (Join-Path $fixtureRoot 'fastboot-false-okay.txt') -Raw
    $variables = ConvertFrom-FastbootVariables -Text $text
    Assert-True (-not (Test-FastbootUnlocked -Variables $variables)) 'false OKAY was accepted as unlocked'
}

It 'rejects a malformed asset hash in a compatibility manifest' {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.assets.kernelSu.sha256 = 'not-a-sha256'
    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-invalid-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tempPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Assert-Throws -Action { Read-UnlockCompatibilityManifest -Path $tempPath } -Pattern 'sha256|SHA-256'
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

It 'allows only the enumerated read-only ADB commands' {
    Assert-True (Test-ReadOnlyAdbArguments -Arguments @('devices', '-l')) 'devices -l was rejected'
    Assert-True (Test-ReadOnlyAdbArguments -Arguments @('-s', 'TESTSERIAL0001', 'shell', 'getprop', 'ro.product.model')) 'getprop was rejected'
    Assert-True (Test-ReadOnlyAdbArguments -Arguments @('-s', 'TESTSERIAL0001', 'shell', 'dumpsys', 'battery')) 'battery query was rejected'
    Assert-True (-not (Test-ReadOnlyAdbArguments -Arguments @('-s', 'TESTSERIAL0001', 'install', 'x.apk'))) 'install was accepted'
    Assert-True (-not (Test-ReadOnlyAdbArguments -Arguments @('-s', 'TESTSERIAL0001', 'reboot'))) 'reboot was accepted'
    Assert-True (-not (Test-ReadOnlyAdbArguments -Arguments @('-s', 'TESTSERIAL0001', 'shell', 'su', '-c', 'id'))) 'su was accepted'
}

It 'audits the exact supported profile through an injected runner' {
    $snapshot = Get-Content -LiteralPath (Join-Path $fixtureRoot 'device-supported.json') -Raw | ConvertFrom-Json
    $runner = New-FakeReadOnlyRunner -Snapshot $snapshot
    $audit = Invoke-ReadOnlyAudit -AdbPath 'fixture-adb.exe' -ManifestPath $manifestPath -CommandRunner $runner
    Assert-Equal $audit.ProfileId 'opd2506-cn-16.0.9.400-b-to-a' 'audit profile mismatch'
    Assert-True $audit.ReadyForDestructiveWorkflow 'supported fixture was not marked ready'
    Assert-Equal $audit.SerialMasked 'TES********001' 'serial masking mismatch'
}

It 'reports an exact kernel mismatch instead of a generic failure' {
    $snapshot = Get-Content -LiteralPath (Join-Path $fixtureRoot 'device-wrong-kernel.json') -Raw | ConvertFrom-Json
    $runner = New-FakeReadOnlyRunner -Snapshot $snapshot
    Assert-Throws -Action {
        Invoke-ReadOnlyAudit -AdbPath 'fixture-adb.exe' -ManifestPath $manifestPath -CommandRunner $runner
    } -Pattern 'kernel: expected=.*actual=.*unknown-build'
}

It 'does not mark a low-battery device ready for destructive work' {
    $snapshot = Get-Content -LiteralPath (Join-Path $fixtureRoot 'device-supported.json') -Raw | ConvertFrom-Json
    $snapshot.batteryPercent = 59
    $runner = New-FakeReadOnlyRunner -Snapshot $snapshot
    $audit = Invoke-ReadOnlyAudit -AdbPath 'fixture-adb.exe' -ManifestPath $manifestPath -CommandRunner $runner
    Assert-True (-not $audit.ReadyForDestructiveWorkflow) 'low battery was accepted'
    Assert-True (($audit.Blockers -join ' ') -match 'battery') 'low-battery blocker is missing'
}

It 'reports active slot A as unsupported for the preview destructive path' {
    $snapshot = Get-Content -LiteralPath (Join-Path $fixtureRoot 'device-supported.json') -Raw | ConvertFrom-Json
    $snapshot.slot = '_a'
    $runner = New-FakeReadOnlyRunner -Snapshot $snapshot
    $audit = Invoke-ReadOnlyAudit -AdbPath 'fixture-adb.exe' -ManifestPath $manifestPath -CommandRunner $runner
    Assert-True (-not $audit.ReadyForDestructiveWorkflow) 'untested A-to-B path was accepted'
    Assert-True (($audit.Blockers -join ' ') -match 'source slot') 'slot blocker is missing'
}

It 'keeps the safe entry point free of mutating operation tokens' {
    $safeEntry = Join-Path $repoRoot 'Check-OPPOPad5.ps1'
    Assert-True (Test-Path -LiteralPath $safeEntry -PathType Leaf) 'safe entry point is missing'
    $source = Get-Content -LiteralPath $safeEntry -Raw
    Assert-True ($source -notmatch '(?im)\b(?:install|push|reboot|setrw|fastboot|su\s+-c)\b') 'safe entry point contains a mutating operation token'
}

It 'accepts an asset only when both byte length and SHA-256 match' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-asset-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDir)
    try {
        $path = Join-Path $tempDir 'hello.bin'
        [IO.File]::WriteAllBytes($path, [Text.Encoding]::ASCII.GetBytes('hello'))
        $spec = [pscustomobject]@{ fileName = 'hello.bin'; bytes = 5; sha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' }
        $check = Test-PinnedAsset -Path $path -Asset $spec
        Assert-True $check.Valid 'correct asset was rejected'
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    }
}

It 'rejects same-size wrong content and truncated assets' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-asset-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDir)
    try {
        $spec = [pscustomobject]@{ fileName = 'hello.bin'; bytes = 5; sha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' }
        $wrong = Join-Path $tempDir 'wrong.bin'
        $short = Join-Path $tempDir 'short.bin'
        [IO.File]::WriteAllBytes($wrong, [Text.Encoding]::ASCII.GetBytes('HELLO'))
        [IO.File]::WriteAllBytes($short, [Text.Encoding]::ASCII.GetBytes('hell'))
        Assert-True (-not (Test-PinnedAsset -Path $wrong -Asset $spec).Valid) 'same-size wrong content was accepted'
        Assert-True (-not (Test-PinnedAsset -Path $short -Asset $spec).Valid) 'truncated content was accepted'
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    }
}

It 'publishes a downloaded asset only after atomic validation' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-download-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDir)
    try {
        $spec = [pscustomobject]@{
            fileName = 'hello.bin'
            bytes = 5
            sha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
            url = 'https://example.invalid/hello.bin'
        }
        $downloader = {
            param([string]$Url, [string]$Destination)
            [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::ASCII.GetBytes('hello'))
        }
        $result = Receive-PinnedAsset -Asset $spec -DestinationDirectory $tempDir -Downloader $downloader
        Assert-True (Test-Path -LiteralPath $result.Path -PathType Leaf) 'validated final asset is missing'
        Assert-True (-not (Test-Path -LiteralPath ($result.Path + '.partial'))) 'partial file survived atomic promotion'
        Assert-True $result.Valid 'download result was not valid'
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    }
}

It 'does not promote a downloader result with the wrong digest' {
    $tempDir = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-download-{0}' -f [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $tempDir)
    try {
        $spec = [pscustomobject]@{
            fileName = 'hello.bin'
            bytes = 5
            sha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
            url = 'https://example.invalid/hello.bin'
        }
        $downloader = {
            param([string]$Url, [string]$Destination)
            [IO.File]::WriteAllBytes($Destination, [Text.Encoding]::ASCII.GetBytes('HELLO'))
        }
        Assert-Throws -Action {
            Receive-PinnedAsset -Asset $spec -DestinationDirectory $tempDir -Downloader $downloader
        } -Pattern 'SHA-256|digest|validation'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $tempDir 'hello.bin'))) 'invalid download was promoted'
    }
    finally {
        if (Test-Path -LiteralPath $tempDir) { Remove-Item -LiteralPath $tempDir -Recurse -Force }
    }
}

It 'rejects a manifest whose pinned LK source leaves the recorded commit' {
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $manifest.assets.lk.url = 'https://evil.example/lk.img'
    $tempPath = Join-Path ([IO.Path]::GetTempPath()) ('opd2506-url-{0}.json' -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($tempPath, ($manifest | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
        Assert-Throws -Action { Read-UnlockCompatibilityManifest -Path $tempPath } -Pattern 'pinned|URL|source'
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force }
    }
}

Write-Host ('RESULT passed={0} failed={1}' -f $script:Passed, $script:Failed)
if ($script:Failed -ne 0) { exit 1 }
