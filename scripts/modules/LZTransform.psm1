# ==============================================================================
# scripts/modules/LZTransform.psm1
#
# PURPOSE:
#   Pure transform logic. Derives every computed value from the request JSON
#   and customer config. No side effects, no file writes, no Azure API calls.
#
# THIS IS THE SINGLE SOURCE OF TRUTH for:
#   - Resource naming conventions
#   - CIDR / subnet layout derivation
#   - Management group mapping
#   - Billing scope mapping
#   - Tag composition
#
# Any stage that needs a derived value calls Invoke-LZTransform.
# Nothing else in the pipeline derives these values independently.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Private helper functions ───────────────────────────────────────────────────
# Not exported — internal to this module only.

function Get-LZCidrFromNetworkSize {
    param([Parameter(Mandatory)][string]$NetworkSize)
    switch ($NetworkSize) {
        'Small'  { return 27 }
        'Medium' { return 26 }
        'Large'  { return 25 }
        default  { throw "Unknown networkSize '$NetworkSize'. Valid values: Small, Medium, Large." }
    }
}

function Get-LZManagementGroupId {
    param(
        [Parameter(Mandatory)][string]       $WorkloadType,
        [Parameter(Mandatory)][PSCustomObject]$ManagementGroups
    )
    switch ($WorkloadType) {
        'Private' { return $ManagementGroups.corp }
        'Public'  { return $ManagementGroups.online }
        'Sandbox' { return $ManagementGroups.sandbox }
        default   { throw "Unknown workloadType '$WorkloadType'. Valid values: Private, Public, Sandbox." }
    }
}

function Get-LZBillingScope {
    param(
        [Parameter(Mandatory)][string]       $Environment,
        [Parameter(Mandatory)][PSCustomObject]$BillingScopes
    )
    switch ($Environment) {
        'Production'    { return $BillingScopes.production }
        'NonProduction' { return $BillingScopes.nonProduction }
        default         { throw "Unknown environment '$Environment'. Valid values: Production, NonProduction." }
    }
}

function Get-LZSubscriptionWorkload {
    param([Parameter(Mandatory)][string]$Environment)
    switch ($Environment) {
        'Production'    { return 'Production' }
        'NonProduction' { return 'DevTest' }
        default         { throw "Unknown environment '$Environment'." }
    }
}

function Get-LZEnvPrefix {
    param([Parameter(Mandatory)][string]$Environment)
    switch ($Environment) {
        'Production'    { return 'prod' }
        'NonProduction' { return 'nonprod' }
        default         { throw "Unknown environment '$Environment'." }
    }
}

function Get-LZACASubnetLayout {
    <#
    .SYNOPSIS
        Derives the five ACA LZA subnet prefixes from a /21 spoke address space.

    .NOTES
        Layout for a /21 (e.g. 10.70.0.0/21 → 10.70.7.255):
          Offset +0.0/23  → infra subnet       (512 IPs — ACA managed env)
          Offset +2.0/27  → private endpoints  (32 IPs)
          Offset +2.32/27 → jump box VM        (32 IPs)
          Offset +3.0/24  → Application Gateway (256 IPs)
          Offset +4.0/24  → deployment script  (256 IPs)
    #>
    param([Parameter(Mandatory)][string]$SpokeVNetAddressSpace)

    $parts   = $SpokeVNetAddressSpace -split '/'
    $octets  = $parts[0].Split('.')
    $o1 = [int]$octets[0]
    $o2 = [int]$octets[1]
    $o3 = [int]$octets[2]

    return [PSCustomObject]@{
        InfraSubnet   = "$o1.$o2.$o3.0/23"
        PeSubnet      = "$o1.$o2.$($o3+2).0/27"
        JumpboxSubnet = "$o1.$o2.$($o3+2).32/27"
        AppGwSubnet   = "$o1.$o2.$($o3+3).0/24"
        DeploySubnet  = "$o1.$o2.$($o3+4).0/24"
    }
}

# ── Exported function ──────────────────────────────────────────────────────────

