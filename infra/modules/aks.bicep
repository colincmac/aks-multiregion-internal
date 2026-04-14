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
param systemNodeVmSize string = 'Standard_D4s_v5'

@description('System node count')
param systemNodeCount int = 3

@description('VM size for the user node pool')
param userNodeVmSize string = 'Standard_D4s_v5'

@description('Min user nodes for autoscaler')
param userNodeMinCount int = 2

@description('Max user nodes for autoscaler')
param userNodeMaxCount int = 10

// Extract VNet and subnet names from the subnet resource ID for role assignment
var vnetName = split(vnetSubnetId, '/')[8]
var subnetName = split(vnetSubnetId, '/')[10]

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: vnetName
}

resource subnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  parent: vnet
  name: subnetName
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
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
    apiServerAccessProfile: {
      enablePrivateCluster: true
    }
    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '172.16.0.0/16'
      dnsServiceIP: '172.16.0.10'
      loadBalancerSku: 'standard'
    }
    agentPoolProfiles: [
      {
        name: 'system'
        count: systemNodeCount
        vmSize: systemNodeVmSize
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: vnetSubnetId
        enableAutoScaling: false
        availabilityZones: ['1', '2', '3']
      }
      {
        name: 'user'
        count: userNodeMinCount
        minCount: userNodeMinCount
        maxCount: userNodeMaxCount
        vmSize: userNodeVmSize
        osType: 'Linux'
        mode: 'User'
        vnetSubnetID: vnetSubnetId
        enableAutoScaling: true
        availabilityZones: ['1', '2', '3']
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

// Flux extension
resource fluxExtension 'Microsoft.KubernetesConfiguration/extensions@2023-05-01' = {
  name: 'flux'
  scope: aks
  properties: {
    extensionType: 'microsoft.flux'
    autoUpgradeMinorVersion: true
  }
}

// Flux GitOps configuration — GitHub source with Kustomize
resource fluxConfig 'Microsoft.KubernetesConfiguration/fluxConfigurations@2023-05-01' = {
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

output id string = aks.id
output name string = aks.name
output principalId string = aks.identity.principalId
