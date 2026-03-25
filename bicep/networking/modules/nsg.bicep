// ============================================================
// bicep/networking/modules/nsg.bicep
// Creates the Network Security Group for the spoke VNet subnets.
// Wraps avm/res/network/network-security-group.
//
// Version: 0.4.0 — pinned.
// Verify latest at: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/network/network-security-group
//
// DESIGN NOTES — no default rules:
//   In a hub/spoke topology, spoke subnets have a UDR routing 0.0.0.0/0
//   to the hub firewall. Internet ingress and egress are enforced at the
//   firewall, not the NSG. Duplicating deny rules at the NSG adds noise
//   without adding security.
//
//   The Azure Load Balancer probe rule is also omitted. Internal load
//   balancers in a private spoke are sourced from RFC 1918 space and do
//   not require the AzureLoadBalancer service tag to be explicitly allowed.
//
//   The only rule added at platform level is the NonProduction intra-VNet
//   deny, passed in via additionalSecurityRules from networking/main.bicep.
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Name for the Network Security Group.')
param nsgName string

@description('Required. Azure region.')
param location string

@description('Required. Resource tags.')
param resourceTags object

@description('Optional. Additional security rules to apply. Used to pass the NonProduction intra-VNet deny rule.')
param additionalSecurityRules array = []

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

module networkSecurityGroup 'br/public:avm/res/network/network-security-group:0.4.0' = {
  name: 'res-nsg-${uniqueString(nsgName, location)}'
  params: {
    name:            nsgName
    location:        location
    tags:            resourceTags
    enableTelemetry: enableTelemetry
    securityRules:   additionalSecurityRules
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the NSG.')
output nsgResourceId string = networkSecurityGroup.outputs.resourceId

@description('Name of the NSG.')
output nsgName string = networkSecurityGroup.outputs.name
