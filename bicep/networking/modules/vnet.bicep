// ============================================================
// bicep/networking/modules/vnet.bicep
// Creates the spoke Virtual Network with the workload subnet.
// Wraps avm/res/network/virtual-network.
//
// Version: 0.6.1 — pinned.
// Verify latest at: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/network/virtual-network
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Name of the virtual network.')
param virtualNetworkName string

@description('Required. CIDR address space (e.g. 10.50.10.0/26).')
param virtualNetworkAddressPrefix string

@description('Required. Resource ID of the NSG to associate with the workload subnet.')
param nsgResourceId string

@description('Required. Azure region.')
param location string

@description('Required. Resource tags.')
param resourceTags object

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'vnet-${uniqueString(virtualNetworkName, location)}'
  params: {
    name:            virtualNetworkName
    addressPrefixes: [virtualNetworkAddressPrefix]
    location:        location
    tags:            resourceTags
    enableTelemetry: enableTelemetry
    subnets: [
      {
        // BYO spoke has a single workload subnet covering the full address space.
        // Workload teams carve this up further within their own deployment.
        name:                     'snet-workload'
        addressPrefix:            virtualNetworkAddressPrefix
        networkSecurityGroupResourceId: nsgResourceId
        privateEndpointNetworkPolicies:    'Disabled'
        privateLinkServiceNetworkPolicies: 'Disabled'
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the virtual network.')
output vnetResourceId string = virtualNetwork.outputs.resourceId

@description('Name of the virtual network.')
output vnetName string = virtualNetwork.outputs.name

@description('Resource IDs of all subnets.')
output subnetResourceIds array = virtualNetwork.outputs.subnetResourceIds
