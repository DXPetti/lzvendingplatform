// ============================================================
// bicep/networking/main.bicepparam
// TEMPLATE — shows structure and parameter sources.
// The GENERATED file (main.generated.bicepparam) is created
// at pipeline runtime by Convert-RequestToBicepParams.ps1.
// ============================================================

using './main.bicep'

// ── From customer.config.defaults.location
param location = 'australiaeast'

// ── Derived from baseIpAddress + networkSize (Small=/27, Medium=/26, Large=/25)
param virtualNetworkAddressPrefix = '10.50.10.0/26'

// ── Naming: vnet-<orgShortName>-<envPrefix>-<workloadName>
param virtualNetworkName = 'vnet-contoso-prod-ecommerce-api'

// ── Naming: rg-<orgShortName>-<envPrefix>-<workloadName>-networking
param virtualNetworkResourceGroupName = 'rg-contoso-prod-ecommerce-api-networking'

// ── From request.workloadType
param workloadType = 'Private'

// ── 9-tag merged set from request + pipeline
param resourceTags = {
  BusinessUnit:       'Retail'
  CostCentre:         'CC-1234'
  DataClassification: 'Confidential'
  Owner:              'platform@contoso.com'
  SupportContact:     'ops@contoso.com'
  Environment:        'Production'
  WorkloadName:       'ecommerce-api'
  DeployedAt:         '2025-01-01T00:00:00Z'
  DeployedBy:         'lz-vending-pipeline'
}

// ── From customer.config.privateDnsZones — only populated when workloadType == 'Private'
param privateDnsZoneResourceIds = [
  '/subscriptions/<dns-subscription-id>/resourceGroups/rg-privatedns-prod/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
  '/subscriptions/<dns-subscription-id>/resourceGroups/rg-privatedns-prod/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
]

// ── From customer.config.dnsZonesSubscriptionId
param dnsZonesSubscriptionId = '<dns-subscription-id>'

// ── From customer.config.dnsZonesResourceGroupName
param dnsZonesResourceGroupName = 'rg-privatedns-prod'
