<#
.SYNOPSIS
    Orchestrates the LZ Vending pipeline stages.

.DESCRIPTION
    Single entry point for all pipeline PowerShell work. Delegates to the
    appropriate module based on the -Stage parameter. Each stage maps to
    exactly one module doing exactly one job.

    Stage 0a — Transform:
        Reads request.json + customer.config.json.
        Derives all computed values via LZTransform.psm1 (pure, no side effects).
        Serialises the LZ Context to an immutable lz-context.json artifact.
        Emits ADO pipeline variables for downstream stage conditions.

    Stage 0b — EntraGroups:
        Reads lz-context.json artifact.
        Creates <subscriptionAliasName>-contributor and -reader Entra groups.
        Adds LZ owner as a member of the contributor group.
        Emits group OIDs as ADO pipeline variables for Stage 0c.

    Stage 0c — BicepParams:
        Reads lz-context.json artifact + group OID pipeline variables.
        Generates all .generated.bicepparam files in a single pass.
        Group role assignments are included so what-if (Stage 1) is fully representative.

.PARAMETER Stage
    Which stage to execute. Must be one of: Transform, EntraGroups, BicepParams.

.PARAMETER RequestFilePath
    Path to the ITSM request JSON file. Required for Transform.

.PARAMETER CustomerConfigPath
    Path to config/customer.config.json. Required for Transform.
    Defaults to 'config/customer.config.json' relative to the OutputDirectory.

.PARAMETER ContextArtifactPath
    Path to the lz-context.json artifact. Required for EntraGroups and BicepParams.

.PARAMETER OutputDirectory
    Repository root directory. Required for Transform (artifact output) and BicepParams.
    Bicepparam files are written to subdirectories beneath this path.

.PARAMETER ContributorGroupOid
    Entra Object ID of the contributor group. Required for BicepParams.
    Passed in from the lzContributorGroupOid ADO pipeline variable set by Stage 0b.

.PARAMETER ReaderGroupOid
    Entra Object ID of the reader group. Required for BicepParams.
    Passed in from the lzReaderGroupOid ADO pipeline variable set by Stage 0b.

.PARAMETER SetADOVariables
    When present, emits ##vso[task.setvariable] commands for downstream stages.

.EXAMPLE
    # Stage 0a — Transform
    ./Invoke-LZVending.ps1 `
        -Stage              Transform `
        -RequestFilePath    requests/ecommerce-api.json `
        -CustomerConfigPath config/customer.config.json `
        -OutputDirectory    . `
        -SetADOVariables

    # Stage 0b — EntraGroups (run inside AzureCLI@2 for az auth)
    ./Invoke-LZVending.ps1 `
        -Stage               EntraGroups `
        -ContextArtifactPath $(Pipeline.Workspace)/lz-context/lz-context.json `
        -SetADOVariables

    # Stage 0c — BicepParams
    ./Invoke-LZVending.ps1 `
        -Stage               BicepParams `
        -ContextArtifactPath $(Pipeline.Workspace)/lz-context/lz-context.json `
        -ContributorGroupOid $(lzContributorGroupOid) `
        -ReaderGroupOid      $(lzReaderGroupOid) `
        -OutputDirectory     . `
        -SetADOVariables
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Transform', 'EntraGroups', 'BicepParams')]
    [string]$Stage,

    # Transform inputs
    [string]$RequestFilePath,
    [string]$CustomerConfigPath = 'config/customer.config.json',

    # EntraGroups + BicepParams input
    [string]$ContextArtifactPath,

    # BicepParams inputs
    [string]$OutputDirectory,
    [string]$ContributorGroupOid = '',
    [string]$ReaderGroupOid      = '',

    [switch]$SetADOVariables
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Logging ────────────────────────────────────────────────────────────────────

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts][$Level] $Message"
}

function Set-ADOVariable {
    param([string]$Name, [string]$Value, [switch]$IsSecret)
    if ($IsSecret) {
        Write-Host "##vso[task.setvariable variable=$Name;isOutput=true;isSecret=true]$Value"
    }
    else {
        Write-Host "##vso[task.setvariable variable=$Name;isOutput=true]$Value"
    }
    Write-Log "ADO variable: $Name = $(if ($IsSecret) { '***' } else { $Value })"
}

# ── Module imports ─────────────────────────────────────────────────────────────

$modulesPath = Join-Path $PSScriptRoot 'modules'
Import-Module (Join-Path $modulesPath 'LZTransform.psm1')   -Force
Import-Module (Join-Path $modulesPath 'LZEntraGroups.psm1') -Force
Import-Module (Join-Path $modulesPath 'LZBicepParams.psm1') -Force

Write-Log "=== LZ Vending — Stage: $Stage ==="

# ── Stage dispatch ─────────────────────────────────────────────────────────────

