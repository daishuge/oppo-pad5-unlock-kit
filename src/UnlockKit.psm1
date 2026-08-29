Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-HexDigest {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value,

        [Parameter(Mandatory = $true)]
        [ValidateSet('md5', 'sha256')]
        [string]$Kind,

        [Parameter(Mandatory = $true)]
        [string]$FieldName
    )

    $length = 64
    if ($Kind -eq 'md5') { $length = 32 }
    if ($Value -notmatch ('^[a-fA-F0-9]{{{0}}}$' -f $length)) {
        throw ('Invalid {0} digest in {1}: expected {2} hexadecimal characters.' -f $Kind.ToUpperInvariant(), $FieldName, $length)
    }
}

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw ('Missing required property {0}.{1}.' -f $Context, $Name)
    }
    return $property.Value
}

function Read-UnlockCompatibilityManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('Compatibility manifest does not exist: {0}' -f $Path)
    }

    try {
        $manifest = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        throw ('Compatibility manifest is not valid JSON: {0}' -f $_.Exception.Message)
    }

    if ([int](Get-RequiredProperty -Object $manifest -Name 'schemaVersion' -Context 'manifest') -ne 1) {
        throw 'Unsupported compatibility manifest schemaVersion; expected 1.'
    }

    $profiles = @(Get-RequiredProperty -Object $manifest -Name 'profiles' -Context 'manifest')
    if ($profiles.Count -lt 1) { throw 'Compatibility manifest contains no profiles.' }

    foreach ($profile in $profiles) {
        $profileId = [string](Get-RequiredProperty -Object $profile -Name 'id' -Context 'profile')
        if ([string]::IsNullOrWhiteSpace($profileId)) { throw 'Compatibility profile id cannot be empty.' }
        $identity = Get-RequiredProperty -Object $profile -Name 'identity' -Context ('profile {0}' -f $profileId)
        foreach ($field in @('model', 'device', 'displayId', 'otaVersion', 'kernel')) {
            $value = [string](Get-RequiredProperty -Object $identity -Name $field -Context ('profile {0}.identity' -f $profileId))
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw ('Compatibility identity field {0} cannot be empty.' -f $field)
            }
        }

        $workflow = Get-RequiredProperty -Object $profile -Name 'workflow' -Context ('profile {0}' -f $profileId)
        if ($workflow.sourceSlot -notin @('_a', '_b') -or $workflow.targetSlot -notin @('_a', '_b')) {
            throw ('Profile {0} contains an invalid slot.' -f $profileId)
        }
        if ($workflow.sourceSlot -eq $workflow.targetSlot) {
            throw ('Profile {0} source and target slots must differ.' -f $profileId)
        }
        if ([int64]$workflow.minimumBatteryPercent -lt 1 -or [int64]$workflow.minimumBatteryPercent -gt 100) {
            throw ('Profile {0} has an invalid battery threshold.' -f $profileId)
        }

        $partitions = Get-RequiredProperty -Object $profile -Name 'partitions' -Context ('profile {0}' -f $profileId)
        Assert-HexDigest -Value ([string]$partitions.lk.stockPrefixSha256) -Kind sha256 -FieldName ('profiles[{0}].partitions.lk.stockPrefixSha256' -f $profileId)
        Assert-HexDigest -Value ([string]$partitions.lk.modifiedSha256) -Kind sha256 -FieldName ('profiles[{0}].partitions.lk.modifiedSha256' -f $profileId)
        Assert-HexDigest -Value ([string]$partitions.initBoot.stagedStockSha256) -Kind sha256 -FieldName ('profiles[{0}].partitions.initBoot.stagedStockSha256' -f $profileId)
        Assert-HexDigest -Value ([string]$partitions.initBoot.kernelSu325PatchedSha256) -Kind sha256 -FieldName ('profiles[{0}].partitions.initBoot.kernelSu325PatchedSha256' -f $profileId)
    }

    $assets = Get-RequiredProperty -Object $manifest -Name 'assets' -Context 'manifest'
    foreach ($assetName in @('kernelSu', 'ghostLock', 'lk', 'ota')) {
        $asset = Get-RequiredProperty -Object $assets -Name $assetName -Context 'manifest.assets'
        if ([int64](Get-RequiredProperty -Object $asset -Name 'bytes' -Context ('manifest.assets.{0}' -f $assetName)) -le 0) {
            throw ('Asset {0} must have a positive byte length.' -f $assetName)
        }
        Assert-HexDigest -Value ([string](Get-RequiredProperty -Object $asset -Name 'sha256' -Context ('manifest.assets.{0}' -f $assetName))) -Kind sha256 -FieldName ('assets.{0}.sha256' -f $assetName)
    }
    if ($null -ne $assets.ota.PSObject.Properties['md5']) {
        Assert-HexDigest -Value ([string]$assets.ota.md5) -Kind md5 -FieldName 'assets.ota.md5'
    }

    $expectedKernelSuUrl = 'https://github.com/tiann/KernelSU/releases/download/v{0}/{1}' -f $assets.kernelSu.version, $assets.kernelSu.fileName
    if ([string]$assets.kernelSu.url -cne $expectedKernelSuUrl) {
        throw ('KernelSU pinned URL does not match its recorded release and file name: {0}' -f $assets.kernelSu.url)
    }
    $expectedLkUrl = 'https://raw.githubusercontent.com/ZincGluxx/OPPO-Pad-5-Unlock/{0}/{1}' -f $assets.lk.version, $assets.lk.fileName
    if ([string]$assets.lk.url -cne $expectedLkUrl) {
        throw ('LK pinned source URL does not match its recorded commit and file name: {0}' -f $assets.lk.url)
    }
    $expectedGhostLockSource = 'https://github.com/YuKongA/ghostlock-app/tree/{0}' -f $assets.ghostLock.version
    if ([string]$assets.ghostLock.sourceUrl -cne $expectedGhostLockSource) {
        throw ('GhostLock pinned source URL does not match its recorded commit: {0}' -f $assets.ghostLock.sourceUrl)
    }

    return $manifest
}

