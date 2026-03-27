// ============================================================
// bicep/approved-workloads/aca-lza/main.bicep
// Stage 3a — Approved Workload: Container Apps LZA
// (runs only when workloadCategory == 'ApprovedWorkload' and pattern == 'ContainerApps')
//
// Thin wrapper around avm/ptn/aca-lza/hosting-environment.
//
// KEY DESIGN DECISIONS:
//   hubVirtualNetworkResourceId is ALWAYS ''.
//   The LZA module accepts a VNet resource ID for hub peering.
//   Azure vWAN hubs are Microsoft.Network/virtualHubs — a different resource type.
//   Passing a vWAN hub ID here would fail ARM validation.
//   Hub connectivity is handled by Stage 4 in the pipeline:
//     az network vhub connection create  (vWAN)
//     az network vnet peering create     (VNet hub)
//   after this module outputs spokeVNetResourceId.

targetScope = 'subscription'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Short workload name. Used in resource naming throughout the LZA pattern.')
param workloadName string

@description('Required. Azure region for all resources.')
param location string

@description('Required. Address prefixes for the spoke VNet. Minimum /21 for ACA LZA.')
param spokeVNetAddressPrefixes array

@description('Required. Address prefix for the ACA infrastructure subnet. Minimum /23.')
param spokeInfraSubnetAddressPrefix string

@description('Required. Address prefix for the private endpoints subnet.')
param spokePrivateEndpointsSubnetAddressPrefix string

@description('Required. Address prefix for the jump box VM subnet.')
param vmJumpBoxSubnetAddressPrefix string

@description('Required. Address prefix for the Application Gateway subnet.')
param spokeApplicationGatewaySubnetAddressPrefix string

@description('Required. Address prefix for the deployment script subnet.')
param deploymentSubnetAddressPrefix string

@description('Required. How the container app environment is exposed externally.')
@allowed(['applicationGateway', 'frontDoor', 'none'])
param exposeContainerAppsWith string

@description('Required. Key Vault certificate key name for Application Gateway TLS.')
param applicationGatewayCertificateKeyName string

@description('Required. Admin password for the jump box VM.')
@secure()
param vmAdminPassword string

@description('Required. SKU for the jump box VM.')
param vmSize string

@description('Required. Deploy Application Insights.')
param enableApplicationInsights bool

@description('Required. Enable Dapr instrumentation via Application Insights.')
param enableDaprInstrumentation bool

@description('Optional. Tags to apply to all resources.')
param tags object = {}

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

// NOTE: hubVirtualNetworkResourceId is hardcoded to ''.
// Do NOT add it as a parameter — it must never be set here.
// Hub connectivity is the responsibility of Stage 4 in the pipeline.

module acaLza 'br/public:avm/ptn/aca-lza/hosting-environment:0.6.2' = {
  name: 'acaLza-${workloadName}'
  params: {
    // Required
    workloadName                               : workloadName
    location                                   : location
    spokeVNetAddressPrefixes                   : spokeVNetAddressPrefixes
    spokeInfraSubnetAddressPrefix              : spokeInfraSubnetAddressPrefix
    spokePrivateEndpointsSubnetAddressPrefix   : spokePrivateEndpointsSubnetAddressPrefix
    vmJumpBoxSubnetAddressPrefix               : vmJumpBoxSubnetAddressPrefix
    spokeApplicationGatewaySubnetAddressPrefix : spokeApplicationGatewaySubnetAddressPrefix
    deploymentSubnetAddressPrefix              : deploymentSubnetAddressPrefix
    exposeContainerAppsWith                    : exposeContainerAppsWith
    applicationGatewayCertificateKeyName       : applicationGatewayCertificateKeyName
    vmAdminPassword                            : vmAdminPassword
    vmSize                                     : vmSize
    enableApplicationInsights                  : enableApplicationInsights
    enableDaprInstrumentation                  : enableDaprInstrumentation

    // Hub networking — intentionally empty. Hub connectivity handled by Stage 4 pipeline CLI.
    hubVirtualNetworkResourceId                : ''

    // Jump box — no OS by default. Override for debugging only.
    vmJumpboxOSType                            : 'none'

    // Tags and telemetry
    tags                                       : tags
    enableTelemetry                            : enableTelemetry
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('Resource ID of the ACA LZA spoke virtual network. Consumed by Stage 4 (hub connection).')
output spokeVNetResourceId string = acaLza.outputs.spokeVNetResourceId
