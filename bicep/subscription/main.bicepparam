// ============================================================
// bicep/subscription/main.bicepparam
// TEMPLATE — shows structure and parameter sources.
// The GENERATED file (main.generated.bicepparam) is created
// at pipeline runtime by Convert-RequestToBicepParams.ps1.
// ============================================================

using './main.bicep'

// ── Derived from request.workloadName + environment + customer.config.defaults.orgShortName
param subscriptionAliasName = 'contoso-prod-ecommerce-api'

// ── Same as alias name
param subscriptionDisplayName = 'contoso-prod-ecommerce-api'

// ── From customer.config.billingScopes (Production → .production, NonProduction → .nonProduction)
param subscriptionBillingScope = '/providers/Microsoft.Billing/billingAccounts/<billingAccountId>/enrollmentAccounts/<enrollmentAccountId>'

// ── Derived: Production → 'Production', NonProduction → 'DevTest'
param subscriptionWorkload = 'Production'

// ── From customer.config.managementGroups (workloadType: Private → .corp, Public → .online, Sandbox → .sandbox)
param subscriptionManagementGroupId = 'mg-contoso-corp'

// ── 5 request tags + 4 pipeline-derived tags = 9 total
param subscriptionTags = {
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

// ── true when request.roleAssignments is non-empty
param roleAssignmentEnabled = true

// ── Mapped from request.roleAssignments
param roleAssignments = [
  {
    definition:    '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
    principalId:   'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
    principalType: 'Group'
    relativeScope: '/'
  }
]

// ── From request.resourceProviders
param resourceProviders = {
  'Microsoft.ContainerRegistry': []
  'Microsoft.KeyVault':          []
  'Microsoft.Network':           []
}

// ── From request.enableTelemetry (default: true)
param enableTelemetry = true