function ConvertFrom-AdbDevices {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $rows = @()
    foreach ($line in ($Text -split "`r?`n")) {
        $trimmed = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed) -or $trimmed -eq 'List of devices attached') { continue }
        $parts = @($trimmed -split '\s+')
        if ($parts.Count -lt 2) { continue }

        $details = @{}
        for ($index = 2; $index -lt $parts.Count; $index++) {
            if ($parts[$index] -match '^([^:]+):(.*)$') {
                $details[$matches[1]] = $matches[2]
            }
        }

        $rows += [pscustomobject]@{
            Serial = $parts[0]
            State = $parts[1]
            Product = $details['product']
            Model = $details['model']
            Device = $details['device']
            TransportId = $details['transport_id']
        }
    }
    return $rows
}

function Select-AdbSerial {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Devices,

        [string]$Serial
    )

    if (-not [string]::IsNullOrWhiteSpace($Serial)) {
        $matches = @($Devices | Where-Object { $_.Serial -eq $Serial })
        if ($matches.Count -ne 1) { throw ('Requested ADB serial was not found exactly once: {0}' -f $Serial) }
        if ($matches[0].State -ne 'device') {
            throw ('Requested ADB device is not authorized/online: state={0}' -f $matches[0].State)
        }
        return [string]$matches[0].Serial
    }

    if ($Devices.Count -eq 0) { throw 'No ADB device was detected.' }
    if ($Devices.Count -gt 1) { throw 'Multiple ADB devices make selection ambiguous; pass -Serial explicitly.' }
    if ($Devices[0].State -ne 'device') {
        throw ('The only ADB transport is not authorized/online: state={0}' -f $Devices[0].State)
    }
    return [string]$Devices[0].Serial
}

function ConvertFrom-FastbootVariables {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Text
    )

    $variables = @{}
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*(?:\(bootloader\)\s*)?([A-Za-z0-9_.-]+)\s*:\s*(.*?)\s*$') {
            $key = $matches[1].ToLowerInvariant()
            $variables[$key] = $matches[2].Trim()
        }
    }
    return $variables
}

