# Quick Start

## Prerequisites

- Azure DevOps organisation and project
- EA billing account with at least two enrollment accounts (Production, NonProduction)
- Existing Management Group hierarchy (Corp, Online, Sandbox)
- Existing hub — Azure vWAN hub or hub VNet (for Private workloads)
- Existing private DNS zones resource group (for Private workloads)
- Service principal or managed identity with permissions to create subscriptions at the EA enrollment account scope

---

## Step 1 — Populate `customer.config.json`

Replace all placeholder values. This is the only file that should contain environment-specific values.

```json
{
  "defaults": {
    "location": "australiaeast",
    "orgShortName": "contoso"
  },
  "billingScopes": {
    "production":    "/providers/Microsoft.Billing/billingAccounts/<id>/enrollmentAccounts/<prod-id>",
    "nonProduction": "/providers/Microsoft.Billing/billingAccounts/<id>/enrollmentAccounts/<dev-id>"
  },
  "managementGroups": {
    "corp":    "mg-contoso-corp",
    "online":  "mg-contoso-online",
    "sandbox": "mg-contoso-sandbox"
  },
  "hub": {
    "type": "vWAN",
    "vwanHubResourceId":        "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualHubs/<hub>",
    "vwanHubResourceGroupName": "rg-vwan-hub-prod",
    "vnetHubResourceId":        "",
    "vnetHubResourceGroupName": ""
  },
  "privateDnsZones":            [ "<zone-resource-id>", "..." ],
  "dnsZonesSubscriptionId":     "<dns-sub-id>",
  "dnsZonesResourceGroupName":  "rg-privatedns-prod"
}
```

---

## Step 2 — Register the Pipeline

1. In Azure DevOps, go to **Pipelines → New pipeline → Azure Repos Git**.
2. Select your repository and point to `pipelines/lz-vending.yml`.
3. Save (do not run yet).

---

## Step 3 — Create the ADO Service Connection

1. In Azure DevOps, go to **Project Settings → Service Connections → New service connection → Azure Resource Manager**.
2. Select **Workload Identity Federation (automatic)** or configure manually with a federated credential.
3. Grant the service principal the following Azure RBAC roles:
   - `Owner` at the EA enrollment account scope (required for subscription creation)
   - `Owner` at the management group scope (required for MG placement)
   - `Contributor` on the hub resource group (required for Stage 4 — vWAN hub RG or VNet hub RG)
4. Name the service connection `sc-lz-vending-wif` (or update the `serviceConnectionName` pipeline parameter).

---

## Step 4 — Grant Microsoft Graph Permissions

The pipeline provisions Entra ID security groups in Stage 0b. This requires Microsoft Graph API permissions on the same service principal used by the WIF service connection. These are separate from Azure RBAC and must be granted explicitly.

1. In the Azure Portal, go to **Entra ID → App registrations**.
2. Find the app registration backing your WIF service connection.
3. Go to **API permissions → Add a permission → Microsoft Graph → Application permissions**.
4. Add the following permissions:
   - `Group.Create`
   - `GroupMember.ReadWrite.All`
   - `User.Read.All`
5. Click **Grant admin consent** for your tenant.

> **Note:** If your organisation's Entra policies restrict group creation to a specific admin role, work with your identity team to either grant the permissions above or establish a delegated group-creation process.

---

## Step 5 — Configure the ADO Environment (Approval Gate)

1. In Azure DevOps, go to **Pipelines → Environments → New environment**.
2. Name it `lz-vending-approval`.
3. Add an **Approvals** check with your platform team as approvers.

This environment is referenced by Stage 2 (Deploy Subscription). The pipeline pauses here after the what-if preview — approvers will see the complete deployment plan including platform-provisioned role assignments.

---

## Step 6 — Add the Pipeline Secret Variable

The ACA LZA pattern requires a VM admin password for the jump box. Set this as a pipeline secret:

1. Edit the pipeline → **Variables → New variable**.
2. Name: `lzVmAdminPassword`, Value: a strong password, tick **Keep this value secret**.

For BYO workloads this variable is unused but must exist (the pipeline references it).

---

## Step 7 — Create a Request File

