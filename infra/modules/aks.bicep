@description('AKS cluster name')
param name string

@description('Azure region')
param location string

@description('Kubernetes version')
param kubernetesVersion string

@description('Subnet resource ID for AKS nodes')
param vnetSubnetId string

@description('Git repository URL for Flux')
param gitRepositoryUrl string

@description('Git branch for Flux')
param gitRepositoryBranch string

@description('Kustomization path within the Git repo')
param kustomizationPath string

@description('VM size for the system node pool')
param systemNodeVmSize string = 'Standard_D4ads_v6'

@description('System node count')
param systemNodeCount int = 3

@description('VM size for the user node pool')
param userNodeVmSize string = 'Standard_D4ads_v6'

@description('Min user nodes for autoscaler')
param userNodeMinCount int = 2

@description('Max user nodes for autoscaler')
param userNodeMaxCount int = 10

@description('Resource ID of the Azure Private DNS Zone managed by ExternalDNS')
param privateDnsZoneId string

@description('Resource ID of the AGC-delegated subnet. When non-empty, a user-assigned managed identity for the ALB Controller is created and granted Network Reader on this subnet.')
param albSubnetId string = ''

// Extract VNet and subnet names from the subnet resource ID for role assignment
var vnetName = split(vnetSubnetId, '/')[8]
var subnetName = split(vnetSubnetId, '/')[10]

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = {
  parent: vnet
  name: subnetName
}

resource aks 'Microsoft.ContainerService/managedClusters@2026-01-01' = {
  name: name
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: name
    enableRBAC: true
    aadProfile: {
      managed: true
      enableAzureRBAC: true
    }
    azureMonitorProfile: {
      metrics: {
        enabled: true
      }
    }
    apiServerAccessProfile: {
      enablePrivateCluster: true
    }
    // Enable OIDC issuer and Workload Identity so ExternalDNS can authenticate
    // to Azure APIs without long-lived credentials.
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    addonProfiles: {
      azureKeyvaultSecretsProvider: {
        enabled: true
        config: {
          enableSecretRotation: 'false'
          rotationPollInterval: '2m'
        }
      }
      azurepolicy: {
        enabled: true
      }
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkDataplane: 'cilium'
      networkPluginMode: 'overlay'
      networkPolicy: 'cilium'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      podCidr: '10.244.0.0/16'
      loadBalancerSku: 'standard'
      advancedNetworking: {
        enabled: true
        observability: {
          enabled: true
        }
        security: {
          advancedNetworkPolicies: 'FQDN'
          enabled: true
        }
      }
    }
    agentPoolProfiles: [
      {
        name: 'system1'
        count: systemNodeCount
        vmSize: systemNodeVmSize
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: vnetSubnetId
        enableAutoScaling: false
        availabilityZones: ['1', '2', '3']
        maxPods: 110
      }
      {
        name: 'default1'
        count: userNodeMinCount
        minCount: userNodeMinCount
        maxCount: userNodeMaxCount
        vmSize: userNodeVmSize
        osType: 'Linux'
        mode: 'User'
        vnetSubnetID: vnetSubnetId
        enableAutoScaling: true
        availabilityZones: ['1', '2', '3']
        maxPods: 110
      }
    ]
  }
}

// Grant AKS identity Network Contributor on the node subnet
resource networkContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: subnet
  name: guid(subnet.id, aks.id, '4d97b98b-1d4f-4787-a291-c67834d212e7')
  properties: {
    principalId: aks.identity.principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
    )
    principalType: 'ServicePrincipal'
  }
}

// ---------------------------------------------------------------------------
// ExternalDNS Workload Identity
// ---------------------------------------------------------------------------

// Parse the DNS zone resource ID components into named variables for clarity.
// Resource ID format: /subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Network/privateDnsZones/{name}
var dnsZoneIdParts = split(privateDnsZoneId, '/')
var dnsZoneResourceGroup = !empty(privateDnsZoneId) ? dnsZoneIdParts[4] : ''
var dnsZoneName = !empty(privateDnsZoneId) ? last(dnsZoneIdParts) : ''

// User-Assigned Managed Identity for ExternalDNS
resource externalDnsIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-05-31-preview' = {
  name: 'mi-external-dns-${name}'
  location: location
}

