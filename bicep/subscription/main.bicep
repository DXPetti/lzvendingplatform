// ============================================================
// bicep/subscription/main.bicep
// Step 1 — Subscription Vending (always runs)
//
// Calls avm/ptn/lz/sub-vending to create the subscription,
// place it in the correct management group, assign RBAC,
// and register resource providers.
//
// IMPORTANT: virtualNetworkEnabled is ALWAYS false.
// Networking is owned by Step 2 (ApprovedWorkload) or Step 3 (BYO).
// No network parameters are declared or passed to this module.
// ============================================================

targetScope = 'managementGroup'

// ── Parameters ────────────────────────────────────────────────────────────────

@description('Required. Alias name for the new subscription. Also used as the display name.')
param subscriptionAliasName string

@description('Required. Display name for the new subscription.')
param subscriptionDisplayName string

@description('Required. EA billing scope resource ID.')
param subscriptionBillingScope string

@description('Required. EA subscription offer type.')
@allowed(['Production', 'DevTest'])
param subscriptionWorkload string

@description('Required. Management group ID to place the subscription into.')
param subscriptionManagementGroupId string

@description('Required. Tags to apply to the subscription and all resources.')
param subscriptionTags object

@description('Optional. Whether to create role assignments on the new subscription.')
param roleAssignmentEnabled bool = false

@description('Optional. RBAC role assignments to create on the new subscription scope.')
param roleAssignments array = []

@description('Optional. Resource providers and features to register on the new subscription.')
param resourceProviders object = {}

@description('Optional. Enable AVM deployment telemetry.')
param enableTelemetry bool = true

// ── Module ────────────────────────────────────────────────────────────────────

module subVending 'br/public:avm/ptn/lz/sub-vending:0.6.0' = {
  name: 'subVending-${subscriptionAliasName}'
  params: {
    // Subscription creation
    subscriptionAliasEnabled             : true
    subscriptionAliasName                : subscriptionAliasName
    subscriptionDisplayName              : subscriptionDisplayName
    subscriptionBillingScope             : subscriptionBillingScope
    subscriptionWorkload                 : subscriptionWorkload
    subscriptionManagementGroupAssociationEnabled: true
    subscriptionManagementGroupId        : subscriptionManagementGroupId
    subscriptionTags                     : subscriptionTags

    // Networking — always disabled. VNet is owned by Step 2 or Step 3.
    virtualNetworkEnabled                : false

    // RBAC
    roleAssignmentEnabled                : roleAssignmentEnabled
    roleAssignments                      : roleAssignments

    // Resource providers
    resourceProviders                    : resourceProviders

    // Telemetry
    enableTelemetry                      : enableTelemetry
  }
}

// ── Outputs ───────────────────────────────────────────────────────────────────

@description('The resource ID of the newly created subscription.')
output subscriptionResourceId string = subVending.outputs.subscriptionResourceId

@description('The subscription ID of the newly created subscription.')
output subscriptionId string = subVending.outputs.subscriptionId
