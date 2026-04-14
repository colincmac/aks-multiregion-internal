targetScope = 'subscription'

@description('Base name prefix for all resources')
param environmentName string

@description('Location for the East region')
param eastLocation string = 'eastus'

@description('Location for the West region')
param westLocation string = 'westus'

@description('Kubernetes version')
param kubernetesVersion string = '1.30'

@description('Git repository URL for Flux (HTTPS)')
param gitRepositoryUrl string

@description('Git branch for Flux')
param gitRepositoryBranch string = 'main'

@description('Kustomization path for the East cluster')
param kustomizationPathEast string = './clusters/east'

@description('Kustomization path for the West cluster')
param kustomizationPathWest string = './clusters/west'

@description('Private DNS zone for internal services')
param privateDnsZoneName string = 'internal.contoso.com'

// ---------------------------------------------------------------------------
// Resource Groups
// ---------------------------------------------------------------------------

resource rgEast 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-east'
  location: eastLocation
}

resource rgWest 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-west'
  location: westLocation
}

resource rgGlobal 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-global'
  location: eastLocation
}

// ---------------------------------------------------------------------------
// Virtual Networks
// ---------------------------------------------------------------------------

module vnetEast 'modules/vnet.bicep' = {
  name: 'vnet-east'
  scope: rgEast
  params: {
    name: 'vnet-${environmentName}-east'
    location: eastLocation
    addressPrefix: '10.1.0.0/16'
    aksSubnetPrefix: '10.1.0.0/20'
    ilbSubnetPrefix: '10.1.16.0/24'
  }
}

module vnetWest 'modules/vnet.bicep' = {
  name: 'vnet-west'
  scope: rgWest
  params: {
    name: 'vnet-${environmentName}-west'
    location: westLocation
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
  }
}

// ---------------------------------------------------------------------------
// VNet Peering (bidirectional)
// ---------------------------------------------------------------------------

module peeringEastToWest 'modules/vnetPeering.bicep' = {
  name: 'peering-east-to-west'
  scope: rgEast
  params: {
    localVnetName: vnetEast.outputs.name
    remoteVnetId: vnetWest.outputs.id
    peeringName: 'east-to-west'
  }
}

module peeringWestToEast 'modules/vnetPeering.bicep' = {
  name: 'peering-west-to-east'
  scope: rgWest
  params: {
    localVnetName: vnetWest.outputs.name
    remoteVnetId: vnetEast.outputs.id
    peeringName: 'west-to-east'
  }
}

// ---------------------------------------------------------------------------
// AKS Clusters (private, Azure CNI, Flux GitOps)
// ---------------------------------------------------------------------------

module aksEast 'modules/aks.bicep' = {
  name: 'aks-east'
  scope: rgEast
  params: {
    name: 'aks-${environmentName}-east'
    location: eastLocation
    kubernetesVersion: kubernetesVersion
    vnetSubnetId: vnetEast.outputs.aksSubnetId
    gitRepositoryUrl: gitRepositoryUrl
    gitRepositoryBranch: gitRepositoryBranch
    kustomizationPath: kustomizationPathEast
  }
}

module aksWest 'modules/aks.bicep' = {
  name: 'aks-west'
  scope: rgWest
  params: {
    name: 'aks-${environmentName}-west'
    location: westLocation
    kubernetesVersion: kubernetesVersion
    vnetSubnetId: vnetWest.outputs.aksSubnetId
    gitRepositoryUrl: gitRepositoryUrl
    gitRepositoryBranch: gitRepositoryBranch
    kustomizationPath: kustomizationPathWest
  }
}

// ---------------------------------------------------------------------------
// Private DNS Zone + VNet Links
// ---------------------------------------------------------------------------

module privateDns 'modules/privateDnsZone.bicep' = {
  name: 'private-dns'
  scope: rgGlobal
  params: {
    zoneName: privateDnsZoneName
    vnetLinks: [
      {
        name: 'link-east'
        vnetId: vnetEast.outputs.id
      }
      {
        name: 'link-west'
        vnetId: vnetWest.outputs.id
      }
    ]
  }
}
