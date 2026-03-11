// ============================================================
// bicep/networking/main.bicep
// Step 3 — BYO Networking (runs only when workloadCategory == 'BYO')
//
// Orchestrates the following in order:
//   1. Resource Group         — avm/res/resources/resource-group:0.4.1
//   2. NSG                    — modules/nsg.bicep → avm/res/network/network-security-group:0.4.0
//   3. Virtual Network        — modules/vnet.bicep → avm/res/network/virtual-network:0.6.1
//   4. DNS Zone VNet Links    — modules/dns-zone-links.bicep (Private workloads only)
//                               One module call per DNS zone, scoped to DNS zones RG.
// ============================================================

targetScope = 'subscription'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Azure region for all resources.')
param location string

@description('Required. CIDR address space for the spoke VNet (e.g. 10.50.10.0/26).')
param virtualNetworkAddressPrefix string

@description('Required. Name of the virtual network.')
param virtualNetworkName string

@description('Required. Name of the resource group to create for networking resources.')
param virtualNetworkResourceGroupName string

@description('Required. Connectivity model — determines DNS zone linking behaviour.')
@allowed(['Private', 'Public', 'Sandbox'])
param workloadType string

@description('Required. Tags to apply to all resources.')
param resourceTags object

@description('Optional. Resource IDs of private DNS zones to link. Only populated when workloadType == Private.')
param privateDnsZoneResourceIds array = []

@description('Optional. Subscription ID hosting the private DNS zones. Required when workloadType == Private.')
param dnsZonesSubscriptionId string = ''

@description('Optional. Resource group name hosting the private DNS zones. Required when workloadType == Private.')
param dnsZonesResourceGroupName string = ''

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Derived variables ─────────────────────────────────────────────────────────

var nsgName   = 'nsg-${virtualNetworkName}'
var isPrivate = workloadType == 'Private'

// ── Step 1: Resource Group ─────────────────────────────────────────────────────
//
// Version 0.4.1 — pinned.
// Verify latest at: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/resources/resource-group

module networkingRg 'br/public:avm/res/resources/resource-group:0.4.1' = {
  name: 'rg-${uniqueString(virtualNetworkResourceGroupName, location)}'
  params: {
    name:            virtualNetworkResourceGroupName
    location:        location
    tags:            resourceTags
    enableTelemetry: enableTelemetry
  }
}

// ── Step 2: NSG ────────────────────────────────────────────────────────────────
//
// Deployed into the networking RG via a scoped module call.
// The NSG module wraps avm/res/network/network-security-group.

module nsg 'modules/nsg.bicep' = {
  name: 'nsg-${uniqueString(nsgName, location)}'
  scope: resourceGroup(virtualNetworkResourceGroupName)
  dependsOn: [networkingRg]
  params: {
    nsgName:         nsgName
    location:        location
    resourceTags:    resourceTags
    enableTelemetry: enableTelemetry
  }
}

// ── Step 3: Virtual Network ────────────────────────────────────────────────────
//
// Deployed into the networking RG via a scoped module call.
// The VNet module wraps avm/res/network/virtual-network and associates the NSG.

module vnet 'modules/vnet.bicep' = {
  name: 'vnet-${uniqueString(virtualNetworkName, location)}'
  scope: resourceGroup(virtualNetworkResourceGroupName)
  params: {
    virtualNetworkName:          virtualNetworkName
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    nsgResourceId:               nsg.outputs.nsgResourceId
    location:                    location
    resourceTags:                resourceTags
    enableTelemetry:             enableTelemetry
  }
}

// ── Step 4: Private DNS Zone VNet Links (Private workloads only) ───────────────
//
// DNS zones live in a centralised DNS subscription/RG — different from the VNet RG.
//
// WHY A MODULE AND NOT A RESOURCE BLOCK:
//   Bicep BCP139 prohibits resource blocks from using scope: resourceGroup(x, y)
//   when the file's targetScope is 'subscription'. Only module calls support this.
//   Each zone gets one module call, scoped to the DNS zones resource group.
//
// HOW THE LOOP WORKS:
//   isPrivate ? privateDnsZoneResourceIds : [] ensures the loop body is empty
//   for non-Private workloads (condition-in-loop pattern avoids a conditional
//   module array which requires Bicep 0.25+ and is harder to read).

module dnsZoneLinks 'modules/dns-zone-links.bicep' = [
  for (zoneResourceId, i) in (isPrivate ? privateDnsZoneResourceIds : []): {
    name: 'dns-link-${i}-${uniqueString(zoneResourceId, virtualNetworkName)}'
    scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
    params: {
      dnsZoneName:    last(split(zoneResourceId, '/'))
      vnetResourceId: vnet.outputs.vnetResourceId
      linkName:       'link-${virtualNetworkName}'
    }
  }
]

// ── Outputs ────────────────────────────────────────────────────────────────────

@description('Resource ID of the spoke VNet. Consumed by Stage 5 (vWAN connection).')
output virtualNetworkResourceId string = vnet.outputs.vnetResourceId

@description('Name of the spoke virtual network.')
output virtualNetworkName string = vnet.outputs.vnetName

@description('Name of the networking resource group.')
output resourceGroupName string = networkingRg.outputs.name