function Test-FastbootUnlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Variables
    )

    return (
        $Variables.ContainsKey('unlocked') -and
        $Variables.ContainsKey('secure') -and
        [string]$Variables['unlocked'] -eq 'yes' -and
        [string]$Variables['secure'] -eq 'no'
    )
}

function Resolve-CompatibilityProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Manifest,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    $mapping = [ordered]@{
        model = 'model'
        device = 'device'
        displayId = 'displayId'
        otaVersion = 'otaVersion'
        kernel = 'kernel'
    }

    foreach ($profile in @($Manifest.profiles)) {
        $mismatches = @()
        foreach ($field in $mapping.Keys) {
            $actualProperty = $Snapshot.PSObject.Properties[$mapping[$field]]
            $actual = $null
            if ($null -ne $actualProperty) { $actual = [string]$actualProperty.Value }
            $expected = [string]$profile.identity.$field
            if ($actual -cne $expected) {
                $mismatches += ('{0}: expected={1} actual={2}' -f $field, $expected, $actual)
            }
        }
        if ($mismatches.Count -eq 0) { return $profile }
    }

    $all = @()
    $reference = @($Manifest.profiles)[0]
    foreach ($field in $mapping.Keys) {
        $actualProperty = $Snapshot.PSObject.Properties[$mapping[$field]]
        $actual = '<missing>'
        if ($null -ne $actualProperty) { $actual = [string]$actualProperty.Value }
        $expected = [string]$reference.identity.$field
        if ($actual -cne $expected) {
            $all += ('{0}: expected=[{1}] actual=[{2}]' -f $field, $expected, $actual)
        }
    }
    throw ('Unsupported device identity: {0}' -f ($all -join '; '))
}

function Test-ReadOnlyAdbArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    if ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'devices' -and $Arguments[1] -eq '-l') {
        return $true
    }
    if ($Arguments.Count -lt 5) { return $false }
    if ($Arguments[0] -ne '-s' -or $Arguments[2] -ne 'shell') { return $false }
    if ($Arguments[1] -notmatch '^[A-Za-z0-9._:-]+$') { return $false }

    if ($Arguments.Count -eq 5 -and $Arguments[3] -eq 'getprop' -and $Arguments[4] -in @(
        'ro.product.model',
        'ro.product.device',
        'ro.build.display.id',
        'ro.build.version.ota',
        'ro.boot.slot_suffix',
        'ro.boot.flash.locked',
        'ro.boot.verifiedbootstate'
    )) {
        return $true
    }
    if ($Arguments.Count -eq 5 -and $Arguments[3] -eq 'uname' -and $Arguments[4] -eq '-r') {
        return $true
    }
    if ($Arguments.Count -eq 5 -and $Arguments[3] -eq 'dumpsys' -and $Arguments[4] -eq 'battery') {
        return $true
    }
    if (
        $Arguments.Count -eq 7 -and
        $Arguments[3] -eq 'settings' -and
        $Arguments[4] -eq 'get' -and
        $Arguments[5] -eq 'global' -and
        $Arguments[6] -in @('mobile_data', 'data_roaming')
    ) {
        return $true
    }
    return $false
}

function Invoke-ExternalTool {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Arguments
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf) -and $FilePath -notmatch '^[A-Za-z0-9_.-]+$') {
        throw ('External tool does not exist: {0}' -f $FilePath)
    }

    $lines = @(& $FilePath @Arguments 2>&1 | ForEach-Object { $_.ToString() })
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = ($lines -join "`n")
    }
}

