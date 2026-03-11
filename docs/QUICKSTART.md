# Quick Start

## Prerequisites

- Azure DevOps organisation and project
- EA billing account with at least two enrollment accounts (Production, NonProduction)
- Existing Management Group hierarchy (Corp, Online, Sandbox)
- Existing Azure vWAN hub (for Private workloads)
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
  "vwanHubResourceId":          "/subscriptions/<sub>/resourceGroups/<rg>/providers/Microsoft.Network/virtualHubs/<hub>",
  "vwanHubResourceGroupName":   "rg-vwan-hub-prod",
  "privateDnsZones":            [ "<zone-resource-id>", "..." ],
  "dnsZonesSubscriptionId":     "<dns-sub-id>",
  "dnsZonesResourceGroupName":  "rg-privatedns-prod"
}
```

---

## Step 2 — Create the ADO Service Connection

1. In Azure DevOps, go to **Project Settings → Service Connections → New service connection → Azure Resource Manager**.
2. Select **Workload Identity Federation (automatic)** or configure manually with a federated credential.
3. Grant the service principal the following roles:
   - `Owner` at the EA enrollment account scope (required for subscription creation)
   - `Owner` at the management group scope (required for MG placement)
   - `Contributor` on the vWAN hub resource group (required for Stage 5)
4. Name the service connection `sc-lz-vending-wif` (or update the `serviceConnectionName` pipeline parameter).

---

## Step 3 — Configure the ADO Environment (Approval Gate)

1. In Azure DevOps, go to **Pipelines → Environments → New environment**.
2. Name it `lz-vending-approval`.
3. Add an **Approvals** check with your platform team as approvers.

This environment is referenced by Stage 3 (Deploy Subscription) — the pipeline will pause for manual approval after the what-if preview.

---

## Step 4 — Add the Pipeline Secret Variable

The ACA LZA pattern requires a VM admin password for the jump box. Set this as a pipeline secret:

1. Edit the pipeline → **Variables → New variable**.
2. Name: `lzVmAdminPassword`, Value: a strong password, tick **Keep this value secret**.

For BYO workloads this variable is unused but must exist (the pipeline references it).

---

## Step 5 — Register the Pipeline

1. In Azure DevOps, go to **Pipelines → New pipeline → Azure Repos Git**.
2. Select your repository and point to `pipelines/lz-vending.yml`.
3. Save (do not run yet).

---

## Step 6 — Create a Request File

Create a JSON file in the `requests/` directory (create the directory if it doesn't exist). Use one of the three scenarios below as a starting point.

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

## Step 7 — Run the Pipeline

1. Go to **Pipelines → lz-vending → Run pipeline**.
2. Set `requestFilePath` to the path of your request file (e.g. `requests/ecommerce-api.json`).
3. Confirm `serviceConnectionName` matches your service connection name.
4. Click **Run**.

The pipeline will:
1. Transform the request into Bicep param files
2. Run a what-if preview against the subscription deployment
3. **Pause for approval** — review the what-if output, then approve
4. Create the subscription and place it in the correct management group
5. Deploy networking or the approved workload pattern
6. Connect the spoke VNet to vWAN (Private workloads only)
7. Publish a deployment summary artifact

---

## Adding a New Approved Workload Pattern (Future)

1. Create `bicep/approved-workloads/<pattern-name>/main.bicep` wrapping the relevant LZA AVM module.
2. Create `bicep/approved-workloads/<pattern-name>/main.bicepparam`.
3. Add a new `pattern` enum value to `schema/request.schema.json`.
4. Add a new `elseif` branch to `Convert-RequestToBicepParams.ps1` for the new pattern's param generation.
5. No changes to the pipeline YAML are required — Stage 4a dynamically resolves the pattern directory.
