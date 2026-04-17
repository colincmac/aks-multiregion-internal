// ---------------------------------------------------------------------------
// Tier-1 gateway — Azure Application Gateway for Containers (AGC)
//
// Implements ADR-0001 Option E.
//
// Deployment mode: BYO (bring-your-own) — we create the AGC parent resource,
// an Association to the regional VNet via a dedicated delegated subnet, and
// a user-assigned managed identity that the in-cluster ALB Controller binds
// to via Azure AD Workload Identity. The Gateway / HTTPRoute / BackendTLSPolicy
// objects live in Git under clusters/base/tier1-agc and are reconciled into
// Azure by the ALB Controller.
//
// Reference:
//   https://learn.microsoft.com/en-us/azure/application-gateway/for-containers/quickstart-create-application-gateway-for-containers-byo-deployment
//
// This module is intentionally NOT wired into infra/main.bicep yet — see the
// follow-ups in ADR-0001. Wiring requires allocating an AGC-delegated subnet
// per regional VNet (see vnet.bicep) and granting the ALB Controller identity
// federated credentials to the cluster OIDC issuer.
// ---------------------------------------------------------------------------

@description('Base name for the AGC resources (e.g. "agc-istio-mesh-eastus2").')
param name string

@description('Azure region (must be an AGC-supported region).')
param location string

@description('Resource ID of the regional VNet that AGC will associate with.')
param vnetId string

@description('Resource ID of the subnet delegated to Microsoft.ServiceNetworking/trafficControllers. Must be empty and /24 or larger.')
param albDelegatedSubnetId string

@description('Name of the private frontend to expose to the regional VNet.')
param frontendName string = 'private-frontend'

@description('Principal ID of the user-assigned managed identity that the in-cluster ALB Controller uses. Must have "AppGw for Containers Configuration Manager" on this AGC resource.')
param albControllerIdentityPrincipalId string

@description('Tags to apply to AGC resources.')
param tags object = {}

// ---------------------------------------------------------------------------
// AGC parent resource (Traffic Controller)
// ---------------------------------------------------------------------------

resource trafficController 'Microsoft.ServiceNetworking/trafficControllers@2025-01-01' = {
  name: name
  location: location
  tags: tags
  properties: {}
}

// ---------------------------------------------------------------------------
// Association: binds the AGC to the regional VNet via the delegated subnet.
// AGC injects its data-plane NICs into this subnet.
// ---------------------------------------------------------------------------

resource association 'Microsoft.ServiceNetworking/trafficControllers/associations@2025-01-01' = {
  parent: trafficController
  name: '${name}-assoc'
  location: location
  tags: tags
  properties: {
    associationType: 'subnets'
    subnet: {
      id: albDelegatedSubnetId
    }
  }
}

// ---------------------------------------------------------------------------
// Private frontend — stable per-region private IP. This is the address that
// the DNS GSLB (today) and Azure Private Traffic Manager (future) point at.
// ---------------------------------------------------------------------------

resource frontend 'Microsoft.ServiceNetworking/trafficControllers/frontends@2025-01-01' = {
  parent: trafficController
  name: frontendName
  location: location
  tags: tags
  properties: {}
}

// ---------------------------------------------------------------------------
// Role assignment — the ALB Controller identity must be able to configure
// this AGC (Gateway / HTTPRoute / BackendTLSPolicy reconciliation).
// Role: "AppGw for Containers Configuration Manager"
// GUID: fbc52c3f-28ad-4303-a892-8a056630b8f1
// ---------------------------------------------------------------------------

var albConfigManagerRoleId = 'fbc52c3f-28ad-4303-a892-8a056630b8f1'

resource albControllerRa 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(trafficController.id, albControllerIdentityPrincipalId, albConfigManagerRoleId)
  scope: trafficController
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', albConfigManagerRoleId)
    principalId: albControllerIdentityPrincipalId
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

@description('Resource ID of the AGC Traffic Controller.')
output trafficControllerId string = trafficController.id

@description('Name of the AGC Traffic Controller.')
output trafficControllerName string = trafficController.name

@description('Resource ID of the private frontend. Referenced from the Gateway API "Gateway" object in the cluster.')
output frontendId string = frontend.id

@description('Resource ID of the VNet association.')
output associationId string = association.id

@description('VNet resource ID wired for convenience (e.g. downstream DNS records).')
output vnetId string = vnetId