function Invoke-LZTransform {
    <#
    .SYNOPSIS
        Reads request.json and customer.config.json, derives all computed values,
        and returns a strongly-typed PSCustomObject (the LZ Context).

    .DESCRIPTION
        Pure function. No side effects. No Azure calls. No file writes.
        The returned object is the single source of truth consumed by all
        downstream modules (LZEntraGroups, LZBicepParams).

    .PARAMETER RequestFilePath
        Path to the ITSM request JSON file.

    .PARAMETER CustomerConfigPath
        Path to config/customer.config.json.

    .OUTPUTS
        PSCustomObject — the LZ Context. Serialisable to JSON via ConvertTo-Json -Depth 10.
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][string]$RequestFilePath,
        [Parameter(Mandatory)][string]$CustomerConfigPath
    )

    # ── Load inputs ────────────────────────────────────────────────────────────
    if (-not (Test-Path $RequestFilePath))    { throw "Request file not found: $RequestFilePath" }
    if (-not (Test-Path $CustomerConfigPath)) { throw "Customer config not found: $CustomerConfigPath" }

    $request = Get-Content $RequestFilePath    -Raw | ConvertFrom-Json
    $config  = Get-Content $CustomerConfigPath -Raw | ConvertFrom-Json

    # ── Validate required top-level fields ─────────────────────────────────────
    foreach ($field in @('workloadName', 'workloadCategory', 'environment', 'tags')) {
        if (-not $request.PSObject.Properties[$field]) {
            throw "Required field missing from request: '$field'"
        }
    }

    $workloadCategory = $request.workloadCategory
    $environment      = $request.environment
    $workloadName     = $request.workloadName

    if ($workloadCategory -notin @('ApprovedWorkload', 'BYO')) {
        throw "workloadCategory must be 'ApprovedWorkload' or 'BYO'. Got: '$workloadCategory'"
    }

    # ── Core derived values ────────────────────────────────────────────────────
    $envPrefix        = Get-LZEnvPrefix           -Environment $environment
    $orgShortName     = $config.defaults.orgShortName
    $location         = $config.defaults.location
    $resourceBaseName = "$orgShortName-$envPrefix-$workloadName"

    $billingScope         = Get-LZBillingScope         -Environment $environment -BillingScopes $config.billingScopes
    $subscriptionWorkload = Get-LZSubscriptionWorkload -Environment $environment

    # ── Workload type and management group ─────────────────────────────────────
    # BYO: workloadType is a top-level field.
    # ApprovedWorkload: workloadType lives inside approvedWorkload object (defaults to 'Private').
    $workloadType = $null
    if ($workloadCategory -eq 'BYO') {
        if (-not $request.PSObject.Properties['workloadType']) {
            throw "workloadType is required for BYO workloads."
        }
        $workloadType = $request.workloadType
    }
    else {
        $workloadType = if (
            $request.PSObject.Properties['approvedWorkload'] -and
            $request.approvedWorkload.PSObject.Properties['workloadType']
        ) { $request.approvedWorkload.workloadType } else { 'Private' }
    }

    $managementGroupId = Get-LZManagementGroupId -WorkloadType $workloadType -ManagementGroups $config.managementGroups

    # ── Tags (5 request + 4 pipeline-derived = 9 total) ───────────────────────
    $deployedAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $allTags = [PSCustomObject]@{
        BusinessUnit       = $request.tags.BusinessUnit
        CostCentre         = $request.tags.CostCentre
        DataClassification = $request.tags.DataClassification
        Owner              = $request.tags.Owner
        SupportContact     = $request.tags.SupportContact
        Environment        = $environment
        WorkloadName       = $workloadName
        DeployedAt         = $deployedAt
        DeployedBy         = 'lz-vending-pipeline'
    }

    # ── Request-specified role assignments ─────────────────────────────────────
    # NOTE: Platform-provisioned group assignments (Contributor/Reader) are NOT
    # added here — they are merged in LZBicepParams after Entra groups are created.
    $requestRoleAssignmentEnabled = $false
    $requestRoleAssignments       = @()
    if ($request.PSObject.Properties['roleAssignments'] -and
        $request.roleAssignments -and
        $request.roleAssignments.Count -gt 0) {
        $requestRoleAssignmentEnabled = $true
        foreach ($ra in $request.roleAssignments) {
            $requestRoleAssignments += [PSCustomObject]@{
                definition    = $ra.roleDefinitionId
                principalId   = $ra.principalId
                principalType = $ra.principalType
                relativeScope = '/'
            }
        }
    }

    # ── Resource providers ─────────────────────────────────────────────────────
    $resourceProviders = [PSCustomObject]@{}
    if ($request.PSObject.Properties['resourceProviders'] -and $request.resourceProviders) {
        $resourceProviders = $request.resourceProviders
    }

    $enableTelemetry = if ($config.PSObject.Properties['enableTelemetry']) {
        [bool]$config.enableTelemetry
    } else {
        Write-Warning "enableTelemetry not found in customer.config.json — defaulting to false."
        $false
    }

    # Owner email — used by LZEntraGroups to add member to contributor group
    $ownerEmail = $request.tags.Owner

    # ── BYO networking values ──────────────────────────────────────────────────
    $vnetCidr    = $null
    $vnetName    = $null
    $vnetRgName  = $null
    $dnsZoneIds  = @()

    if ($workloadCategory -eq 'BYO') {
        if (-not $request.PSObject.Properties['networkSize'])   { throw "networkSize is required for BYO workloads." }
        if (-not $request.PSObject.Properties['baseIpAddress']) { throw "baseIpAddress is required for BYO workloads." }

        $cidrLength = Get-LZCidrFromNetworkSize -NetworkSize $request.networkSize
        $vnetCidr   = "$($request.baseIpAddress)/$cidrLength"
        $vnetName   = "vnet-$resourceBaseName"
        $vnetRgName = "rg-$resourceBaseName-networking"

        if ($workloadType -eq 'Private') {
            $dnsZoneIds = @($config.privateDnsZones)
        }
    }

    # ── Hub connectivity config ────────────────────────────────────────────────
    # Read from customer.config.json — organisational topology decision, not
    # something the requester controls. Validated here so misconfiguration fails
    # fast at Stage 0a rather than silently at Stage 4 connection time.

    if (-not $config.PSObject.Properties['hub']) {
        throw "customer.config.json is missing the 'hub' block. Add hub.type ('vWAN' or 'VNet') and the relevant resource fields."
    }

    $hubType = $config.hub.type

    if ($hubType -notin @('vWAN', 'VNet')) {
        throw "customer.config.json hub.type must be 'vWAN' or 'VNet'. Got: '$hubType'"
    }

    if ($hubType -eq 'vWAN' -and [string]::IsNullOrWhiteSpace($config.hub.vwanHubResourceId)) {
        throw "customer.config.json hub.vwanHubResourceId must be populated when hub.type is 'vWAN'."
    }

    if ($hubType -eq 'VNet' -and [string]::IsNullOrWhiteSpace($config.hub.vnetHubResourceId)) {
        throw "customer.config.json hub.vnetHubResourceId must be populated when hub.type is 'VNet'."
    }

    # ── ApprovedWorkload values ────────────────────────────────────────────────
    $approvedWorkloadPattern = ''
    $subnetLayout            = $null
    $acaConfig               = $null

    if ($workloadCategory -eq 'ApprovedWorkload') {
        if (-not $request.PSObject.Properties['approvedWorkload']) {
            throw "approvedWorkload object is required when workloadCategory is 'ApprovedWorkload'."
        }
        $aw      = $request.approvedWorkload
        $pattern = $aw.pattern
        $approvedWorkloadPattern = $pattern

        switch ($pattern) {
            'ContainerApps' {
                $subnetLayout = Get-LZACASubnetLayout -SpokeVNetAddressSpace $aw.spokeVNetAddressSpace
                $acaConfig = [PSCustomObject]@{
                    SpokeVNetAddressSpace     = $aw.spokeVNetAddressSpace
                    ExposeWith                = $aw.exposeWith
                    CertKeyName               = $aw.certKeyName
                    VmSize                    = $aw.vmSize
                    EnableApplicationInsights = [bool]$aw.enableApplicationInsights
                    EnableDaprInstrumentation = [bool]$aw.enableDaprInstrumentation
                }
            }
            default { throw "Unsupported approvedWorkload.pattern: '$pattern'" }
        }
    }

    # ── Return context object ──────────────────────────────────────────────────
    return [PSCustomObject]@{
        # Identity
        ResourceBaseName              = $resourceBaseName
        SubscriptionAliasName         = $resourceBaseName
        WorkloadName                  = $workloadName

        # Subscription
        ManagementGroupId             = $managementGroupId
        BillingScope                  = $billingScope
        SubscriptionWorkload          = $subscriptionWorkload
        Location                      = $location

        # Routing
        WorkloadCategory              = $workloadCategory
        WorkloadType                  = $workloadType
        ApprovedWorkloadPattern       = $approvedWorkloadPattern
        HubType                       = $hubType

        # Tags and telemetry
        AllTags                       = $allTags
        EnableTelemetry               = $enableTelemetry

        # RBAC (request-specified only; platform groups added in BicepParams stage)
        RequestRoleAssignmentEnabled  = $requestRoleAssignmentEnabled
        RequestRoleAssignments        = $requestRoleAssignments
        ResourceProviders             = $resourceProviders

        # Owner (for Entra group membership)
        OwnerEmail                    = $ownerEmail

        # BYO networking (null for ApprovedWorkload)
        VNetCidr                      = $vnetCidr
        VNetName                      = $vnetName
        VNetRgName                    = $vnetRgName
        DnsZoneIds                    = $dnsZoneIds
        DnsZonesSubscriptionId        = $config.dnsZonesSubscriptionId
        DnsZonesResourceGroupName     = $config.dnsZonesResourceGroupName

        # ApprovedWorkload (null for BYO)
        SubnetLayout                  = $subnetLayout
        AcaConfig                     = $acaConfig
    }
}

Export-ModuleMember -Function Invoke-LZTransform