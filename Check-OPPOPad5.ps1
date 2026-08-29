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
            throw '找不到 adb.exe。请从 Android Developers 官方页面下载 Platform-Tools，并通过 -PlatformToolsDir 指定目录。'
        }
        $adbPath = $command.Source
    }

    if ($null -eq $CommandRunner -and -not (Test-Path -LiteralPath $adbPath -PathType Leaf)) {
        throw ('adb.exe 不存在：{0}' -f $adbPath)
    }

    $audit = Invoke-ReadOnlyAudit -AdbPath $adbPath -ManifestPath $ManifestPath -Serial $Serial -CommandRunner $CommandRunner

    Write-Host ('设备：{0} / {1}' -f $audit.Snapshot.model, $audit.Snapshot.device)
    Write-Host ('版本：{0}' -f $audit.Snapshot.displayId)
    Write-Host ('内核：{0}' -f $audit.Snapshot.kernel)
    Write-Host ('槽位：{0}；电量：{1}%' -f $audit.Snapshot.slot, $audit.Snapshot.batteryPercent)
    Write-Host ('设备标识：{0}' -f $audit.SerialMasked)
    if ($audit.ReadyForDestructiveWorkflow) {
        Write-Host '只读检查通过：身份与预览配置完全匹配。' -ForegroundColor Green
    }
    else {
        Write-Host '只读检查完成，但高级流程被以下条件阻断：' -ForegroundColor Yellow
        foreach ($blocker in $audit.Blockers) { Write-Host ('- {0}' -f $blocker) -ForegroundColor Yellow }
    }

    if (-not [string]::IsNullOrWhiteSpace($OutputJson)) {
        $absoluteOutput = [IO.Path]::GetFullPath($OutputJson)
        $parent = Split-Path -Parent $absoluteOutput
        if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
            [void](New-Item -ItemType Directory -Path $parent)
        }
        [IO.File]::WriteAllText($absoluteOutput, ($audit | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
        Write-Host ('报告：{0}' -f $absoluteOutput)
    }

    if ($PassThru) { return $audit }
    if ($audit.ReadyForDestructiveWorkflow) { exit 0 }
    exit 20
}
catch {
    Write-Error $_.Exception.Message
    if ($PassThru) { throw }
    if ($_.Exception.Message -match 'Multiple ADB|ambiguous|authorized/online|No ADB') { exit 11 }
    exit 10
}
