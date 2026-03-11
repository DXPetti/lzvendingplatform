# Architecture Overview

## Pipeline Stage Model

The pipeline has five stages. Stages 4a and 4b are mutually exclusive based on `workloadCategory`.

```mermaid
flowchart TD
    A([ITSM Request JSON]) --> S1

    S1["Stage 1 — Transform\nConvert-RequestToBicepParams.ps1\nGenerates .generated.bicepparam files\nSets ADO pipeline variables"]

    S1 --> S2["Stage 2 — Validate\naz deployment mg what-if\nSubscription vending preview"]

    S2 --> GATE{Approval Gate}
    GATE --> S3["Stage 3 — Deploy Subscription\navm/ptn/lz/sub-vending\nvirtualNetworkEnabled: false\nOutputs: subscriptionId"]

    S3 --> CAT{workloadCategory?}

    CAT -- ApprovedWorkload --> S4A["Stage 4a — Deploy Approved Workload\navm/ptn/aca-lza/hosting-environment\nhubVirtualNetworkResourceId: ''\nOutputs: spokeVNetResourceId"]

    CAT -- BYO --> S4B["Stage 4b — Deploy BYO Networking\nbicep/networking/main.bicep\nVNet · NSG · DNS zone links\nOutputs: virtualNetworkResourceId"]

    S4A --> VWAN{workloadType\n== Private?}
    S4B --> VWAN

    VWAN -- Yes --> S5["Stage 5 — Connect vWAN\naz network vhub connection create\nReads spokeVNetResourceId from\nwhichever Stage 4 ran"]
    VWAN -- No --> END([Done])
    S5 --> END
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
        PS1[Convert-RequestToBicepParams.ps1]
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

    subgraph Azure
        MGMT[Management Group]
        NEWSUB[New Subscription]
        VHUB[vWAN Virtual Hub]
    end

    REQ --> PS1
    CFG --> PS1

    PS1 -- subscription params --> SUB
    PS1 -- networking params --> NET
    PS1 -- aca-lza params --> ACA

    SUB --> MGMT --> NEWSUB
    NET --> NEWSUB
    ACA --> NEWSUB
    NEWSUB -- spokeVNetResourceId --> VHUB
```

---

## Data Flow: Request to Deployment

### 1. Request fields → outcomes

| Field | Value | Effect |
|---|---|---|
| `workloadCategory` | `BYO` | Stage 4b runs; Stage 4a skipped |
| `workloadCategory` | `ApprovedWorkload` | Stage 4a runs; Stage 4b skipped |
| `workloadType` | `Private` | Corp MG · Stage 5 vWAN connect · DNS zone links |
| `workloadType` | `Public` | Online MG · no peering |
| `workloadType` | `Sandbox` | Sandbox MG · isolated |
| `networkSize` | `Small / Medium / Large` | /27 · /26 · /25 (BYO only) |
| `environment` | `Production` | EA `MS-AZR-0017P` · `subscriptionWorkload: Production` |
| `environment` | `NonProduction` | EA `MS-AZR-0148P` · `subscriptionWorkload: DevTest` |
| `approvedWorkload.pattern` | `ContainerApps` | `bicep/approved-workloads/aca-lza/main.bicep` |

### 2. Transform script outputs

The PowerShell transform script always writes `bicep/subscription/main.generated.bicepparam` and conditionally writes the networking or approved-workload param file. It also emits these ADO variables for downstream stages:

| Variable | Example |
|---|---|
| `lzSubscriptionAliasName` | `contoso-prod-ecommerce-api` |
| `lzManagementGroupId` | `mg-contoso-corp` |
| `lzWorkloadCategory` | `BYO` |
| `lzWorkloadType` | `Private` |
| `lzApprovedWorkloadPattern` | `` (empty for BYO) |
| `lzResourceBaseName` | `contoso-prod-ecommerce-api` |

### 3. Naming convention

All resources follow: `<orgShortName>-<env>-<workloadName>`

Example: `contoso-prod-ecommerce-api`

`orgShortName` and default `location` are sourced from `customer.config.json`.

### 4. Tagging

9 tags total — Azure Policy enforced.

| Source | Tags |
|---|---|
| Request (mandatory) | `BusinessUnit` · `CostCentre` · `DataClassification` · `Owner` · `SupportContact` |
| Pipeline (derived) | `DeployedAt` · `DeployedBy` · `Environment` · `WorkloadName` |

---

## vWAN Connectivity Approach

LZA modules (`aca-lza`, `app-service-lza`) accept `hubVirtualNetworkResourceId` — a `Microsoft.Network/virtualNetworks` resource ID. Azure vWAN hubs are `Microsoft.Network/virtualHubs`, a different resource type. Passing a vWAN hub ID into an LZA module would fail ARM validation.

The platform resolves this by setting `hubVirtualNetworkResourceId: ''` in the LZA wrapper and connecting the spoke VNet to the vWAN hub in Stage 5 via:

```bash
az network vhub connection create \
  --name <resourceBaseName>-vhub-conn \
  --vhub-name <parsed from customer.config.json> \
  --resource-group <vwanHubResourceGroupName> \
  --remote-vnet <spokeVNetResourceId from Stage 4>
```

This pattern applies to both BYO Private and ApprovedWorkload Private deployments.
