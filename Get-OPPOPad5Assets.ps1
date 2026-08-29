[CmdletBinding()]
param(
    [string]$DestinationDirectory = (Join-Path $PSScriptRoot 'downloads'),
    [string]$ManifestPath = (Join-Path $PSScriptRoot 'config\compatibility.json'),
    [ValidateSet('kernelSu', 'lk')]
    [string[]]$Download = @('kernelSu', 'lk'),
    [string]$GhostLockApk,
    [string]$OtaZip,
    [scriptblock]$Downloader,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'src\UnlockKit.psm1') -Force
$manifest = Read-UnlockCompatibilityManifest -Path $ManifestPath
$results = @()

foreach ($assetName in $Download) {
    $asset = $manifest.assets.$assetName
    $result = Receive-PinnedAsset -Asset $asset -DestinationDirectory $DestinationDirectory -Downloader $Downloader
    $results += [pscustomobject]@{
        Name = $assetName
        Path = $result.Path
        Bytes = $result.ActualBytes
        Sha256 = $result.ActualSha256
        Valid = $result.Valid
    }
    Write-Host ('已验证：{0}  {1}' -f $assetName, $result.ActualSha256) -ForegroundColor Green
}

foreach ($supplied in @(
    [pscustomobject]@{ Name = 'ghostLock'; Path = $GhostLockApk },
    [pscustomobject]@{ Name = 'ota'; Path = $OtaZip }
)) {
    if ([string]::IsNullOrWhiteSpace([string]$supplied.Path)) { continue }
    $result = Test-PinnedAsset -Path $supplied.Path -Asset $manifest.assets.($supplied.Name)
    if (-not $result.Valid) {
        throw ('用户提供的 {0} 未通过验证：{1}' -f $supplied.Name, $result.Reason)
    }
    $results += [pscustomobject]@{
        Name = $supplied.Name
        Path = $result.Path
        Bytes = $result.ActualBytes
        Sha256 = $result.ActualSha256
        Valid = $result.Valid
    }
    Write-Host ('已验证：{0}  {1}' -f $supplied.Name, $result.ActualSha256) -ForegroundColor Green
}

if ($PassThru) { return $results }