switch ($Stage) {

    # ── 0a: Transform ──────────────────────────────────────────────────────────
    #    Pure derivation. No Azure calls. Produces the immutable lz-context.json.
    # ──────────────────────────────────────────────────────────────────────────

    'Transform' {
        if (-not $RequestFilePath) { throw "-RequestFilePath is required for the Transform stage." }
        if (-not $OutputDirectory) { throw "-OutputDirectory is required for the Transform stage." }

        # Resolve CustomerConfigPath relative to OutputDirectory if not absolute
        if (-not [System.IO.Path]::IsPathRooted($CustomerConfigPath)) {
            $CustomerConfigPath = Join-Path $OutputDirectory $CustomerConfigPath
        }

        Write-Log "Request file:     $RequestFilePath"
        Write-Log "Customer config:  $CustomerConfigPath"
        Write-Log "Output directory: $OutputDirectory"

        $context = Invoke-LZTransform `
            -RequestFilePath    $RequestFilePath `
            -CustomerConfigPath $CustomerConfigPath

        # Serialise context to immutable JSON artifact
        $artifactDir  = Join-Path $OutputDirectory 'artifacts/lz-context'
        $artifactPath = Join-Path $artifactDir 'lz-context.json'

        if (-not (Test-Path $artifactDir)) {
            New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
        }

        $context | ConvertTo-Json -Depth 10 | Set-Content -Path $artifactPath -Encoding UTF8
        Write-Log "Context artifact written: $artifactPath"

        # Emit ADO variables for downstream stage conditions and deployment commands
        if ($SetADOVariables) {
            Set-ADOVariable 'lzResourceBaseName'        $context.ResourceBaseName
            Set-ADOVariable 'lzSubscriptionAliasName'   $context.SubscriptionAliasName
            Set-ADOVariable 'lzManagementGroupId'       $context.ManagementGroupId
            Set-ADOVariable 'lzWorkloadCategory'        $context.WorkloadCategory
            Set-ADOVariable 'lzWorkloadType'            $context.WorkloadType
            Set-ADOVariable 'lzApprovedWorkloadPattern' $context.ApprovedWorkloadPattern
            Set-ADOVariable 'lzLocation'                $context.Location
        }

        Write-Log "Transform complete. ResourceBaseName: $($context.ResourceBaseName)"
    }

    # ── 0b: EntraGroups ────────────────────────────────────────────────────────
    #    Requires Azure CLI auth (az ad commands).
    #    Run this stage inside AzureCLI@2 in the pipeline.
    # ──────────────────────────────────────────────────────────────────────────

    'EntraGroups' {
        if (-not $ContextArtifactPath) { throw "-ContextArtifactPath is required for the EntraGroups stage." }
        if (-not (Test-Path $ContextArtifactPath)) { throw "Context artifact not found: $ContextArtifactPath" }

        Write-Log "Loading context from: $ContextArtifactPath"
        $context = Get-Content $ContextArtifactPath -Raw | ConvertFrom-Json

        $groups = New-LZEntraGroups -Context $context

        if ($SetADOVariables) {
            Set-ADOVariable 'lzContributorGroupOid'  $groups.ContributorGroupOid
            Set-ADOVariable 'lzContributorGroupName' $groups.ContributorGroupName
            Set-ADOVariable 'lzReaderGroupOid'       $groups.ReaderGroupOid
            Set-ADOVariable 'lzReaderGroupName'      $groups.ReaderGroupName
        }

        Write-Log "EntraGroups stage complete."
    }

    # ── 0c: BicepParams ────────────────────────────────────────────────────────
    #    No Azure calls needed. Generates bicepparam files in a single pass.
    #    Group OIDs passed in from Stage 0b ADO variables.
    # ──────────────────────────────────────────────────────────────────────────

    'BicepParams' {
        if (-not $ContextArtifactPath) { throw "-ContextArtifactPath is required for the BicepParams stage." }
        if (-not $OutputDirectory)     { throw "-OutputDirectory is required for the BicepParams stage." }
        if (-not (Test-Path $ContextArtifactPath)) { throw "Context artifact not found: $ContextArtifactPath" }

        Write-Log "Loading context from: $ContextArtifactPath"
        $context = Get-Content $ContextArtifactPath -Raw | ConvertFrom-Json

        # Build EntraGroups object from the pipeline variables passed in
        $entraGroups = $null
        if (-not [string]::IsNullOrWhiteSpace($ContributorGroupOid) -and
            -not [string]::IsNullOrWhiteSpace($ReaderGroupOid)) {
            $entraGroups = [PSCustomObject]@{
                ContributorGroupOid = $ContributorGroupOid
                ReaderGroupOid      = $ReaderGroupOid
            }
            Write-Log "Entra group OIDs received — merging into role assignments."
        }
        else {
            Write-Log "No Entra group OIDs provided — role assignments will contain request-specified entries only."
        }

        New-LZBicepParams `
            -Context         $context `
            -EntraGroups     $entraGroups `
            -OutputDirectory $OutputDirectory

        Write-Log "BicepParams stage complete."
    }
}

Write-Log "=== Stage '$Stage' finished ==="