Create a JSON file in the `requests/` directory (create the directory if it doesn't exist). Use one of the three scenarios below as a starting point.

The `tags.Owner` value must be a valid UPN in your Entra tenant — it is used to resolve the LZ owner's Object ID and add them as a member of the `<subscriptionname>-contributor` group.

### BYO / Private / Production
```json
{
  "workloadName": "ecommerce-api",
  "workloadCategory": "BYO",
  "environment": "Production",
  "workloadType": "Private",
  "baseIpAddress": "10.50.10.0",
  "networkSize": "Medium",
  "roleAssignments": [],
  "resourceProviders": { "Microsoft.KeyVault": [], "Microsoft.Network": [] },
  "enableTelemetry": true,
  "tags": {
    "BusinessUnit": "Retail",
    "CostCentre": "CC-1234",
    "DataClassification": "Confidential",
    "Owner": "platform@contoso.com",
    "SupportContact": "ops@contoso.com"
  }
}
```

### BYO / Public / NonProduction
```json
{
  "workloadName": "marketing-site",
  "workloadCategory": "BYO",
  "environment": "NonProduction",
  "workloadType": "Public",
  "baseIpAddress": "10.60.5.0",
  "networkSize": "Small",
  "roleAssignments": [],
  "resourceProviders": { "Microsoft.Web": [] },
  "enableTelemetry": true,
  "tags": {
    "BusinessUnit": "Marketing",
    "CostCentre": "CC-5678",
    "DataClassification": "Internal",
    "Owner": "dev@contoso.com",
    "SupportContact": "devops@contoso.com"
  }
}
```

### ApprovedWorkload / ContainerApps / Private
```json
{
  "workloadName": "payments-aca",
  "workloadCategory": "ApprovedWorkload",
  "environment": "Production",
  "approvedWorkload": {
    "pattern": "ContainerApps",
    "workloadType": "Private",
    "spokeVNetAddressSpace": "10.70.0.0/21",
    "exposeWith": "applicationGateway",
    "certKeyName": "appgw-payments-tls",
    "vmAdminPassword": "$(lzVmAdminPassword)",
    "vmSize": "Standard_B2s",
    "enableApplicationInsights": true,
    "enableDaprInstrumentation": false
  },
  "roleAssignments": [],
  "resourceProviders": { "Microsoft.App": [], "Microsoft.ContainerRegistry": [] },
  "enableTelemetry": true,
  "tags": {
    "BusinessUnit": "Payments",
    "CostCentre": "CC-9012",
    "DataClassification": "Highly Confidential",
    "Owner": "payments@contoso.com",
    "SupportContact": "payments-ops@contoso.com"
  }
}
```

Commit the file to the repository before running the pipeline.

---

## Step 8 — Run the Pipeline

1. Go to **Pipelines → lz-vending → Run pipeline**.
2. Set `requestFilePath` to the path of your request file (e.g. `requests/ecommerce-api.json`).
3. Confirm `serviceConnectionName` matches your service connection name.
4. Click **Run**.

The pipeline will:

1. **0a — Transform:** Derive all computed values from the request and customer config. Publish the immutable `lz-context.json` artifact.
2. **0b — Entra Groups:** Create `<subscriptionname>-contributor` and `<subscriptionname>-reader` security groups. Add the LZ owner as a member of the contributor group.
3. **0c — Bicep Params:** Generate all `.generated.bicepparam` files. Merge the group OIDs into the subscription role assignments so the what-if is fully representative.
4. **1 — Validate:** Run a what-if preview against the subscription deployment. Review the output before approving.
5. **Pause for approval** — the pipeline waits here. Review the what-if output in the stage logs, then approve the `lz-vending-approval` environment check.
6. **2 — Deploy Subscription:** Create the subscription and place it in the correct management group. Role assignments (including the two platform groups) are applied.
7. **3a or 3b — Networking / Workload:** Deploy BYO networking or the approved workload pattern into the new subscription.
8. **4 — Connect hub** (Private workloads only): Connect the spoke VNet to the hub (vWAN connection or VNet peering, based on `hub.type` in `customer.config.json`).
9. Publish a deployment summary artifact.

---

## What Gets Created Per Deployment

In addition to the subscription and its networking or workload resources, every LZ deployment creates:

| Resource | Name | Notes |
|---|---|---|
| Entra security group | `<subscriptionname>-contributor` | LZ owner added as member |
| Entra security group | `<subscriptionname>-reader` | Empty — populate via PIM or manual assignment |
| Role assignment | Contributor at subscription scope | Assigned to contributor group |
| Role assignment | Reader at subscription scope | Assigned to reader group |

---

## Adding a New Approved Workload Pattern (Future)

1. Create `bicep/approved-workloads/<pattern-name>/main.bicep` wrapping the relevant LZA AVM module.
2. Create `bicep/approved-workloads/<pattern-name>/main.bicepparam`.
3. Add a new `pattern` enum value to `schema/request.schema.json`.
4. Add a new `switch` case to `LZBicepParams.psm1` for the new pattern's param generation.
5. No changes to `Invoke-LZVending.ps1`, `LZTransform.psm1`, `LZEntraGroups.psm1`, or the pipeline YAML are required.