function Invoke-ReadOnlyAdb {
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [scriptblock]$CommandRunner
    )

    if (-not (Test-ReadOnlyAdbArguments -Arguments $Arguments)) {
        throw ('Read-only ADB policy rejected command arguments: {0}' -f ($Arguments -join ' '))
    }

    $result = $null
    if ($null -ne $CommandRunner) {
        $result = & $CommandRunner $AdbPath $Arguments
    }
    else {
        $result = Invoke-ExternalTool -FilePath $AdbPath -Arguments $Arguments
    }
    if ($null -eq $result -or $null -eq $result.PSObject.Properties['ExitCode'] -or $null -eq $result.PSObject.Properties['Output']) {
        throw 'Command runner returned an invalid result object.'
    }
    if ([int]$result.ExitCode -ne 0) {
        throw ('Read-only ADB command failed with exit code {0}: {1}' -f $result.ExitCode, $result.Output)
    }
    return ([string]$result.Output).Trim()
}

function Protect-DeviceSerial {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Serial)

    if ($Serial.Length -le 6) { return ('*' * $Serial.Length) }
    return $Serial.Substring(0, 3) + ('*' * ($Serial.Length - 6)) + $Serial.Substring($Serial.Length - 3, 3)
}

function Invoke-ReadOnlyAudit {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AdbPath,
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [string]$Serial,
        [scriptblock]$CommandRunner
    )

    $manifest = Read-UnlockCompatibilityManifest -Path $ManifestPath
    $devicesText = Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('devices', '-l') -CommandRunner $CommandRunner
    $selectedSerial = Select-AdbSerial -Devices @(ConvertFrom-AdbDevices -Text $devicesText) -Serial $Serial

    function Read-Property {
        param([string]$Name)
        return Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('-s', $selectedSerial, 'shell', 'getprop', $Name) -CommandRunner $CommandRunner
    }

    $batteryText = Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('-s', $selectedSerial, 'shell', 'dumpsys', 'battery') -CommandRunner $CommandRunner
    if ($batteryText -notmatch '(?m)^\s*level:\s*(\d+)\s*$') {
        throw 'Could not parse battery level from dumpsys battery.'
    }

    $snapshot = [pscustomobject]@{
        model = Read-Property -Name 'ro.product.model'
        device = Read-Property -Name 'ro.product.device'
        displayId = Read-Property -Name 'ro.build.display.id'
        otaVersion = Read-Property -Name 'ro.build.version.ota'
        kernel = Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('-s', $selectedSerial, 'shell', 'uname', '-r') -CommandRunner $CommandRunner
        slot = Read-Property -Name 'ro.boot.slot_suffix'
        flashLocked = Read-Property -Name 'ro.boot.flash.locked'
        verifiedBootState = Read-Property -Name 'ro.boot.verifiedbootstate'
        batteryPercent = [int]$matches[1]
        mobileData = Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('-s', $selectedSerial, 'shell', 'settings', 'get', 'global', 'mobile_data') -CommandRunner $CommandRunner
        dataRoaming = Invoke-ReadOnlyAdb -AdbPath $AdbPath -Arguments @('-s', $selectedSerial, 'shell', 'settings', 'get', 'global', 'data_roaming') -CommandRunner $CommandRunner
    }

    $profile = Resolve-CompatibilityProfile -Manifest $manifest -Snapshot $snapshot
    $blockers = @()
    if ($snapshot.slot -cne [string]$profile.workflow.sourceSlot) {
        $blockers += ('source slot mismatch: expected={0} actual={1}; the opposite direction is not validated in this preview' -f $profile.workflow.sourceSlot, $snapshot.slot)
    }
    if ($snapshot.batteryPercent -lt [int]$profile.workflow.minimumBatteryPercent) {
        $blockers += ('battery below threshold: required={0} actual={1}' -f $profile.workflow.minimumBatteryPercent, $snapshot.batteryPercent)
    }
    if ($snapshot.flashLocked -cne [string]$profile.workflow.preUnlockFlashLocked) {
        $blockers += ('flash lock pre-state mismatch: expected={0} actual={1}' -f $profile.workflow.preUnlockFlashLocked, $snapshot.flashLocked)
    }
    if ($snapshot.verifiedBootState -cne [string]$profile.workflow.preUnlockVerifiedBootState) {
        $blockers += ('verified boot pre-state mismatch: expected={0} actual={1}' -f $profile.workflow.preUnlockVerifiedBootState, $snapshot.verifiedBootState)
    }
    if ($snapshot.mobileData -ne '0') { $blockers += ('mobile data is not disabled: actual={0}' -f $snapshot.mobileData) }
    if ($snapshot.dataRoaming -ne '0') { $blockers += ('data roaming is not disabled: actual={0}' -f $snapshot.dataRoaming) }

    return [pscustomobject]@{
        SchemaVersion = 1
        EvidenceClass = 'read-only-audit'
        ProfileId = [string]$profile.id
        SerialMasked = Protect-DeviceSerial -Serial $selectedSerial
        Snapshot = $snapshot
        ReadyForDestructiveWorkflow = ($blockers.Count -eq 0)
        Blockers = @($blockers)
    }
}