// Federated identity credential: allows the ExternalDNS Kubernetes ServiceAccount
// in the external-dns namespace to exchange a Kubernetes token for an Azure token.
resource externalDnsFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-05-31-preview' = {
  parent: externalDnsIdentity
  name: 'external-dns-federated'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:external-dns:external-dns'
    audiences: ['api://AzureADTokenExchange']
  }
}

module externalDnsDnsContributor 'dnsZoneContributorRole.bicep' = {
  params: {
    principalId: externalDnsIdentity.properties.principalId
    privateDnsZoneName: dnsZoneName
    privateDnsZoneResourceGroup: dnsZoneResourceGroup
  }
}

// Flux extension
resource fluxExtension 'Microsoft.KubernetesConfiguration/extensions@2025-03-01' = {
  name: 'flux'
  scope: aks
  properties: {
    extensionType: 'microsoft.flux'
    autoUpgradeMinorVersion: true
    configurationSettings: {
      'multiTenancy.enforce': 'false'
    }
  }
}

// Flux GitOps configuration — GitHub source with Kustomize
resource fluxConfig 'Microsoft.KubernetesConfiguration/fluxConfigurations@2025-04-01' = {
  name: 'cluster-config'
  scope: aks
  dependsOn: [fluxExtension]
  properties: {
    scope: 'cluster'
    namespace: 'flux-system'
    sourceKind: 'GitRepository'
    gitRepository: {
      url: gitRepositoryUrl
      repositoryRef: {
        branch: gitRepositoryBranch
      }
      syncIntervalInSeconds: 120
    }
    kustomizations: {
      infra: {
        path: kustomizationPath
        syncIntervalInSeconds: 120
        prune: true
      }
    }
  }
}

// ---------------------------------------------------------------------------
// ALB Controller Workload Identity (only when AGC subnet is provided)
// ---------------------------------------------------------------------------

// User-Assigned Managed Identity for the in-cluster ALB Controller.
// The ALB Controller exchanges a Kubernetes ServiceAccount token for this
// identity's token to configure the AGC resource in Azure.
resource albControllerIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2025-05-31-preview' = if (!empty(albSubnetId)) {
  name: 'mi-alb-controller-${name}'
  location: location
}

// Federated identity credential: allows the ALB Controller ServiceAccount in
// the azure-alb-system namespace to authenticate to Azure AD as this identity.
resource albControllerFederatedCredential 'Microsoft.ManagedIdentity/userAssignedIdentities/federatedIdentityCredentials@2025-05-31-preview' = if (!empty(albSubnetId)) {
  parent: albControllerIdentity
  name: 'alb-controller-federated'
  properties: {
    issuer: aks.properties.oidcIssuerProfile.issuerURL
    subject: 'system:serviceaccount:azure-alb-system:azure-alb-controller'
    audiences: ['api://AzureADTokenExchange']
  }
}

// Extract VNet/subnet names from the ALB subnet resource ID for role scoping.
var albSubnetIdParts = split(albSubnetId, '/')
var albVnetName = !empty(albSubnetId) ? albSubnetIdParts[8] : ''
var albSubnetName = !empty(albSubnetId) ? albSubnetIdParts[10] : ''

resource albVnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = if (!empty(albSubnetId)) {
  name: albVnetName
}

resource albSubnetResource 'Microsoft.Network/virtualNetworks/subnets@2025-05-01' existing = if (!empty(albSubnetId)) {
  parent: albVnet
  name: albSubnetName
}

// Grant the ALB Controller identity Reader on the AGC-delegated subnet so it
// can read subnet metadata during AGC association reconciliation.
resource albControllerSubnetReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(albSubnetId)) {
  scope: albSubnetResource
  name: guid(albSubnetId, albControllerIdentity!.id, 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
    )
    principalId: albControllerIdentity!.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

output id string = aks.id
output name string = aks.name
output principalId string = aks.identity.principalId
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
output externalDnsIdentityClientId string = externalDnsIdentity.properties.clientId
output externalDnsIdentityPrincipalId string = externalDnsIdentity.properties.principalId
// albControllerIdentity outputs are empty strings when albSubnetId is not provided.
output albControllerIdentityClientId string = !empty(albSubnetId) ? albControllerIdentity!.properties.clientId : ''
output albControllerIdentityPrincipalId string = !empty(albSubnetId) ? albControllerIdentity!.properties.principalId : ''
