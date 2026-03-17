// ============================================================
// bicep/networking/modules/nsg.bicep
// Creates the Network Security Group for the spoke VNet subnet.
// Wraps avm/res/network/network-security-group.
//
// Version: 0.4.0 — pinned.
// Verify latest at: https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/network/network-security-group
// ============================================================

targetScope = 'resourceGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Name for the Network Security Group.')
param nsgName string

@description('Required. Azure region.')
param location string

@description('Required. Resource tags.')
param resourceTags object

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

module networkSecurityGroup 'br/public:avm/res/network/network-security-group:0.4.0' = {
  name: 'nsg-${uniqueString(nsgName, location)}'
  params: {
    name:            nsgName
    location:        location
    tags:            resourceTags
    enableTelemetry: enableTelemetry
    securityRules: [
      {
        name: 'Deny-Inbound-Internet'
        properties: {
          priority:                 4000
          direction:                'Inbound'
          access:                   'Deny'
          protocol:                 '*'
          sourcePortRange:          '*'
          destinationPortRange:     '*'
          sourceAddressPrefix:      'Internet'
          destinationAddressPrefix: 'VirtualNetwork'
          description:              'Deny all inbound internet traffic by default. Override with explicit allow rules per workload.'
        }
      }
      {
        name: 'Deny-Outbound-Internet'
        properties: {
          priority:                 4000
          direction:                'Outbound'
          access:                   'Deny'
          protocol:                 '*'
          sourcePortRange:          '*'
          destinationPortRange:     '*'
          sourceAddressPrefix:      'VirtualNetwork'
          destinationAddressPrefix: 'Internet'
          description:              'Deny all outbound internet traffic by default. Override with explicit allow rules per workload.'
        }
      }
      {
        name: 'Allow-AzureLoadBalancer-Inbound'
        properties: {
          priority:                 4095
          direction:                'Inbound'
          access:                   'Allow'
          protocol:                 '*'
          sourcePortRange:          '*'
          destinationPortRange:     '*'
          sourceAddressPrefix:      'AzureLoadBalancer'
          destinationAddressPrefix: '*'
          description:              'Allow Azure Load Balancer health probes.'
        }
      }
    ]
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the NSG.')
output nsgResourceId string = networkSecurityGroup.outputs.resourceId

@description('Name of the NSG.')
output nsgName string = networkSecurityGroup.outputs.name
