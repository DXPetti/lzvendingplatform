<#
.SYNOPSIS
    Transforms a JSON landing zone request into one or more .generated.bicepparam files
    and optionally sets Azure DevOps pipeline variables.

.DESCRIPTION
    Reads a request JSON file and a customer config JSON file, validates the inputs,
    derives all computed values (CIDR, naming, MG ID, billing scope, subnet layout),
    and writes the appropriate .generated.bicepparam files to the correct subdirectories.

    Always writes:
        bicep/subscription/main.generated.bicepparam

    Conditionally writes:
        bicep/networking/main.generated.bicepparam           (BYO only)
        bicep/approved-workloads/<pattern>/main.generated.bicepparam  (ApprovedWorkload only)

    When -SetADOVariables is specified, emits ##vso[task.setvariable] commands
    so downstream pipeline stages can consume the values.

.PARAMETER RequestFilePath
    Path to the ITSM request JSON file.

.PARAMETER CustomerConfigPath
    Path to customer.config.json. Defaults to 'config/customer.config.json' relative
    to the script's parent directory.

.PARAMETER OutputDirectory
    Root of the repository. Bicep param files are written relative to this path.
    Defaults to the script's parent directory.

.PARAMETER SetADOVariables
    When present, emits ADO logging commands to set pipeline variables.

.EXAMPLE
    ./Convert-RequestToBicepParams.ps1 `
        -RequestFilePath requests/ecommerce-api.json `
        -SetADOVariables
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $RequestFilePath,

    [Parameter(Mandatory = $false)]
    [string] $CustomerConfigPath,

    [Parameter(Mandatory = $false)]
    [string] $OutputDirectory,

    [Parameter(Mandatory = $false)]
    [switch] $SetADOVariables
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region ── Helpers ────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$ts][$Level] $Message"
}

function Set-ADOVariable {
    param([string]$Name, [string]$Value, [switch]$IsSecret)
    if ($IsSecret) {
        Write-Host "##vso[task.setvariable variable=$Name;isSecret=true]$Value"
    } else {
        Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
    }
    Write-Log "ADO variable set: $Name = $(if ($IsSecret) { '***' } else { $Value })"
}

function Get-CidrFromNetworkSize {
    param([string]$NetworkSize)
    switch ($NetworkSize) {
        'Small'  { return 27 }
        'Medium' { return 26 }
        'Large'  { return 25 }
        default  { throw "Unknown networkSize: $NetworkSize" }
    }
}

function Get-ManagementGroupId {
    param([string]$WorkloadType, [PSCustomObject]$ManagementGroups)
    switch ($WorkloadType) {
        'Private' { return $ManagementGroups.corp }
        'Public'  { return $ManagementGroups.online }
        'Sandbox' { return $ManagementGroups.sandbox }
        default   { throw "Unknown workloadType: $WorkloadType" }
    }
}

function Get-BillingScope {
    param([string]$Environment, [PSCustomObject]$BillingScopes)
    switch ($Environment) {
        'Production'    { return $BillingScopes.production }
        'NonProduction' { return $BillingScopes.nonProduction }
        default         { throw "Unknown environment: $Environment" }
    }
}

function Get-SubscriptionWorkload {
    param([string]$Environment)
    switch ($Environment) {
        'Production'    { return 'Production' }
        'NonProduction' { return 'DevTest' }
        default         { throw "Unknown environment: $Environment" }
    }
}

function Get-EnvPrefix {
    param([string]$Environment)
    switch ($Environment) {
        'Production'    { return 'prod' }
        'NonProduction' { return 'nonprod' }
        default         { throw "Unknown environment: $Environment" }
    }
}

