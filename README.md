# Azure Landing Zone Vending Platform

A generic, reusable platform for provisioning Azure Landing Zones via an Azure DevOps pipeline. Accepts a structured JSON request (sourced from an ITSM tool such as ServiceNow) and provisions a fully configured subscription with networking, management group placement, RBAC, and optional approved workload patterns.

---

## What It Does

| Capability | Detail |
|---|---|
| Subscription provisioning | Dynamic EA subscription via `avm/ptn/lz/sub-vending:0.6.0` |
| Management group placement | Corp / Online / Sandbox — driven by request |
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
│   ├── subscription/                # Step 1 — always runs
│   │   ├── main.bicep
│   │   └── main.bicepparam
│   ├── networking/                  # Step 3 — BYO path only
│   │   ├── main.bicep
│   │   ├── main.bicepparam
│   │   └── modules/
│   │       ├── vnet.bicep
│   │       ├── nsg.bicep
│   │       └── dns-zone-links.bicep
│   └── approved-workloads/
│       └── aca-lza/                 # Step 2 — ContainerApps pattern
│           ├── main.bicep
│           └── main.bicepparam
├── scripts/
│   └── Convert-RequestToBicepParams.ps1
└── pipelines/
    └── lz-vending.yml
```

---

## Deployment Paths

### BYO (Bring Your Own)
Caller provides networking parameters. Platform creates the subscription, VNet, NSG, and optionally links private DNS zones and connects to vWAN.

Supports three connectivity models:

| `workloadType` | Management Group | vWAN | DNS Zone Links |
|---|---|---|---|
| `Private` | Corp | ✅ | ✅ |
| `Public` | Online | ❌ | ❌ |
| `Sandbox` | Sandbox | ❌ | ❌ |

### ApprovedWorkload
Caller selects a pre-validated pattern. Platform deploys the full pattern including its own networking via the relevant LZA AVM module. vWAN is connected via CLI in Step 5 if `workloadType == Private`.

| `pattern` | Module | Status |
|---|---|---|
| `ContainerApps` | `avm/ptn/aca-lza/hosting-environment` | ✅ In scope |
| `AppServiceLZA` | `avm/ptn/app-service-lza/hosting-environment` | 🔜 Future |

---

## Key Design Constraints

- `virtualNetworkEnabled` is **always `false`** in the sub-vending call. Networking is never owned by subscription vending.
- `hubVirtualNetworkResourceId` is **always `''`** in the ACA LZA wrapper. vWAN hubs (`Microsoft.Network/virtualHubs`) are a different resource type from VNet peers — ARM would reject the ID. vWAN connectivity is handled by `az network vhub connection create` in Stage 5.
- All customer-specific values are isolated in `customer.config.json`. No hardcoded values exist in Bicep or pipeline YAML.
- All AVM module references use pinned versions.

---

## AVM Module Versions

| Module | Version |
|---|---|
| `avm/ptn/lz/sub-vending` | `0.6.0` |
| `avm/ptn/aca-lza/hosting-environment` | verify at deploy time |
| `avm/res/resources/resource-group` | `0.4.1` |
| `avm/res/network/network-security-group` | `0.4.0` |
| `avm/res/network/virtual-network` | `0.6.1` |
