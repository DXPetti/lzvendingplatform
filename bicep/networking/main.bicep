// ============================================================
// bicep/networking/main.bicep
// Stage 3b — BYO Networking (runs only when workloadCategory == 'BYO')
//
// Orchestrates the following in order:
//   1. Resource Group         — avm/res/resources/resource-group:0.4.1
//   2. NSG                    — modules/nsg.bicep → avm/res/network/network-security-group:0.4.0
//   3. Virtual Network        — modules/vnet.bicep → avm/res/network/virtual-network:0.6.1
//   4. DNS Zone VNet Links    — modules/dns-zone-links.bicep (Private workloads only)
//                               One module call per DNS zone, scoped to DNS zones RG.
//
// SUBNET LAYOUT (derived by LZTransform.psm1, passed via subnets param):
//   Production:    1 subnet  — snet-<workloadName>         (full VNet CIDR)
//   NonProduction: 3 subnets — snet-<workloadName>-dev
//                              snet-<workloadName>-test
//                              snet-<workloadName>-uat
//
// NSG RULES:
//   Production:    No rules. Internet enforcement is the hub firewall's job.
//                  The Azure Load Balancer probe rule is also omitted — internal
//                  LBs in a private spoke use RFC 1918 addresses and do not
//                  require the AzureLoadBalancer service tag.
//   NonProduction: One intra-VNet deny rule prevents lateral movement between
//                  the dev/test/uat subnets. Source is the VNet CIDR specifically
//                  (not the VirtualNetwork service tag, which covers all peered
//                  address spaces and would block hub-sourced traffic).
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

@description('Required. Subnet definitions — name and addressPrefix per entry. Derived by LZTransform.psm1.')
param subnets array

@description('Required. Connectivity model — determines DNS zone linking behaviour.')
@allowed(['Private', 'Public', 'Sandbox'])
param workloadType string

@description('Required. Deployment environment — determines NSG rule set.')
@allowed(['Production', 'NonProduction'])
param environment string

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

// NonProduction intra-VNet deny rule.
// Source is the VNet CIDR — NOT the VirtualNetwork service tag.
// The service tag covers all peered address spaces and would block
// hub-sourced traffic. Using the specific VNet CIDR restricts the
// deny to intra-VNet lateral movement only.
var nonProdIntraVNetDenyRule = [
  {
    name: 'Deny-Inbound-IntraVNet'
    properties: {
      priority:                 900
      direction:                'Inbound'
      access:                   'Deny'
      protocol:                 '*'
      sourcePortRange:          '*'
      destinationPortRange:     '*'
      sourceAddressPrefix:      virtualNetworkAddressPrefix
      destinationAddressPrefix: 'VirtualNetwork'
      description:              'Deny inbound lateral movement between subnets within this VNet. Does not affect hub-sourced traffic.'
    }
  }
]

var nsgSecurityRules = environment == 'NonProduction' ? nonProdIntraVNetDenyRule : []

// ── Step 1: Resource Group ─────────────────────────────────────────────────────

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
// A single NSG shared across all subnets in the VNet.
// Production: no rules — hub firewall is the enforcement point.
// NonProduction: intra-VNet deny rule to prevent lateral movement
// between dev/test/uat subnets.

module nsg 'modules/nsg.bicep' = {
  name: 'nsg-${uniqueString(nsgName, location)}'
  scope: resourceGroup(virtualNetworkResourceGroupName)
  dependsOn: [networkingRg]
  params: {
    nsgName:                 nsgName
    location:                location
    resourceTags:            resourceTags
    additionalSecurityRules: nsgSecurityRules
    enableTelemetry:         enableTelemetry
  }
}

// ── Step 3: Virtual Network ────────────────────────────────────────────────────
//
// Subnet definitions (name + addressPrefix) are passed in from the generated
// bicepparam. vnet.bicep applies the NSG association and network policies
// uniformly across all subnets via a for loop, so the param file stays clean.

module vnet 'modules/vnet.bicep' = {
  name: 'vnet-${uniqueString(virtualNetworkName, location)}'
  scope: resourceGroup(virtualNetworkResourceGroupName)
  params: {
    virtualNetworkName:          virtualNetworkName
    virtualNetworkAddressPrefix: virtualNetworkAddressPrefix
    subnets:                     subnets
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

@description('Resource ID of the spoke VNet. Consumed by Stage 4 (hub connection).')
output virtualNetworkResourceId string = vnet.outputs.vnetResourceId

@description('Name of the spoke virtual network.')
output virtualNetworkName string = vnet.outputs.vnetName

@description('Name of the networking resource group.')
output resourceGroupName string = networkingRg.outputs.name
