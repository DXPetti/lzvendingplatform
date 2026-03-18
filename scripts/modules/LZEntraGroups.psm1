# ==============================================================================
# scripts/modules/LZEntraGroups.psm1
#
# PURPOSE:
#   Provisions the standard Entra ID security groups for a new Landing Zone.
#   Adds the LZ owner as a member of the Contributor group.
#
# GROUPS CREATED PER LZ:
#   <subscriptionAliasName>-contributor  → Azure RBAC Contributor role
#   <subscriptionAliasName>-reader       → Azure RBAC Reader role
#
# MEMBERSHIP:
#   Contributor group: populated with the Owner from the request tags.
#   Reader group: created but left empty — populated by the workload team.
#
# REQUIRES:
#   Azure CLI authenticated with Microsoft Graph permissions:
#     Group.Create (or GroupMember.ReadWrite.All)
#     User.Read.All
#   These are Entra ID permissions, separate from Azure RBAC.
#   Grant via: App registrations → API permissions → Microsoft Graph.
#
# IDEMPOTENT:
#   If a group already exists with the expected display name, it is reused.
#   If the owner cannot be resolved, a warning is logged and membership
#   is skipped — the group and its role assignment still proceed.
# ==============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Private helpers ────────────────────────────────────────────────────────────

function Write-LZLog {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')
    Write-Host "[$ts][$Level] $Message"
}

function Get-OrNew-LZEntraGroup {
    <#
    .SYNOPSIS
        Returns the Object ID of an existing group, or creates it if absent.
        Idempotent — safe to call on every pipeline run.
    #>
    param([Parameter(Mandatory)][string]$DisplayName)

    Write-LZLog "Checking for existing group: $DisplayName"

    $existing = az ad group list `
        --display-name $DisplayName `
        --query "[0].id" `
        --output tsv 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($existing)) {
        Write-LZLog "Group already exists: $DisplayName ($existing)"
        return $existing.Trim()
    }

    Write-LZLog "Creating group: $DisplayName"

    # mail-nickname must be alphanumeric + hyphens only
    $mailNickname = ($DisplayName -replace '[^a-zA-Z0-9]', '-') -replace '-{2,}', '-'

    $oid = az ad group create `
        --display-name  $DisplayName `
        --mail-nickname $mailNickname `
        --query id `
        --output tsv

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($oid)) {
        throw "Failed to create Entra group '$DisplayName'. Exit code: $LASTEXITCODE"
    }

    Write-LZLog "Created group: $DisplayName ($($oid.Trim()))"
    return $oid.Trim()
}

function Resolve-LZOwnerObjectId {
    <#
    .SYNOPSIS
        Resolves an Entra user Object ID from an email / UPN.
        Returns $null (with a warning) if the user cannot be found —
        the pipeline continues without failing.
    #>
    param([Parameter(Mandatory)][string]$OwnerEmail)

    Write-LZLog "Resolving Entra Object ID for owner: $OwnerEmail"

    $oid = az ad user show `
        --id    $OwnerEmail `
        --query id `
        --output tsv 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($oid)) {
        Write-Warning "Could not resolve Entra Object ID for '$OwnerEmail'."
        Write-Warning "This may be a guest user, shared mailbox, or UPN mismatch."
        Write-Warning "The Contributor group will be created and role-assigned, but no member will be added."
        Write-Warning "Populate the group membership manually after deployment."
        return $null
    }

    Write-LZLog "Resolved: $OwnerEmail → $($oid.Trim())"
    return $oid.Trim()
}

function Add-LZGroupMemberIfAbsent {
    param(
        [Parameter(Mandatory)][string]$GroupOid,
        [Parameter(Mandatory)][string]$MemberOid,
        [Parameter(Mandatory)][string]$GroupDisplayName
    )

    $isMember = az ad group member check `
        --group     $GroupOid `
        --member-id $MemberOid `
        --query value `
        --output tsv 2>$null

    if ($isMember -eq 'true') {
        Write-LZLog "Member already present in $GroupDisplayName — skipping add."
        return
    }

    # Retry up to 5 times with 10 second backoff to handle Entra replication lag
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        az ad group member add `
            --group     $GroupOid `
            --member-id $MemberOid | Out-Null

        if ($LASTEXITCODE -eq 0) {
            Write-LZLog "Added member to $GroupDisplayName."
            return
        }

        if ($attempt -lt 5) {
            Write-LZLog "Attempt $attempt failed — waiting 10 seconds for Entra replication..."
            Start-Sleep -Seconds 10
        }
    }

    Write-Warning "Failed to add member $MemberOid to group $GroupDisplayName after 5 attempts. Continuing."
}

# ── Exported function ──────────────────────────────────────────────────────────

function New-LZEntraGroups {
    <#
    .SYNOPSIS
        Creates the standard Contributor and Reader security groups for a new LZ.
        Adds the LZ owner as a member of the Contributor group.

    .PARAMETER Context
        The LZ Context object returned by Invoke-LZTransform (or loaded from
        the lz-context.json artifact via ConvertFrom-Json).

    .OUTPUTS
        PSCustomObject with:
          ContributorGroupOid   — Entra Object ID of the contributor group
          ContributorGroupName  — Display name of the contributor group
          ReaderGroupOid        — Entra Object ID of the reader group
          ReaderGroupName       — Display name of the reader group
    #>
    [CmdletBinding()]
    [OutputType([PSCustomObject])]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Context
    )

    $subAlias             = $Context.SubscriptionAliasName
    $contributorGroupName = "$subAlias-contributor"
    $readerGroupName      = "$subAlias-reader"

    Write-LZLog "=== Provisioning Entra Groups for: $subAlias ==="

    # Create (or retrieve) both groups
    $contributorOid = Get-OrNew-LZEntraGroup -DisplayName $contributorGroupName
    $readerOid      = Get-OrNew-LZEntraGroup -DisplayName $readerGroupName

    # Resolve owner and add to contributor group
    if (-not [string]::IsNullOrWhiteSpace($Context.OwnerEmail)) {
        $ownerOid = Resolve-LZOwnerObjectId -OwnerEmail $Context.OwnerEmail
        if ($ownerOid) {
            Add-LZGroupMemberIfAbsent `
                -GroupOid        $contributorOid `
                -MemberOid       $ownerOid `
                -GroupDisplayName $contributorGroupName
        }
    }
    else {
        Write-Warning "OwnerEmail is empty in context — skipping group member assignment."
    }

    Write-LZLog "=== Entra Group Provisioning Complete ==="
    Write-LZLog "  Contributor: $contributorGroupName  OID: $contributorOid"
    Write-LZLog "  Reader:      $readerGroupName  OID: $readerOid"

    return [PSCustomObject]@{
        ContributorGroupOid  = $contributorOid
        ContributorGroupName = $contributorGroupName
        ReaderGroupOid       = $readerOid
        ReaderGroupName      = $readerGroupName
    }
}

Export-ModuleMember -Function New-LZEntraGroups
