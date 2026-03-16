# Azure Landing Zone Vending Platform

A generic, reusable platform for provisioning Azure Landing Zones via an Azure DevOps pipeline. Accepts a structured JSON request (sourced from an ITSM tool such as ServiceNow) and provisions a fully configured subscription with networking, management group placement, RBAC, Entra ID security groups, and optional approved workload patterns.

---

## What It Does

| Capability | Detail |
|---|---|
| Subscription provisioning | Dynamic EA subscription via `avm/ptn/lz/sub-vending:0.6.0` |
| Management group placement | Corp / Online / Sandbox — driven by request |
| Entra ID RBAC groups | Two security groups provisioned per LZ: `<name>-contributor` and `<name>-reader`. LZ owner auto-added to contributor group. |
| BYO networking | VNet, NSG, subnets, private DNS zone links |
| Approved workloads | ACA Landing Zone Accelerator (ContainerApps pattern) |
| vWAN connectivity | Hub connection created post-deployment via CLI |
| Tagging | 5 mandatory request tags + 4 pipeline-derived tags |
| ITSM integration | V1: JSON file committed to repo, pipeline triggered manually |

---

## Repository Structure

```
lz-vending/
├── schema/
│   ├── request.schema.json          # JSON Schema (draft-07) for request validation
│   └── request.example.json         # 3 example scenarios
├── config/
│   └── customer.config.json         # All customer-specific values (MGs, billing, vWAN, DNS)
├── bicep/
│   ├── subscription/                # Stage 2 — always runs
│   │   ├── main.bicep
│   │   └── main.bicepparam
│   ├── networking/                  # Stage 3b — BYO path only
│   │   ├── main.bicep
│   │   ├── main.bicepparam
│   │   └── modules/
│   │       ├── vnet.bicep
│   │       ├── nsg.bicep
│   │       └── dns-zone-links.bicep
│   └── approved-workloads/
│       └── aca-lza/                 # Stage 3a — ContainerApps pattern
│           ├── main.bicep
│           └── main.bicepparam
├── scripts/
│   ├── Invoke-LZVending.ps1         # Pipeline orchestrator — one entry point per stage
│   └── modules/
│       ├── LZTransform.psm1         # Pure derivation logic — single source of truth for all naming
│       ├── LZEntraGroups.psm1       # Entra ID group provisioning
│       └── LZBicepParams.psm1       # Bicep param file generation
└── pipelines/
    └── lz-vending.yml
```

---

## Scripting Architecture

The pipeline PowerShell work is split across three focused modules and a single orchestrator. `Invoke-LZVending.ps1` is the only script the pipeline calls — it accepts a `-Stage` parameter that maps directly to each pipeline stage.

| Module | Responsibility |
|---|---|
| `LZTransform.psm1` | Pure derivation of all computed values from request + config. No side effects. Single source of truth for naming conventions, CIDR derivation, MG/billing mapping, and tag composition. |
| `LZEntraGroups.psm1` | Creates the `<name>-contributor` and `<name>-reader` Entra security groups. Resolves the owner email to an Object ID and adds them to the contributor group. Idempotent. |
| `LZBicepParams.psm1` | Generates all `.generated.bicepparam` files. Merges request-specified role assignments with the platform-provisioned group assignments in a single pass. |

The transform module is always called first by the orchestrator — even in stages that only need group OIDs or param files — so there is never a second implementation of the naming convention anywhere in the codebase.

---

## Deployment Paths

### BYO (Bring Your Own)
Caller provides networking parameters. Platform creates the subscription, Entra groups, VNet, NSG, and optionally links private DNS zones and connects to vWAN.

| `workloadType` | Management Group | vWAN | DNS Zone Links |
|---|---|---|---|
| `Private` | Corp | ✅ | ✅ |
| `Public` | Online | ❌ | ❌ |
| `Sandbox` | Sandbox | ❌ | ❌ |

### ApprovedWorkload
Caller selects a pre-validated pattern. Platform deploys the full pattern including its own networking via the relevant LZA AVM module. Entra groups are provisioned in the same way as BYO. vWAN is connected via CLI in Stage 4 if `workloadType == Private`.

| `pattern` | Module | Status |
|---|---|---|
| `ContainerApps` | `avm/ptn/aca-lza/hosting-environment` | ✅ In scope |
| `AppServiceLZA` | `avm/ptn/app-service-lza/hosting-environment` | 🔜 Future |

---

## Entra ID RBAC Groups

For every LZ provisioned, two Entra ID security groups are created in Stage 0b:

| Group | Naming | Azure RBAC Role | Initial Membership |
|---|---|---|---|
| Contributor | `<subscriptionAliasName>-contributor` | Contributor | LZ Owner (from `tags.Owner`) |
| Reader | `<subscriptionAliasName>-reader` | Reader | Empty — populated by workload team |

Both groups and their role assignments are included in the subscription bicepparam before the what-if runs, so approvers see the full deployment picture in the Stage 1 preview.

Group creation is idempotent — re-running the pipeline on the same request reuses existing groups rather than failing.

---

## Key Design Constraints

- `virtualNetworkEnabled` is **always `false`** in the sub-vending call. Networking is never owned by subscription vending.
- `hubVirtualNetworkResourceId` is **always `''`** in the ACA LZA wrapper. vWAN hubs (`Microsoft.Network/virtualHubs`) are a different resource type from VNet peers — ARM would reject the ID. vWAN connectivity is handled by `az network vhub connection create` in Stage 4.
- All customer-specific values are isolated in `customer.config.json`. No hardcoded values exist in Bicep or pipeline YAML.
- All AVM module references use pinned versions.
- `LZTransform.psm1` is the only place naming and derivation logic lives. Nothing else in the pipeline derives these values independently.

---

## AVM Module Versions

| Module | Version |
|---|---|
| `avm/ptn/lz/sub-vending` | `0.6.0` |
| `avm/ptn/aca-lza/hosting-environment` | verify at deploy time |
| `avm/res/resources/resource-group` | `0.4.1` |
| `avm/res/network/network-security-group` | `0.4.0` |
| `avm/res/network/virtual-network` | `0.6.1` |
