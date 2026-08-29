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

Export-ModuleMember -Function @(
    'Read-UnlockCompatibilityManifest',
    'ConvertFrom-AdbDevices',
    'Select-AdbSerial',
    'ConvertFrom-FastbootVariables',
    'Test-FastbootUnlocked',
    'Resolve-CompatibilityProfile'
)