function Get-FileSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw ('File does not exist: {0}' -f $Path)
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Test-PinnedAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Asset
    )

    $expectedBytes = [int64](Get-RequiredProperty -Object $Asset -Name 'bytes' -Context 'asset')
    $expectedSha256 = [string](Get-RequiredProperty -Object $Asset -Name 'sha256' -Context 'asset')
    Assert-HexDigest -Value $expectedSha256 -Kind sha256 -FieldName 'asset.sha256'

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{
            Valid = $false
            Path = $Path
            ExpectedBytes = $expectedBytes
            ActualBytes = $null
            ExpectedSha256 = $expectedSha256.ToLowerInvariant()
            ActualSha256 = $null
            Reason = 'missing'
        }
    }

    $item = Get-Item -LiteralPath $Path
    $actualBytes = [int64]$item.Length
    $actualSha256 = Get-FileSha256 -Path $Path
    $valid = ($actualBytes -eq $expectedBytes -and $actualSha256 -ceq $expectedSha256.ToLowerInvariant())
    $reason = 'ok'
    if ($actualBytes -ne $expectedBytes) { $reason = 'byte-length-mismatch' }
    elseif ($actualSha256 -cne $expectedSha256.ToLowerInvariant()) { $reason = 'sha256-mismatch' }

    return [pscustomobject]@{
        Valid = $valid
        Path = $item.FullName
        ExpectedBytes = $expectedBytes
        ActualBytes = $actualBytes
        ExpectedSha256 = $expectedSha256.ToLowerInvariant()
        ActualSha256 = $actualSha256
        Reason = $reason
    }
}

function Receive-PinnedAsset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Asset,
        [Parameter(Mandatory = $true)][string]$DestinationDirectory,
        [scriptblock]$Downloader
    )

    $fileName = [string](Get-RequiredProperty -Object $Asset -Name 'fileName' -Context 'asset')
    if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -ne [IO.Path]::GetFileName($fileName)) {
        throw ('Unsafe asset file name: {0}' -f $fileName)
    }
    $urlProperty = $Asset.PSObject.Properties['url']
    if ($null -eq $urlProperty -or [string]::IsNullOrWhiteSpace([string]$urlProperty.Value)) {
        throw ('Asset {0} has no downloadable URL and must be supplied by the user.' -f $fileName)
    }
    $url = [string]$urlProperty.Value
    if ($url -notmatch '^https://') { throw ('Asset URL must use HTTPS: {0}' -f $url) }

    $destinationRoot = [IO.Path]::GetFullPath($DestinationDirectory)
    if (-not (Test-Path -LiteralPath $destinationRoot)) {
        [void](New-Item -ItemType Directory -Path $destinationRoot)
    }
    $finalPath = Join-Path $destinationRoot $fileName
    $partialPath = $finalPath + '.partial'

    if (Test-Path -LiteralPath $finalPath -PathType Leaf) {
        $existing = Test-PinnedAsset -Path $finalPath -Asset $Asset
        if ($existing.Valid) { return $existing }
        throw ('Existing asset failed validation and will not be overwritten: {0} ({1})' -f $finalPath, $existing.Reason)
    }
    if (Test-Path -LiteralPath $partialPath) {
        Remove-Item -LiteralPath $partialPath -Force
    }

    if ($null -ne $Downloader) {
        & $Downloader $url $partialPath
    }
    else {
        Invoke-WebRequest -Uri $url -OutFile $partialPath -UseBasicParsing
    }

    $check = Test-PinnedAsset -Path $partialPath -Asset $Asset
    if (-not $check.Valid) {
        if (Test-Path -LiteralPath $partialPath) { Remove-Item -LiteralPath $partialPath -Force }
        throw ('Downloaded asset failed byte length/SHA-256 validation: {0} ({1})' -f $fileName, $check.Reason)
    }

    Move-Item -LiteralPath $partialPath -Destination $finalPath
    $finalCheck = Test-PinnedAsset -Path $finalPath -Asset $Asset
    if (-not $finalCheck.Valid) {
        throw ('Asset failed validation after atomic promotion: {0}' -f $finalPath)
    }
    return $finalCheck
}

