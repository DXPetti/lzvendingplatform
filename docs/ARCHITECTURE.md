# Architecture Overview

## Pipeline Stage Model

The pipeline has eight stages. Stages 0a, 0b, and 0c run before any validation or deployment. Stages 3a and 3b are mutually exclusive based on `workloadCategory`.

```mermaid
flowchart TD
    A([ITSM Request JSON]) --> S0A

    S0A["Stage 0a — Transform\nInvoke-LZVending.ps1 -Stage Transform\nLZTransform.psm1 — pure derivation\nProduces: lz-context.json artifact\nSets ADO routing variables"]

    S0A --> S0B["Stage 0b — Entra Groups\nInvoke-LZVending.ps1 -Stage EntraGroups\nLZEntraGroups.psm1\nCreates contributor + reader groups\nAdds owner to contributor group\nEmits group OIDs as pipeline variables"]

    S0B --> S0C["Stage 0c — Bicep Params\nInvoke-LZVending.ps1 -Stage BicepParams\nLZBicepParams.psm1\nMerges group OIDs into role assignments\nGenerates .generated.bicepparam files"]

    S0C --> S1["Stage 1 — Validate\naz deployment mg what-if\nFully representative preview\nincludes platform group assignments"]

    S1 --> GATE{Approval Gate}

    GATE --> S2["Stage 2 — Deploy Subscription\navm/ptn/lz/sub-vending\nvirtualNetworkEnabled: false\nOutputs: subscriptionId"]

    S2 --> CAT{workloadCategory?}

    CAT -- ApprovedWorkload --> S3A["Stage 3a — Deploy Approved Workload\navm/ptn/aca-lza/hosting-environment\nhubVirtualNetworkResourceId: ''\nOutputs: spokeVNetResourceId"]

    CAT -- BYO --> S3B["Stage 3b — Deploy BYO Networking\nbicep/networking/main.bicep\nVNet · NSG · DNS zone links\nOutputs: virtualNetworkResourceId"]

    S3A --> VWAN{workloadType\n== Private?}
    S3B --> VWAN

    VWAN -- Yes --> S4["Stage 4 — Connect vWAN\naz network vhub connection create\nReads spokeVNetResourceId from\nwhichever Stage 3 ran"]
    VWAN -- No --> END([Done])
    S4 --> END
```

---

## Scripting Module Relationships

```mermaid
flowchart TD
    subgraph orchestrator["scripts/"]
        INV["Invoke-LZVending.ps1\n-Stage Transform | EntraGroups | BicepParams"]
    end

    subgraph modules["scripts/modules/"]
        TRN["LZTransform.psm1\nPure derivation\nNo side effects\nSingle source of truth"]
        ENT["LZEntraGroups.psm1\nEntra group creation\nOwner membership\nIdempotent"]
        BCP["LZBicepParams.psm1\nParam file generation\nRole assignment merge"]
    end

    subgraph artifacts["Pipeline Artifacts"]
        CTX["lz-context.json\nImmutable\nPublished by Stage 0a\nConsumed by 0b and 0c"]
        PRM["generated-bicep-params/\nPublished by Stage 0c\nConsumed by Stages 1–3"]
    end

    INV -- "always calls first" --> TRN
    INV -- "Stage EntraGroups" --> ENT
    INV -- "Stage BicepParams" --> BCP

    TRN --> CTX
    ENT -- "group OIDs via\nADO pipeline variables" --> BCP
    BCP --> PRM
```

---

## Component Relationships

```mermaid
flowchart LR
    subgraph Inputs
        REQ[request.json]
        CFG[customer.config.json]
    end

    subgraph scripts["scripts/"]
        INV[Invoke-LZVending.ps1]
        TRN[LZTransform.psm1]
        ENT[LZEntraGroups.psm1]
        BCP[LZBicepParams.psm1]
        INV --> TRN & ENT & BCP
    end

    subgraph bicep_sub["bicep/subscription/"]
        SUB[main.bicep\navm/ptn/lz/sub-vending]
    end

    subgraph bicep_net["bicep/networking/"]
        NET[main.bicep]
        NSG[modules/nsg.bicep]
        VNET[modules/vnet.bicep]
        DNS[modules/dns-zone-links.bicep]
        NET --> NSG & VNET & DNS
    end

    subgraph bicep_aw["bicep/approved-workloads/aca-lza/"]
        ACA[main.bicep\navm/ptn/aca-lza/hosting-environment]
    end

    subgraph Entra["Entra ID"]
        CG[contributor group]
        RG[reader group]
    end

    subgraph Azure
        MGMT[Management Group]
        NEWSUB[New Subscription]
        VHUB[vWAN Virtual Hub]
    end

    REQ --> INV
    CFG --> INV

    INV -- subscription params\n+ group role assignments --> SUB
    INV -- networking params --> NET
    INV -- aca-lza params --> ACA
    ENT --> CG & RG

    SUB --> MGMT --> NEWSUB
    NET --> NEWSUB
    ACA --> NEWSUB
    CG & RG -- role assignments --> NEWSUB
    NEWSUB -- spokeVNetResourceId --> VHUB
```

---

## Data Flow: Request to Deployment

### 1. Request fields → outcomes