function ConvertTo-BicepParamValue {
    <#
    .SYNOPSIS
        Converts a PowerShell value to its Bicep parameter file string representation.
    #>
    param($Value, [int]$IndentLevel = 0)
    $indent  = '  ' * $IndentLevel
    $indent1 = '  ' * ($IndentLevel + 1)

    if ($null -eq $Value) { return 'null' }

    switch ($Value.GetType().Name) {
        'Boolean'       { return $Value.ToString().ToLower() }
        'Int32'         { return $Value.ToString() }
        'Int64'         { return $Value.ToString() }
        'String'        { return "'$($Value -replace "'", "\\\'")'" }
        'PSCustomObject' {
            $props = $Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' }
            if (-not $props) { return '{}' }
            $lines = @('{')
            foreach ($prop in $props) {
                $v = ConvertTo-BicepParamValue -Value $prop.Value -IndentLevel ($IndentLevel + 1)
                $lines += "${indent1}$($prop.Name): $v"
            }
            $lines += "${indent}}"
            return $lines -join "`n"
        }
        'Object[]' {
            if ($Value.Count -eq 0) { return '[]' }
            $lines = @('[')
            foreach ($item in $Value) {
                $v = ConvertTo-BicepParamValue -Value $item -IndentLevel ($IndentLevel + 1)
                $lines += "${indent1}$v"
            }
            $lines += "${indent}]"
            return $lines -join "`n"
        }
        default {
            # Hashtable
            if ($Value -is [System.Collections.IDictionary]) {
                if ($Value.Count -eq 0) { return '{}' }
                $lines = @('{')
                foreach ($key in $Value.Keys) {
                    $v = ConvertTo-BicepParamValue -Value $Value[$key] -IndentLevel ($IndentLevel + 1)
                    $lines += "${indent1}${key}: $v"
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
        Writes a .bicepparam file from a hashtable of parameter name -> value.
    #>
    param(
        [string] $UsingPath,
        [hashtable] $Params,
        [string] $OutputPath,
        [hashtable] $SecretParams = @{}
    )

    $lines = @()
    $lines += "// ============================================================"
    $lines += "// GENERATED FILE — DO NOT EDIT MANUALLY"
    $lines += "// Generated: $(Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC)"
    $lines += "// ============================================================"
    $lines += ""
    $lines += "using '$UsingPath'"
    $lines += ""

    foreach ($key in $Params.Keys | Sort-Object) {
        $val = $Params[$key]
        if ($SecretParams.ContainsKey($key)) {
            $lines += "param $key = readEnvironmentVariable('$($SecretParams[$key])', '')"
        } else {
            $rendered = ConvertTo-BicepParamValue -Value $val
            $lines += "param $key = $rendered"
        }
    }

    $dir = Split-Path -Path $OutputPath -Parent
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $lines -join "`n" | Set-Content -Path $OutputPath -Encoding UTF8
    Write-Log "Written: $OutputPath"
}

#endregion

#region ── Load and validate inputs ───────────────────────────────────────────

# Resolve paths
$scriptRoot = $PSScriptRoot
if (-not $OutputDirectory) {
    $OutputDirectory = Split-Path -Path $scriptRoot -Parent
}
if (-not $CustomerConfigPath) {
    $CustomerConfigPath = Join-Path $OutputDirectory 'config/customer.config.json'
}

Write-Log "Request file:     $RequestFilePath"
Write-Log "Customer config:  $CustomerConfigPath"
Write-Log "Output directory: $OutputDirectory"

if (-not (Test-Path $RequestFilePath)) {
    throw "Request file not found: $RequestFilePath"
}
if (-not (Test-Path $CustomerConfigPath)) {
    throw "Customer config not found: $CustomerConfigPath"
}

$request = Get-Content $RequestFilePath -Raw | ConvertFrom-Json
$config  = Get-Content $CustomerConfigPath -Raw | ConvertFrom-Json

# Basic validation
$requiredFields = @('workloadName', 'workloadCategory', 'environment', 'tags')
foreach ($field in $requiredFields) {
    if (-not $request.PSObject.Properties[$field]) {
        throw "Required field missing from request: $field"
    }
}

$workloadCategory = $request.workloadCategory
$environment      = $request.environment
$workloadName     = $request.workloadName

Write-Log "workloadCategory: $workloadCategory"
Write-Log "environment:      $environment"
Write-Log "workloadName:     $workloadName"

if ($workloadCategory -notin @('ApprovedWorkload', 'BYO')) {
    throw "workloadCategory must be 'ApprovedWorkload' or 'BYO'. Got: $workloadCategory"
}

#endregion

#region ── Derived values ─────────────────────────────────────────────────────

$envPrefix       = Get-EnvPrefix -Environment $environment
$orgShortName    = $config.defaults.orgShortName
$location        = $config.defaults.location
$resourceBaseName = "$orgShortName-$envPrefix-$workloadName"
$subscriptionAliasName = $resourceBaseName

# Billing scope and subscription workload
$billingScope       = Get-BillingScope -Environment $environment -BillingScopes $config.billingScopes
$subscriptionWorkload = Get-SubscriptionWorkload -Environment $environment

# Management group — derived from workloadType or approvedWorkload.workloadType
$mgWorkloadType = $null
if ($workloadCategory -eq 'BYO') {
    $mgWorkloadType = $request.workloadType
} elseif ($workloadCategory -eq 'ApprovedWorkload') {
    # ApprovedWorkload defaults to Private unless explicitly set to Public
    $mgWorkloadType = if ($request.approvedWorkload.PSObject.Properties['workloadType']) {
        $request.approvedWorkload.workloadType
    } else {
        'Private'
    }
}
$managementGroupId = Get-ManagementGroupId -WorkloadType $mgWorkloadType -ManagementGroups $config.managementGroups

# Pipeline-derived tags (merged with request tags)
$deployedAt = Get-Date -Format 'yyyy-MM-ddTHH:mm:ssZ' -AsUTC
$allTags = @{
    BusinessUnit      = $request.tags.BusinessUnit
    CostCentre        = $request.tags.CostCentre
    DataClassification = $request.tags.DataClassification
    Owner             = $request.tags.Owner
    SupportContact    = $request.tags.SupportContact
    Environment       = $environment
    WorkloadName      = $workloadName
    DeployedAt        = $deployedAt
    DeployedBy        = 'lz-vending-pipeline'
}

# Role assignments — convert to array of objects expected by sub-vending
$roleAssignmentsEnabled = $false
$roleAssignments = @()
if ($request.PSObject.Properties['roleAssignments'] -and $request.roleAssignments.Count -gt 0) {
    $roleAssignmentsEnabled = $true
    foreach ($ra in $request.roleAssignments) {
        $roleAssignments += [PSCustomObject]@{
            definition    = $ra.roleDefinitionId
            principalId   = $ra.principalId
            principalType = $ra.principalType
            relativeScope = '/'
        }
    }
}

# Resource providers
$resourceProviders = @{}
if ($request.PSObject.Properties['resourceProviders']) {
    foreach ($prop in $request.resourceProviders.PSObject.Properties) {
        $resourceProviders[$prop.Name] = $prop.Value
    }
}

$enableTelemetry = if ($request.PSObject.Properties['enableTelemetry']) { $request.enableTelemetry } else { $true }

Write-Log "resourceBaseName:    $resourceBaseName"
Write-Log "managementGroupId:   $managementGroupId"
Write-Log "billingScope:        $billingScope"
Write-Log "subscriptionWorkload: $subscriptionWorkload"

#endregion

#region ── Step 1 — Subscription params (always) ─────────────────────────────

$subParams = [ordered]@{
    subscriptionAliasName                    = $subscriptionAliasName
    subscriptionDisplayName                  = $resourceBaseName
    subscriptionBillingScope                 = $billingScope
    subscriptionWorkload                     = $subscriptionWorkload
    subscriptionManagementGroupId            = $managementGroupId
    subscriptionTags                         = $allTags
    roleAssignmentEnabled                    = $roleAssignmentsEnabled
    roleAssignments                          = $roleAssignments
    resourceProviders                        = $resourceProviders
    enableTelemetry                          = $enableTelemetry
}

$subParamFile = Join-Path $OutputDirectory 'bicep/subscription/main.generated.bicepparam'
New-BicepParamFile `
    -UsingPath './main.bicep' `
    -Params $subParams `
    -OutputPath $subParamFile

#endregion

#region ── Step 3 — BYO networking params ─────────────────────────────────────

if ($workloadCategory -eq 'BYO') {

    if (-not $request.PSObject.Properties['workloadType']) { throw "workloadType required for BYO" }
    if (-not $request.PSObject.Properties['networkSize'])  { throw "networkSize required for BYO" }
    if (-not $request.PSObject.Properties['baseIpAddress']){ throw "baseIpAddress required for BYO" }

    $workloadType = $request.workloadType
    $cidrLength   = Get-CidrFromNetworkSize -NetworkSize $request.networkSize
    $vnetCidr     = "$($request.baseIpAddress)/$cidrLength"
    $vnetName     = "vnet-$resourceBaseName"
    $vnetRgName   = "rg-$resourceBaseName-networking"

    # DNS zones only for Private workloads
    $dnsZoneIds = @()
    if ($workloadType -eq 'Private') {
        $dnsZoneIds = $config.privateDnsZones
    }

    $netParams = [ordered]@{
        location                       = $location
        virtualNetworkAddressPrefix    = $vnetCidr
        virtualNetworkName             = $vnetName
        virtualNetworkResourceGroupName = $vnetRgName
        workloadType                   = $workloadType
        resourceTags                   = $allTags
        privateDnsZoneResourceIds      = $dnsZoneIds
        dnsZonesSubscriptionId         = $config.dnsZonesSubscriptionId
        dnsZonesResourceGroupName      = $config.dnsZonesResourceGroupName
    }

    $netParamFile = Join-Path $OutputDirectory 'bicep/networking/main.generated.bicepparam'
    New-BicepParamFile `
        -UsingPath './main.bicep' `
        -Params $netParams `
        -OutputPath $netParamFile
}

#endregion

#region ── Step 2 — ApprovedWorkload params ───────────────────────────────────

$approvedWorkloadPattern = ''

if ($workloadCategory -eq 'ApprovedWorkload') {

    if (-not $request.PSObject.Properties['approvedWorkload']) {
        throw "approvedWorkload object required when workloadCategory is 'ApprovedWorkload'"
    }

    $aw      = $request.approvedWorkload
    $pattern = $aw.pattern
    $approvedWorkloadPattern = $pattern

    switch ($pattern) {

        'ContainerApps' {

            # Derive subnet layout from the spoke /21 space
            # The ACA LZA module owns subnet creation; we pass individual subnet prefixes.
            # Layout (for a /21 = 10.x.x.0 – 10.x.7.255):
            #   /23 infra           e.g. 10.70.0.0/23  (512 IPs — ACA infra)
            #   /27 private-eps     e.g. 10.70.2.0/27  (32 IPs)
            #   /27 jumpbox         e.g. 10.70.2.32/27 (32 IPs)
            #   /24 app-gateway     e.g. 10.70.3.0/24  (256 IPs)
            #   /24 deployment      e.g. 10.70.4.0/24  (256 IPs — deployment script subnet)

            $spokeBase   = $aw.spokeVNetAddressSpace   # e.g. 10.70.0.0/21
            $baseOctets  = ($spokeBase -split '/')[0].Split('.')
            $o1 = [int]$baseOctets[0]; $o2 = [int]$baseOctets[1]; $o3 = [int]$baseOctets[2]

            $infraSubnet    = "$o1.$o2.$o3.0/23"
            $peSubnet       = "$o1.$o2.$($o3+2).0/27"
            $jumpboxSubnet  = "$o1.$o2.$($o3+2).32/27"
            $appGwSubnet    = "$o1.$o2.$($o3+3).0/24"
            $deploySubnet   = "$o1.$o2.$($o3+4).0/24"

            $acaParams = [ordered]@{
                workloadName                                = $workloadName
                location                                    = $location
                spokeVNetAddressPrefixes                    = @($aw.spokeVNetAddressSpace)
                spokeInfraSubnetAddressPrefix               = $infraSubnet
                spokePrivateEndpointsSubnetAddressPrefix    = $peSubnet
                vmJumpBoxSubnetAddressPrefix                = $jumpboxSubnet
                spokeApplicationGatewaySubnetAddressPrefix  = $appGwSubnet
                deploymentSubnetAddressPrefix               = $deploySubnet
                exposeContainerAppsWith                     = $aw.exposeWith
                applicationGatewayCertificateKeyName        = $aw.certKeyName
                vmSize                                      = $aw.vmSize
                enableApplicationInsights                   = $aw.enableApplicationInsights
                enableDaprInstrumentation                   = $aw.enableDaprInstrumentation
                # hubVirtualNetworkResourceId intentionally omitted from params —
                # it is hardcoded to '' in the Bicep wrapper.
                # vWAN is connected via Step 4 (az network vhub connection create).
                tags                                        = $allTags
                enableTelemetry                             = $enableTelemetry
            }

            $acaParamFile = Join-Path $OutputDirectory "bicep/approved-workloads/aca-lza/main.generated.bicepparam"
            New-BicepParamFile `
                -UsingPath './main.bicep' `
                -Params $acaParams `
                -SecretParams @{ vmAdminPassword = 'LZ_VM_ADMIN_PASSWORD' } `
                -OutputPath $acaParamFile
        }

        default {
            throw "Unsupported approvedWorkload.pattern: $pattern"
        }
    }
}

#endregion

#region ── ADO variable output ────────────────────────────────────────────────

$lzWorkloadType    = if ($workloadCategory -eq 'BYO') { $request.workloadType } else {
    if ($request.approvedWorkload.PSObject.Properties['workloadType']) {
        $request.approvedWorkload.workloadType
    } else { 'Private' }
}

Write-Log "=== Computed pipeline variables ==="
Write-Log "lzSubscriptionAliasName:   $subscriptionAliasName"
Write-Log "lzManagementGroupId:       $managementGroupId"
Write-Log "lzWorkloadCategory:        $workloadCategory"
Write-Log "lzWorkloadType:            $lzWorkloadType"
Write-Log "lzApprovedWorkloadPattern: $approvedWorkloadPattern"
Write-Log "lzResourceBaseName:        $resourceBaseName"

if ($SetADOVariables) {
    Set-ADOVariable -Name 'lzSubscriptionAliasName'   -Value $subscriptionAliasName
    Set-ADOVariable -Name 'lzManagementGroupId'        -Value $managementGroupId
    Set-ADOVariable -Name 'lzWorkloadCategory'         -Value $workloadCategory
    Set-ADOVariable -Name 'lzWorkloadType'             -Value $lzWorkloadType
    Set-ADOVariable -Name 'lzApprovedWorkloadPattern'  -Value $approvedWorkloadPattern
    Set-ADOVariable -Name 'lzResourceBaseName'         -Value $resourceBaseName
}

Write-Log "Transform complete."

#endregion
