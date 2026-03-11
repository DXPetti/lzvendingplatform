// ============================================================
// bicep/networking/modules/dns-zone-links.bicep
// Creates a Virtual Network Link on an EXISTING private DNS zone.
//
// WHY THIS MODULE EXISTS (BCP139 fix):
//   The private DNS zones live in a centralised DNS resource group,
//   which is in a DIFFERENT subscription/RG from the spoke VNet.
//   Bicep BCP139 prevents a resource block inside a file with
//   targetScope = 'subscription' from using scope: resourceGroup(x, y).
//   Only module calls support cross-scope targeting.
//
//   This module is deployed from main.bicep with:
//     scope: resourceGroup(dnsZonesSubscriptionId, dnsZonesResourceGroupName)
//   so all resources here deploy into the DNS zones RG.
//
// One instance of this module is deployed per DNS zone.
// The loop in main.bicep iterates over privateDnsZoneResourceIds.
//
// NOTE: No AVM module exists for creating a VNet link on an existing zone.
// The AVM private-dns-zone module manages the full zone lifecycle and would
// conflict with existing zones. Direct ARM resource declaration is the
// correct approach here.
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Name of the existing private DNS zone (e.g. privatelink.blob.core.windows.net).')
param dnsZoneName string

@description('Required. Resource ID of the spoke VNet to link to the DNS zone.')
param vnetResourceId string

@description('Required. Name for the virtual network link resource.')
param linkName string

// ── Existing DNS Zone reference ───────────────────────────────────────────────

resource existingDnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' existing = {
  name: dnsZoneName
}

// ── VNet Link ─────────────────────────────────────────────────────────────────

resource vnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = {
  parent: existingDnsZone
  name:   linkName
  location: 'global'
  properties: {
    virtualNetwork:      { id: vnetResourceId }
    registrationEnabled: false
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the virtual network link.')
output vnetLinkResourceId string = vnetLink.id

@description('Name of the DNS zone this link was created in.')
output dnsZoneName string = dnsZoneName
