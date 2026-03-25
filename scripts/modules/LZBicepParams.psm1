# ==============================================================================
# scripts/modules/LZBicepParams.psm1
#
# PURPOSE:
#   Generates all .generated.bicepparam files from the LZ Context and the
#   Entra group OIDs produced by LZEntraGroups.
#
# FILES PRODUCED:
#   Always:
#     bicep/subscription/main.generated.bicepparam
#   BYO only:
#     bicep/networking/main.generated.bicepparam
#   ApprovedWorkload / ContainerApps only:
#     bicep/approved-workloads/aca-lza/main.generated.bicepparam
#
# ROLE ASSIGNMENT MERGE:
#   This module merges request-specified role assignments (from the Context)
#   with platform-provisioned group assignments (from the EntraGroups object).
#   The subscription bicepparam always contains the full merged set, so the
#   what-if output in Stage 1 is fully representative.
#
# BUILT-IN ROLE DEFINITION IDs (stable across all Azure tenants):
#   Contributor : b24988ac-6180-42a0-ab88-20f7382dd24c
#   Reader      : acdd72a7-3385-48ef-bd42-f606fba81ae7
#
# FIX — property name quoting:
#   Bicep object literals require property names containing non-identifier
#   characters (dots, hyphens, spaces, etc.) to be single-quoted.
#   resourceProviders keys such as 'Microsoft.ContainerRegistry' contain dots
#   and must be rendered as:
#       'Microsoft.ContainerRegistry': []
#   not:
#       Microsoft.ContainerRegistry: []   ← BCP018 parse error
#   ConvertTo-BicepParamValue now quotes any property name that contains a
#   character outside [a-zA-Z0-9_].
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RoleDefinitionIds = @{
    Contributor = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
    Reader      = '/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
}

# ── Private helpers ────────────────────────────────────────────────────────────

function Write-LZLog {
    param([string]$Message)
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts][INFO] $Message"
}

function Format-BicepPropertyName {
    <#
    .SYNOPSIS
        Returns a Bicep-safe property name.
        Names containing characters outside [a-zA-Z0-9_] are single-quoted
        so that Bicep parses them as string keys rather than identifiers.
        Examples:
          BusinessUnit              → BusinessUnit          (no quotes needed)
          Microsoft.ContainerRegistry → 'Microsoft.ContainerRegistry'  (dot requires quoting)
    #>
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -match '[^a-zA-Z0-9_]') {
        return "'$($Name -replace "'", "\\'")'"
    }
    return $Name
}

function ConvertTo-BicepParamValue {
    <#
    .SYNOPSIS
        Recursively converts a PowerShell value to its Bicep param file representation.
    #>
    param($Value, [int]$IndentLevel = 0)

    $indent  = '  ' * $IndentLevel
    $indent1 = '  ' * ($IndentLevel + 1)

    if ($null -eq $Value) { return 'null' }

    switch ($Value.GetType().Name) {
        'Boolean' { return $Value.ToString().ToLower() }
        'Int32'   { return $Value.ToString() }
        'Int64'   { return $Value.ToString() }
        'String'  { return "'$($Value -replace "'", "\\'")'" }

        'PSCustomObject' {
            $props = @($Value.PSObject.Properties | Where-Object MemberType -eq 'NoteProperty')
            if ($props.Count -eq 0) { return '{}' }
            $lines = @('{')
            foreach ($prop in $props) {
                $v       = ConvertTo-BicepParamValue -Value $prop.Value -IndentLevel ($IndentLevel + 1)
                $propKey = Format-BicepPropertyName -Name $prop.Name
                $lines  += "${indent1}${propKey}: $v"
            }
            $lines += "${indent}}"
            return $lines -join "`n"
        }

        'Object[]' {
            if ($Value.Count -eq 0) { return '[]' }
            $lines = @('[')
            foreach ($item in $Value) {
                $v      = ConvertTo-BicepParamValue -Value $item -IndentLevel ($IndentLevel + 1)
                $lines += "${indent1}$v"
            }
            $lines += "${indent}]"
            return $lines -join "`n"
        }

        default {
            if ($Value -is [System.Collections.IDictionary]) {
                if ($Value.Count -eq 0) { return '{}' }
                $lines = @('{')
                foreach ($key in $Value.Keys) {
                    $v       = ConvertTo-BicepParamValue -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
                    $dictKey = Format-BicepPropertyName -Name $key
                    $lines  += "${indent1}${dictKey}: $v"
                }
                $lines += "${indent}}"
                return $lines -join "`n"
            }
            return "'$Value'"
        }
    }
}

