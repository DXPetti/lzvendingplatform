// ============================================================
// bicep/networking/modules/vnet.bicep
// Creates the spoke Virtual Network and its subnets.
// Wraps avm/res/network/virtual-network.
//
// Version: 0.6.1 — pinned.
// Verify latest at: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/network/virtual-network
//
// SUBNET LAYOUT — driven by the subnets param, derived by LZTransform.psm1:
//
//   Production:
//     snet-<workloadName>               — full VNet CIDR, single workload subnet
//
//   NonProduction:
//     snet-<workloadName>-dev           — lower third of VNet address space
//     snet-<workloadName>-test          — middle third
//     snet-<workloadName>-uat           — upper third
//
// Each subnet entry in the array requires only name and addressPrefix.
// This module applies the NSG association and network policies uniformly
// across all subnets — callers do not need to repeat those properties
// per-subnet and there is no dependency on the subscription ID at
// param-generation time.
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Name of the virtual network.')
param virtualNetworkName string

@description('Required. CIDR address space for the VNet (e.g. 10.50.10.0/26).')
param virtualNetworkAddressPrefix string

@description('Required. Subnet definitions. Each entry must include name and addressPrefix.')
param subnets array

@description('Required. Resource ID of the NSG to associate with all subnets.')
param nsgResourceId string

@description('Required. Azure region.')
param location string

@description('Required. Resource tags.')
param resourceTags object

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'res-vnet-${uniqueString(virtualNetworkName, location)}'
  params: {
    name:            virtualNetworkName
    addressPrefixes: [virtualNetworkAddressPrefix]
    location:        location
    tags:            resourceTags
    enableTelemetry: enableTelemetry
    // NSG association and network policies applied uniformly across all subnets.
    // Callers supply only name and addressPrefix in the subnets array.
    subnets: [for subnet in subnets: {
      name:                              subnet.name
      addressPrefix:                     subnet.addressPrefix
      networkSecurityGroupResourceId:    nsgResourceId
      privateEndpointNetworkPolicies:    'Disabled'
      privateLinkServiceNetworkPolicies: 'Disabled'
    }]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the virtual network.')
output vnetResourceId string = virtualNetwork.outputs.resourceId

@description('Name of the virtual network.')
output vnetName string = virtualNetwork.outputs.name

@description('Resource IDs of all subnets.')
output subnetResourceIds array = virtualNetwork.outputs.subnetResourceIds
