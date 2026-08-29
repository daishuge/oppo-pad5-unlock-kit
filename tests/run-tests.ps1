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

Write-Host ('RESULT passed={0} failed={1}' -f $script:Passed, $script:Failed)
if ($script:Failed -ne 0) { exit 1 }