function New-BicepParamFile {
    <#
    .SYNOPSIS
        Writes a single .generated.bicepparam file from a param hashtable.
        SecretParams entries are rendered as readEnvironmentVariable() calls.
    #>
    param(
        [Parameter(Mandatory)][string]    $UsingPath,
        [Parameter(Mandatory)][hashtable] $Params,
        [Parameter(Mandatory)][string]    $OutputPath,
        [hashtable]                        $SecretParams = @{}
    )

    $lines = @(
        '// ============================================================',
        '// GENERATED FILE — DO NOT EDIT MANUALLY',
        "// Generated: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'))",
        '// ============================================================',
        '',
        "using '$UsingPath'",
        ''
    )

    foreach ($key in ($Params.Keys | Sort-Object)) {
        if ($SecretParams.ContainsKey($key)) {
            $lines += "param $key = readEnvironmentVariable('$($SecretParams[$key])', '')"
        }
        else {
            $rendered = ConvertTo-BicepParamValue -Value $Params[$key]
            $lines += "param $key = $rendered"
        }
    }

    $dir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    ($lines -join "`n") | Set-Content -Path $OutputPath -Encoding UTF8
    Write-LZLog "Written: $OutputPath"
}

function Merge-LZRoleAssignments {
    <#
    .SYNOPSIS
        Merges request-specified role assignments with the platform-provisioned
        Contributor and Reader group assignments.

        Called by New-LZBicepParams. Not exported.
    #>
    param(
        [array]         $RequestAssignments,   # From Context.RequestRoleAssignments
        [PSCustomObject]$EntraGroups           # From LZEntraGroups. May be $null.
    )

    # Start with request-specified assignments
    [System.Collections.Generic.List[PSCustomObject]]$merged = @()
    if ($RequestAssignments) {
        foreach ($ra in $RequestAssignments) { $merged.Add($ra) }
    }

    # Add platform-provisioned group assignments when group OIDs are available
    if ($null -ne $EntraGroups -and
        -not [string]::IsNullOrWhiteSpace($EntraGroups.ContributorGroupOid) -and
        -not [string]::IsNullOrWhiteSpace($EntraGroups.ReaderGroupOid)) {

        $merged.Add([PSCustomObject]@{
            definition    = $script:RoleDefinitionIds.Contributor
            principalId   = $EntraGroups.ContributorGroupOid
            principalType = 'Group'
            relativeScope = '/'
        })

        $merged.Add([PSCustomObject]@{
            definition    = $script:RoleDefinitionIds.Reader
            principalId   = $EntraGroups.ReaderGroupOid
            principalType = 'Group'
            relativeScope = '/'
        })

        Write-LZLog "Merged platform group assignments: Contributor ($($EntraGroups.ContributorGroupOid)) + Reader ($($EntraGroups.ReaderGroupOid))"
    }
    else {
        Write-LZLog "No Entra group OIDs provided — role assignments contain request-specified entries only."
    }

    return $merged.ToArray()
}

# ── Exported function ──────────────────────────────────────────────────────────