function Test-DestructivePrerequisites {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Audit,
        [Parameter(Mandatory = $true)]$Assets,
        [Parameter(Mandatory = $true)]$Stage,
        [Parameter(Mandatory = $true)][bool]$RootAvailable,
        [switch]$EnableDestructive,
        [AllowEmptyString()][string]$ConfirmationPhrase = ''
    )

    $blockers = @()
    if (-not $EnableDestructive.IsPresent) {
        $blockers += 'destructive mode was not explicitly enabled'
    }
    if ($ConfirmationPhrase -cne [string]$Profile.workflow.confirmationPhrase) {
        $blockers += 'exact destructive confirmation phrase is missing'
    }
    if ([string]$Audit.ProfileId -cne [string]$Profile.id) {
        $blockers += 'audit profile does not match the selected compatibility profile'
    }
    if (-not [bool]$Audit.ReadyForDestructiveWorkflow) {
        $blockers += 'read-only audit did not declare the device ready'
    }

    $snapshot = $Audit.Snapshot
    if ([string]$snapshot.slot -cne [string]$Profile.workflow.sourceSlot) {
        $blockers += ('live source slot mismatch: expected={0} actual={1}' -f $Profile.workflow.sourceSlot, $snapshot.slot)
    }
    if ([int]$snapshot.batteryPercent -lt [int]$Profile.workflow.minimumBatteryPercent) {
        $blockers += ('live battery is below threshold: required={0} actual={1}' -f $Profile.workflow.minimumBatteryPercent, $snapshot.batteryPercent)
    }
    if ([string]$snapshot.flashLocked -cne [string]$Profile.workflow.preUnlockFlashLocked) {
        $blockers += ('live flash-lock state mismatch: expected={0} actual={1}' -f $Profile.workflow.preUnlockFlashLocked, $snapshot.flashLocked)
    }
    if ([string]$snapshot.verifiedBootState -cne [string]$Profile.workflow.preUnlockVerifiedBootState) {
        $blockers += ('live verified-boot state mismatch: expected={0} actual={1}' -f $Profile.workflow.preUnlockVerifiedBootState, $snapshot.verifiedBootState)
    }
    if (-not $RootAvailable) { $blockers += 'temporary root is not available' }

    foreach ($assetField in @('KernelSuValid', 'GhostLockValid', 'LkValid')) {
        $property = $Assets.PSObject.Properties[$assetField]
        if ($null -eq $property -or -not [bool]$property.Value) {
            $blockers += ('required asset validation failed: {0}' -f $assetField)
        }
    }

    if ([string]$Stage.TargetSlot -cne [string]$Profile.workflow.targetSlot) {
        $blockers += ('staged target slot mismatch: expected={0} actual={1}' -f $Profile.workflow.targetSlot, $Stage.TargetSlot)
    }
    if ([int64]$Stage.LkPartitionBytes -ne [int64]$Profile.partitions.lk.partitionBytes) {
        $blockers += ('LK partition size mismatch: expected={0} actual={1}' -f $Profile.partitions.lk.partitionBytes, $Stage.LkPartitionBytes)
    }
    if ([string]$Stage.LkStockPrefixSha256 -cne [string]$Profile.partitions.lk.stockPrefixSha256) {
        $blockers += 'LK stock-prefix SHA-256 mismatch'
    }
    if ([int64]$Stage.InitBootPartitionBytes -ne [int64]$Profile.partitions.initBoot.partitionBytes) {
        $blockers += ('init_boot partition size mismatch: expected={0} actual={1}' -f $Profile.partitions.initBoot.partitionBytes, $Stage.InitBootPartitionBytes)
    }
    if ([string]$Stage.InitBootStockSha256 -cne [string]$Profile.partitions.initBoot.stagedStockSha256) {
        $blockers += 'init_boot stock SHA-256 mismatch'
    }
    if (-not [bool]$Stage.LocalBackupsPresent) {
        $blockers += 'validated local partition backups are missing'
    }
    foreach ($backupField in @('LkBackupSha256', 'InitBootBackupSha256')) {
        $property = $Stage.PSObject.Properties[$backupField]
        if ($null -eq $property -or [string]$property.Value -notmatch '^[a-fA-F0-9]{64}$') {
            $blockers += ('local backup digest is missing or malformed: {0}' -f $backupField)
        }
    }

    return [pscustomobject]@{
        Allowed = ($blockers.Count -eq 0)
        ProfileId = [string]$Profile.id
        SourceSlot = [string]$Profile.workflow.sourceSlot
        TargetSlot = [string]$Profile.workflow.targetSlot
        Blockers = @($blockers)
    }
}

