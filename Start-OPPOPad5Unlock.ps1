[CmdletBinding()]
param(
    [ValidateSet('Plan', 'VerifyPostUnlock')]
    [string]$Mode = 'Plan',

    [string]$AuditReportPath,

    [string]$StageReportPath,
    [string]$PostUnlockReportPath,
    [string]$AssetDirectory = (Join-Path $PSScriptRoot 'assets'),
    [string]$StatePath = (Join-Path $PSScriptRoot 'state\workflow.json'),
    [string]$Serial,
    [switch]$TemporaryRootAvailable,
    [switch]$LocalBackupsPresent,
    [string]$LkBackupSha256,
    [string]$InitBootBackupSha256,
    [switch]$EnableDestructive,
    [string]$ConfirmationPhrase = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'src\UnlockKit.psm1'
$manifestPath = Join-Path $PSScriptRoot 'config\compatibility.json'
Import-Module -Name $modulePath -Force

trap {
    [Console]::Error.WriteLine(('ERROR: {0}' -f $_.Exception.Message))
    exit (Get-UnlockExitCode -Category UserActionRequired)
}

if ([string]::IsNullOrWhiteSpace($AuditReportPath)) {
    [Console]::Error.WriteLine('ERROR: This advanced preview requires -AuditReportPath. Run Start-ReadOnlyCheck.cmd first.')
    exit (Get-UnlockExitCode -Category UserActionRequired)
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Label)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ("{0} does not exist: {1}" -f $Label, $Path) }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

$manifest = Read-UnlockCompatibilityManifest -Path $manifestPath
$audit = Read-JsonFile -Path $AuditReportPath -Label 'Read-only audit report'
$profile = @($manifest.profiles | Where-Object { [string]$_.id -ceq [string]$audit.ProfileId })
if ($profile.Count -ne 1) {
    [Console]::Error.WriteLine('ERROR: The audit report does not resolve to exactly one compatibility profile.')
    exit (Get-UnlockExitCode -Category UnsupportedIdentity)
}
$profile = $profile[0]

if ($Mode -eq 'VerifyPostUnlock') {
    if ([string]::IsNullOrWhiteSpace($PostUnlockReportPath)) {
        [Console]::Error.WriteLine('ERROR: -PostUnlockReportPath is required in VerifyPostUnlock mode.')
        exit (Get-UnlockExitCode -Category UserActionRequired)
    }
    $post = Read-JsonFile -Path $PostUnlockReportPath -Label 'Post-unlock report'
    if (-not (Test-PersistentRootReadback -Profile $profile -Snapshot $post)) {
        [Console]::Error.WriteLine('ERROR: Post-unlock evidence does not prove persistent KernelSU root after an ordinary reboot.')
        exit (Get-UnlockExitCode -Category DeviceStateChanged)
    }
    Write-Host 'PASS: post-unlock evidence proves the recorded profile, ordinary reboot, unlocked/orange state, KernelSU 3.2.5, and uid=0(root).'
    exit (Get-UnlockExitCode -Category Success)
}

if ([string]::IsNullOrWhiteSpace($StageReportPath)) {
    [Console]::Error.WriteLine('ERROR: -StageReportPath is required in Plan mode.')
    exit (Get-UnlockExitCode -Category UserActionRequired)
}
if ([string]::IsNullOrWhiteSpace($Serial)) {
    [Console]::Error.WriteLine('ERROR: -Serial is required to bind local state to one ADB transport.')
    exit (Get-UnlockExitCode -Category UserActionRequired)
}
if ($Serial -notmatch '^[A-Za-z0-9._:-]+$') {
    [Console]::Error.WriteLine('ERROR: Serial contains unsupported characters.')
    exit (Get-UnlockExitCode -Category UserActionRequired)
}
$stageReport = Read-JsonFile -Path $StageReportPath -Label 'Read-only stage report'
$stage = [pscustomobject]@{
    ProfileId = [string]$stageReport.profileId
    EvidenceClass = [string]$stageReport.evidenceClass
    TargetSlot = [string]$stageReport.targetSlot
    LkPartitionBytes = [int64]$stageReport.lkPartitionBytes
    LkStockPrefixSha256 = [string]$stageReport.lkStockPrefixSha256
    InitBootPartitionBytes = [int64]$stageReport.initBootPartitionBytes
    InitBootStockSha256 = [string]$stageReport.initBootStockSha256
    LkBackupSha256 = $LkBackupSha256
    InitBootBackupSha256 = $InitBootBackupSha256
    LocalBackupsPresent = $LocalBackupsPresent.IsPresent
}

$assetPaths = @{
    KernelSu = Join-Path $AssetDirectory $manifest.assets.kernelSu.fileName
    GhostLock = Join-Path $AssetDirectory $manifest.assets.ghostLock.fileName
    Lk = Join-Path $AssetDirectory $manifest.assets.lk.fileName
}
$assets = [pscustomobject]@{
    KernelSuValid = (Test-PinnedAsset -Path $assetPaths.KernelSu -Asset $manifest.assets.kernelSu).Valid
    GhostLockValid = (Test-PinnedAsset -Path $assetPaths.GhostLock -Asset $manifest.assets.ghostLock).Valid
    LkValid = (Test-PinnedAsset -Path $assetPaths.Lk -Asset $manifest.assets.lk).Valid
}
if (-not $assets.KernelSuValid -or -not $assets.GhostLockValid -or -not $assets.LkValid) {
    [Console]::Error.WriteLine('ERROR: One or more required assets failed exact byte-length/SHA-256 validation.')
    exit (Get-UnlockExitCode -Category AssetMismatch)
}

$gate = Test-DestructivePrerequisites -Profile $profile -Audit $audit -Assets $assets -Stage $stage -RootAvailable $TemporaryRootAvailable.IsPresent -EnableDestructive:$EnableDestructive.IsPresent -ConfirmationPhrase $ConfirmationPhrase
if (-not $gate.Allowed) {
    Write-Host 'BLOCKED: no destructive command plan was emitted.' -ForegroundColor Red
    foreach ($blocker in $gate.Blockers) { Write-Host (" - {0}" -f $blocker) }
    exit (Get-UnlockExitCode -Category DestructiveGateDenied)
}

$state = New-UnlockWorkflowState -Serial $Serial -Profile $profile -Audit $audit -Assets $assets -Stage $stage
Write-UnlockWorkflowState -State $state -Path $StatePath
$plan = @(Get-DestructiveCommandPlan -Profile $profile -Gate $gate)

Write-Host 'AUTHORIZED PLAN ONLY: this preview does not automatically execute destructive commands.' -ForegroundColor Yellow
foreach ($step in $plan) { Write-Host (" - {0} [{1}; revalidate={2}]" -f $step.Id, $step.Boundary, $step.RequiresRevalidation) }
Write-Host ("Local state: {0}" -f ([IO.Path]::GetFullPath($StatePath)))
exit (Get-UnlockExitCode -Category Success)
