// ============================================================
// bicep/approved-workloads/aca-lza/main.bicepparam
// TEMPLATE — shows structure and parameter sources for a /21 spoke.
// The GENERATED file (main.generated.bicepparam) is created
// at pipeline runtime by Convert-RequestToBicepParams.ps1.
//
// Subnet layout for a /21 spoke (e.g. 10.70.0.0/21):
//   snet-infra       10.70.0.0/23   (512 IPs — ACA managed env infra)
//   snet-private-ep  10.70.2.0/27   (32 IPs  — private endpoints)
//   snet-jumpbox     10.70.2.32/27  (32 IPs  — jump box VM)
//   snet-appgw       10.70.3.0/24   (256 IPs — Application Gateway)
//   snet-deployment  10.70.4.0/24   (256 IPs — deployment script)
// ============================================================

using './main.bicep'

// ── From request.workloadName
param workloadName = 'payments-aca'

// ── From customer.config.defaults.location
param location = 'australiaeast'

// ── From request.approvedWorkload.spokeVNetAddressSpace
param spokeVNetAddressPrefixes = ['10.70.0.0/21']

// ── Derived by Convert-RequestToBicepParams.ps1 from spokeVNetAddressSpace
param spokeInfraSubnetAddressPrefix             = '10.70.0.0/23'
param spokePrivateEndpointsSubnetAddressPrefix  = '10.70.2.0/27'
param vmJumpBoxSubnetAddressPrefix              = '10.70.2.32/27'
param spokeApplicationGatewaySubnetAddressPrefix = '10.70.3.0/24'
param deploymentSubnetAddressPrefix             = '10.70.4.0/24'

// ── From request.approvedWorkload.exposeWith
param exposeContainerAppsWith = 'applicationGateway'

// ── From request.approvedWorkload.certKeyName
param applicationGatewayCertificateKeyName = 'appgw-payments-tls'

// ── From pipeline environment variable LZ_VM_ADMIN_PASSWORD (never stored in source)
param vmAdminPassword = readEnvironmentVariable('LZ_VM_ADMIN_PASSWORD', '')

// ── From request.approvedWorkload.vmSize
param vmSize = 'Standard_B2s'

// ── From request.approvedWorkload.enableApplicationInsights
param enableApplicationInsights = true

// ── From request.approvedWorkload.enableDaprInstrumentation
param enableDaprInstrumentation = false

// ── 9-tag merged set from request + pipeline
param tags = {
  BusinessUnit:       'Payments'
  CostCentre:         'CC-9012'
  DataClassification: 'Highly Confidential'
  Owner:              'payments-platform@contoso.com'
  SupportContact:     'payments-ops@contoso.com'
  Environment:        'Production'
  WorkloadName:       'payments-aca'
  DeployedAt:         '2025-01-01T00:00:00Z'
  DeployedBy:         'lz-vending-pipeline'
}

// ── From request.enableTelemetry
param enableTelemetry = true