| Field | Value | Effect |
|---|---|---|
| `workloadCategory` | `BYO` | Stage 3b runs; Stage 3a skipped |
| `workloadCategory` | `ApprovedWorkload` | Stage 3a runs; Stage 3b skipped |
| `workloadType` | `Private` | Corp MG · Stage 4 vWAN connect · DNS zone links |
| `workloadType` | `Public` | Online MG · no peering |
| `workloadType` | `Sandbox` | Sandbox MG · isolated |
| `networkSize` | `Small / Medium / Large` | /27 · /26 · /25 (BYO only) |
| `environment` | `Production` | EA `MS-AZR-0017P` · `subscriptionWorkload: Production` |
| `environment` | `NonProduction` | EA `MS-AZR-0148P` · `subscriptionWorkload: DevTest` |
| `approvedWorkload.pattern` | `ContainerApps` | `bicep/approved-workloads/aca-lza/main.bicep` |
| `tags.Owner` | any email | Resolved to Entra OID · added to contributor group |

### 2. Stage 0a — Transform outputs

`LZTransform.psm1` produces the immutable `lz-context.json` artifact and emits these ADO variables for downstream stage conditions and deployment commands:

| Variable | Example |
|---|---|
| `lzResourceBaseName` | `contoso-prod-ecommerce-api` |
| `lzSubscriptionAliasName` | `contoso-prod-ecommerce-api` |
| `lzManagementGroupId` | `mg-contoso-corp` |
| `lzWorkloadCategory` | `BYO` |
| `lzWorkloadType` | `Private` |
| `lzApprovedWorkloadPattern` | `` (empty for BYO) |
| `lzLocation` | `australiaeast` |

### 3. Stage 0b — Entra Groups outputs

`LZEntraGroups.psm1` emits these ADO variables, consumed by Stage 0c:

| Variable | Example |
|---|---|
| `lzContributorGroupOid` | `aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa` |
| `lzContributorGroupName` | `contoso-prod-ecommerce-api-contributor` |
| `lzReaderGroupOid` | `bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb` |
| `lzReaderGroupName` | `contoso-prod-ecommerce-api-reader` |

### 4. Artifact flow

| Artifact | Produced by | Consumed by |
|---|---|---|
| `lz-context` | Stage 0a | Stages 0b, 0c |
| `generated-bicep-params` | Stage 0c | Stages 1, 2, 3a, 3b |
| `deployment-summary` | Stage 4 | — (download manually) |

### 5. Naming convention

All resources follow: `<orgShortName>-<envPrefix>-<workloadName>`

Example: `contoso-prod-ecommerce-api`

`orgShortName` and default `location` are sourced from `customer.config.json`. The env prefix mapping is `Production → prod`, `NonProduction → nonprod`. This logic lives exclusively in `LZTransform.psm1`.

### 6. Tagging

9 tags total — Azure Policy enforced.

| Source | Tags |
|---|---|
| Request (mandatory) | `BusinessUnit` · `CostCentre` · `DataClassification` · `Owner` · `SupportContact` |
| Pipeline (derived) | `DeployedAt` · `DeployedBy` · `Environment` · `WorkloadName` |

---

## Entra ID RBAC Group Design

Two security groups are provisioned in Stage 0b for every LZ, before any validation or deployment runs.

| Group | Naming | Role | Initial Members |
|---|---|---|---|
| Contributor | `<subscriptionAliasName>-contributor` | Contributor | LZ Owner resolved from `tags.Owner` |
| Reader | `<subscriptionAliasName>-reader` | Reader | Empty |

**Why before validation?** Both group OIDs are merged into the subscription bicepparam by Stage 0c (`LZBicepParams.psm1`), so the what-if output in Stage 1 includes the role assignments. Approvers see the complete deployment picture rather than a partial preview.

**Idempotency:** `LZEntraGroups.psm1` checks for an existing group with the expected display name before creating. Re-running the pipeline on the same request reuses existing groups without error.

**Owner resolution failure:** If `az ad user show` cannot resolve the owner email (guest user, shared mailbox, UPN mismatch), Stage 0b logs a warning and continues. Groups are still created and role-assigned; membership is populated manually. A pipeline failure at this point would block subscription creation for a recoverable membership issue — the warning-and-continue approach is deliberate.

**Graph permissions required:** Entra group creation and user lookup require Microsoft Graph API permissions on the WIF service principal, separate from Azure RBAC:

| Permission | Purpose |
|---|---|
| `Group.Create` | Create new security groups |
| `GroupMember.ReadWrite.All` | Add members to groups |
| `User.Read.All` | Resolve owner email to Object ID |

These are granted in Entra ID (App registrations → API permissions → Microsoft Graph) and require admin consent.

---

## vWAN Connectivity Approach

LZA modules (`aca-lza`, `app-service-lza`) accept `hubVirtualNetworkResourceId` — a `Microsoft.Network/virtualNetworks` resource ID. Azure vWAN hubs are `Microsoft.Network/virtualHubs`, a different resource type. Passing a vWAN hub ID into an LZA module would fail ARM validation.

The platform resolves this by setting `hubVirtualNetworkResourceId: ''` in the LZA wrapper and connecting the spoke VNet to the vWAN hub in Stage 4 via:

```bash
az network vhub connection create \
  --name <resourceBaseName>-vhub-conn \
  --vhub-name <parsed from customer.config.json> \
  --resource-group <vwanHubResourceGroupName> \
  --remote-vnet <spokeVNetResourceId from Stage 3>
```

This pattern applies to both BYO Private and ApprovedWorkload Private deployments.
