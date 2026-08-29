[CmdletBinding()]
param(
    [string]$PlatformToolsDir,
    [string]$Serial,
    [string]$ManifestPath,
    [string]$OutputJson,
    [scriptblock]$CommandRunner,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $ManifestPath = Join-Path $repoRoot 'config\compatibility.json'
}
$modulePath = Join-Path $repoRoot 'src\UnlockKit.psm1'
Import-Module -Name $modulePath -Force

try {
    $adbPath = 'adb.exe'
    if (-not [string]::IsNullOrWhiteSpace($PlatformToolsDir)) {
        $adbPath = Join-Path $PlatformToolsDir 'adb.exe'
    }
    elseif ($null -eq $CommandRunner) {
        $command = Get-Command adb.exe -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            throw 'adb.exe was not found. Download official Android Platform-Tools and pass -PlatformToolsDir.'
        }
        $adbPath = $command.Source
    }

    if ($null -eq $CommandRunner -and -not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw ('adb.exe does not exist: {0}' -f $adbPath)
    }

    $audit = Invoke-ReadOnlyAudit -AdbPath $adbPath -ManifestPath $ManifestPath -Serial $Serial -CommandRunner $CommandRunner

    Write-Host ('Device: {0} / {1}' -f $audit.Snapshot.model, $audit.Snapshot.device)
    Write-Host ('Build: {0}' -f $audit.Snapshot.displayId)
    Write-Host ('Kernel: {0}' -f $audit.Snapshot.kernel)
    Write-Host ('Slot: {0}; battery: {1}%' -f $audit.Snapshot.slot, $audit.Snapshot.batteryPercent)
    Write-Host ('Masked device ID: {0}' -f $audit.SerialMasked)
    if ($audit.ReadyForDestructiveWorkflow) {
        Write-Host 'PASS: the read-only identity exactly matches the preview profile.' -ForegroundColor Green
    }
    else {
        Write-Host 'The read-only check completed, but the advanced workflow is blocked:' -ForegroundColor Yellow
        foreach ($blocker in $audit.Blockers) { Write-Host ('- {0}' -f $blocker) -ForegroundColor Yellow }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        $absoluteOutput = [IO.Path]::GetFullPath($OutputJson)
        $parent = Split-Path -Parent $absoluteOutput
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent)
        }
        [IO.File]::WriteAllText($absoluteOutput, ($audit | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Write-Host ('Report: {0}' -f $absoluteOutput)
    }

    if ($PassThru) { return $audit }
    if ($audit.ReadyForDestructiveWorkflow) { exit (Get-UnlockExitCode -Category Success) }
    exit (Get-UnlockExitCode -Category UserActionRequired)
}
catch {
    [Console]::Error.WriteLine(('ERROR: {0}' -f $_.Exception.Message))
    if ($PassThru) { throw }
    if ($_.Exception.Message -match 'Multiple ADB|ambiguous|authorized/online|No ADB') {
        exit (Get-UnlockExitCode -Category AmbiguousTransport)
    }
    if ($_.Exception.Message -match 'Unsupported device identity') {
        exit (Get-UnlockExitCode -Category UnsupportedIdentity)
    }
    exit (Get-UnlockExitCode -Category UserActionRequired)
}