function Get-DestructiveCommandPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Gate
    )

    if (-not [bool]$Gate.Allowed) { return @() }
    if ([string]$Gate.ProfileId -cne [string]$Profile.id -or
        [string]$Gate.SourceSlot -cne '_b' -or
        [string]$Gate.TargetSlot -cne '_a') {
        throw 'Destructive command planning is restricted to the validated OPD2506 B-to-A profile.'
    }

    return @(
        [pscustomobject]@{ Id = 'write-lk-a'; Boundary = 'device-root-shell'; RequiresRevalidation = $true },
        [pscustomobject]@{ Id = 'set-active-a'; Boundary = 'device-root-shell'; RequiresRevalidation = $true },
        [pscustomobject]@{ Id = 'unlock-and-revalidate'; Boundary = 'host-fastboot'; RequiresRevalidation = $true },
        [pscustomobject]@{ Id = 'flash-init-boot-a'; Boundary = 'host-fastboot'; RequiresRevalidation = $true }
    )
}

function Test-LkWriteReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Readback
    )

    $valid = (
        [int64]$Readback.BytesWritten -eq [int64]$Profile.partitions.lk.modifiedBytes -and
        [string]$Readback.ModifiedSha256 -ceq [string]$Profile.partitions.lk.modifiedSha256 -and
        [bool]$Readback.BlockDeviceReadOnly
    )
    return [pscustomobject]@{ Valid = $valid }
}

function Test-UnlockReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][bool]$HostCommandSucceeded,
        [Parameter(Mandatory = $true)][hashtable]$Variables
    )

    return ($HostCommandSucceeded -and (Test-FastbootUnlocked -Variables $Variables))
}

function Test-PersistentRootReadback {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Snapshot
    )

    return (
        [bool]$Snapshot.BootWasOrdinaryReboot -and
        [string]$Snapshot.Slot -ceq [string]$Profile.workflow.targetSlot -and
        [string]$Snapshot.FlashLocked -ceq [string]$Profile.workflow.postUnlockFlashLocked -and
        [string]$Snapshot.VerifiedBootState -ceq [string]$Profile.workflow.postUnlockVerifiedBootState -and
        [string]$Snapshot.KsudVersion -match '(?:^|\s)3\.2\.5(?:$|\s)' -and
        [string]$Snapshot.IdOutput -match '(?:^|\s)uid=0\(root\)(?:\s|$)'
    )
}

