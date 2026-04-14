targetScope = 'subscription'

@description('Base name prefix for all resources')
param environmentName string

@description('Kubernetes version')
param kubernetesVersion string = '1.30'

@description('Git repository URL for Flux (HTTPS)')
param gitRepositoryUrl string

@description('Git branch for Flux')
param gitRepositoryBranch string = 'main'

@description('Private DNS zone for internal services')
param privateDnsZoneName string = 'internal.contoso.com'

@description('Location for global shared resources (DNS zone resource group)')
param globalResourcesLocation string = 'eastus'

@description('Array of cluster configurations. Each element: { name, location, addressPrefix, aksSubnetPrefix, ilbSubnetPrefix, kustomizationPath }')
param clusters array

// ---------------------------------------------------------------------------
// Resource Groups — one per cluster + one global
// ---------------------------------------------------------------------------

resource rgs 'Microsoft.Resources/resourceGroups@2024-03-01' = [
  for cluster in clusters: {
    name: 'rg-${environmentName}-${cluster.name}'
    location: cluster.location
  }
]

resource rgGlobal 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${environmentName}-global'
  location: globalResourcesLocation
}

// ---------------------------------------------------------------------------
// Virtual Networks — one per cluster
// ---------------------------------------------------------------------------

module vnets 'modules/vnet.bicep' = [
  for (cluster, i) in clusters: {
    name: 'vnet-${cluster.name}'
    scope: rgs[i]
    params: {
      name: 'vnet-${environmentName}-${cluster.name}'
      location: cluster.location
      addressPrefix: cluster.addressPrefix
      aksSubnetPrefix: cluster.aksSubnetPrefix
      ilbSubnetPrefix: cluster.ilbSubnetPrefix
    }
  }
]

// ---------------------------------------------------------------------------
// VNet Peering — full mesh (every VNet peers with every other)
// ---------------------------------------------------------------------------

var clusterCount = length(clusters)

module peerings 'modules/vnetPeering.bicep' = [
  for k in range(0, clusterCount * clusterCount): if ((k / clusterCount) != (k % clusterCount)) {
    name: 'peering-${clusters[k / clusterCount].name}-to-${clusters[k % clusterCount].name}'
    scope: rgs[k / clusterCount]
    params: {
      localVnetName: vnets[k / clusterCount].outputs.name
      remoteVnetId: vnets[k % clusterCount].outputs.id
      peeringName: '${clusters[k / clusterCount].name}-to-${clusters[k % clusterCount].name}'
    }
  }
]

// ---------------------------------------------------------------------------
// AKS Clusters (private, Azure CNI, Flux GitOps) — one per cluster
// ---------------------------------------------------------------------------

module aksClusters 'modules/aks.bicep' = [
  for (cluster, i) in clusters: {
    name: 'aks-${cluster.name}'
    scope: rgs[i]
    params: {
      name: 'aks-${environmentName}-${cluster.name}'
      location: cluster.location
      kubernetesVersion: kubernetesVersion
      vnetSubnetId: vnets[i].outputs.aksSubnetId
      gitRepositoryUrl: gitRepositoryUrl
      gitRepositoryBranch: gitRepositoryBranch
      kustomizationPath: cluster.kustomizationPath
    }
  }
]

// ---------------------------------------------------------------------------
// Private DNS Zone + VNet Links (all VNets linked)
// ---------------------------------------------------------------------------

module privateDns 'modules/privateDnsZone.bicep' = {
  name: 'private-dns'
  scope: rgGlobal
  params: {
    zoneName: privateDnsZoneName
    vnetLinks: [
      for (cluster, i) in clusters: {
        name: 'link-${cluster.name}'
        vnetId: vnets[i].outputs.id
      }
    ]
  }
}