function New-LZBicepParams {
    <#
    .SYNOPSIS
        Generates all .generated.bicepparam files required for the current LZ request.

    .PARAMETER Context
        The LZ Context object — from Invoke-LZTransform or loaded from lz-context.json.

    .PARAMETER EntraGroups
        The Entra group OIDs from New-LZEntraGroups.
        Optional — if $null, platform group role assignments are omitted.

    .PARAMETER OutputDirectory
        Repository root. Bicep param files are written to subdirectories beneath this path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]        [PSCustomObject]$Context,
        [Parameter(Mandatory=$false)] [PSCustomObject]$EntraGroups = $null,
        [Parameter(Mandatory)]        [string]         $OutputDirectory
    )

    Write-LZLog "=== Generating Bicep param files for: $($Context.ResourceBaseName) ==="

    # ── Merge role assignments ─────────────────────────────────────────────────
    $allRoleAssignments = Merge-LZRoleAssignments `
        -RequestAssignments $Context.RequestRoleAssignments `
        -EntraGroups        $EntraGroups

    # roleAssignmentEnabled = true if there are any assignments at all
    $roleAssignmentEnabled = ($allRoleAssignments.Count -gt 0) -or $Context.RequestRoleAssignmentEnabled

    # ── 1. Subscription params (always) ───────────────────────────────────────
    $subParams = [ordered]@{
        subscriptionAliasName         = $Context.SubscriptionAliasName
        subscriptionDisplayName       = $Context.ResourceBaseName
        subscriptionBillingScope      = $Context.BillingScope
        subscriptionWorkload          = $Context.SubscriptionWorkload
        subscriptionManagementGroupId = $Context.ManagementGroupId
        subscriptionTags              = $Context.AllTags
        roleAssignmentEnabled         = $roleAssignmentEnabled
        roleAssignments               = $allRoleAssignments
        resourceProviders             = $Context.ResourceProviders
        enableTelemetry               = $Context.EnableTelemetry
    }

    New-BicepParamFile `
        -UsingPath  './main.bicep' `
        -Params     $subParams `
        -OutputPath (Join-Path $OutputDirectory 'bicep/subscription/main.generated.bicepparam')

    # ── 2. BYO networking params ───────────────────────────────────────────────
    if ($Context.WorkloadCategory -eq 'BYO') {
        Write-LZLog "Generating BYO networking params..."

        $netParams = [ordered]@{
            dnsZonesResourceGroupName       = $Context.DnsZonesResourceGroupName
            dnsZonesSubscriptionId          = $Context.DnsZonesSubscriptionId
            enableTelemetry                 = $Context.EnableTelemetry
            environment                     = $Context.Environment
            location                        = $Context.Location
            privateDnsZoneResourceIds       = $(if ($Context.DnsZoneIds) { @($Context.DnsZoneIds) } else { @() })
            resourceTags                    = $Context.AllTags
            subnets                         = $Context.VNetSubnets
            virtualNetworkAddressPrefix     = $Context.VNetCidr
            virtualNetworkName              = $Context.VNetName
            virtualNetworkResourceGroupName = $Context.VNetRgName
            workloadType                    = $Context.WorkloadType
        }

        New-BicepParamFile `
            -UsingPath  './main.bicep' `
            -Params     $netParams `
            -OutputPath (Join-Path $OutputDirectory 'bicep/networking/main.generated.bicepparam')
    }

    # ── 3. ACA LZA params (ApprovedWorkload / ContainerApps) ──────────────────
    if ($Context.WorkloadCategory -eq 'ApprovedWorkload' -and
        $Context.ApprovedWorkloadPattern -eq 'ContainerApps') {
        Write-LZLog "Generating ACA LZA params..."

        $sl = $Context.SubnetLayout
        $aw = $Context.AcaConfig

        $acaParams = [ordered]@{
            applicationGatewayCertificateKeyName       = $aw.CertKeyName
            deploymentSubnetAddressPrefix              = $sl.DeploySubnet
            enableApplicationInsights                  = $aw.EnableApplicationInsights
            enableDaprInstrumentation                  = $aw.EnableDaprInstrumentation
            enableTelemetry                            = $Context.EnableTelemetry
            exposeContainerAppsWith                    = $aw.ExposeWith
            location                                   = $Context.Location
            spokeApplicationGatewaySubnetAddressPrefix = $sl.AppGwSubnet
            spokeInfraSubnetAddressPrefix              = $sl.InfraSubnet
            spokePrivateEndpointsSubnetAddressPrefix   = $sl.PeSubnet
            spokeVNetAddressPrefixes                   = @($aw.SpokeVNetAddressSpace)
            tags                                       = $Context.AllTags
            vmJumpBoxSubnetAddressPrefix               = $sl.JumpboxSubnet
            vmSize                                     = $aw.VmSize
            # vmAdminPassword rendered as readEnvironmentVariable() — see SecretParams below
            workloadName                               = $Context.WorkloadName
        }

        New-BicepParamFile `
            -UsingPath   './main.bicep' `
            -Params      $acaParams `
            -SecretParams @{ vmAdminPassword = 'LZ_VM_ADMIN_PASSWORD' } `
            -OutputPath  (Join-Path $OutputDirectory 'bicep/approved-workloads/aca-lza/main.generated.bicepparam')
    }

    Write-LZLog "=== Bicep param generation complete ==="
}

Export-ModuleMember -Function New-LZBicepParams