function New-UnlockWorkflowState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Audit,
        [Parameter(Mandatory = $true)]$Assets,
        [Parameter(Mandatory = $true)]$Stage
    )

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        EvidenceClass = 'local-unverified-workflow-state'
        Serial = $Serial
        ProfileId = [string]$Profile.id
        SourceSlot = [string]$Profile.workflow.sourceSlot
        TargetSlot = [string]$Profile.workflow.targetSlot
        Model = [string]$Audit.Snapshot.model
        Device = [string]$Audit.Snapshot.device
        DisplayId = [string]$Audit.Snapshot.displayId
        OtaVersion = [string]$Audit.Snapshot.otaVersion
        Kernel = [string]$Audit.Snapshot.kernel
        LiveSlotAtCreation = [string]$Audit.Snapshot.slot
        BatteryPercentAtCreation = [int]$Audit.Snapshot.batteryPercent
        LkStockPrefixSha256 = [string]$Profile.partitions.lk.stockPrefixSha256
        LkModifiedSha256 = [string]$Profile.partitions.lk.modifiedSha256
        InitBootStockSha256 = [string]$Profile.partitions.initBoot.stagedStockSha256
        PatchedInitBootSha256 = [string]$Profile.partitions.initBoot.kernelSu325PatchedSha256
        LkBackupSha256 = [string]$Stage.LkBackupSha256
        InitBootBackupSha256 = [string]$Stage.InitBootBackupSha256
        LkAssetValidated = [bool]$Assets.LkValid
        KernelSuAssetValidated = [bool]$Assets.KernelSuValid
        GhostLockAssetValidated = [bool]$Assets.GhostLockValid
        CompletedStages = @()
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
    }
}

function Test-UnlockWorkflowResume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Serial,
        [Parameter(Mandatory = $true)]$Profile,
        [Parameter(Mandatory = $true)]$Audit
    )

    return (
        [int]$State.SchemaVersion -eq 1 -and
        [string]$State.Serial -ceq $Serial -and
        [string]$State.ProfileId -ceq [string]$Profile.id -and
        [string]$Audit.ProfileId -ceq [string]$Profile.id -and
        [string]$State.SourceSlot -ceq [string]$Profile.workflow.sourceSlot -and
        [string]$State.TargetSlot -ceq [string]$Profile.workflow.targetSlot -and
        [string]$State.Model -ceq [string]$Audit.Snapshot.model -and
        [string]$State.Device -ceq [string]$Audit.Snapshot.device -and
        [string]$State.DisplayId -ceq [string]$Audit.Snapshot.displayId -and
        [string]$State.OtaVersion -ceq [string]$Audit.Snapshot.otaVersion -and
        [string]$State.Kernel -ceq [string]$Audit.Snapshot.kernel -and
        [string]$State.LiveSlotAtCreation -ceq [string]$Audit.Snapshot.slot
    )
}

function Write-UnlockWorkflowState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)][string]$Path
    )

    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent) }
    $temporary = $fullPath + '.partial'
    [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $temporary -Destination $fullPath -Force
}

function Read-UnlockWorkflowState {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw ('Workflow state does not exist: {0}' -f $Path) }
    $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ([int]$state.SchemaVersion -ne 1) { throw 'Unsupported workflow-state schemaVersion.' }
    return $state
}

Export-ModuleMember -Function @(
    'Read-UnlockCompatibilityManifest',
    'ConvertFrom-AdbDevices',
    'Select-AdbSerial',
    'ConvertFrom-FastbootVariables',
    'Test-FastbootUnlocked',
    'Resolve-CompatibilityProfile',
    'Test-ReadOnlyAdbArguments',
    'Invoke-ExternalTool',
    'Protect-DeviceSerial',
    'Invoke-ReadOnlyAudit',
    'Get-FileSha256',
    'Test-PinnedAsset',
    'Receive-PinnedAsset',
    'Test-DestructivePrerequisites',
    'Get-DestructiveCommandPlan',
    'Test-LkWriteReadback',
    'Test-UnlockReadback',
    'Test-PersistentRootReadback',
    'New-UnlockWorkflowState',
    'Test-UnlockWorkflowResume',
    'Write-UnlockWorkflowState',
    'Read-UnlockWorkflowState'
)
