targetScope = 'subscription'

@description('Base name prefix for all resources')
param environmentName string

@description('Kubernetes version')
param kubernetesVersion string = '1.35'

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

resource rgs 'Microsoft.Resources/resourceGroups@2025-04-01' = [
  for cluster in clusters: {
    name: 'rg-${environmentName}-${cluster.name}'
    location: cluster.location
  }
]

resource rgGlobal 'Microsoft.Resources/resourceGroups@2025-04-01' = {
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
    dependsOn: [
      rgs
      rgGlobal
    ]
    params: {
      name: 'vnet-${environmentName}-${cluster.name}'
      location: cluster.location
      addressPrefix: cluster.addressPrefix
      aksSubnetPrefix: cluster.aksSubnetPrefix
      ilbSubnetPrefix: cluster.ilbSubnetPrefix
    }
  }
]

module hubVnet 'modules/vnet.bicep' = {
  name: 'vnet-${environmentName}-global'
  scope: rgGlobal
  params: {
    name: 'vnet-${environmentName}-global'
    location: globalResourcesLocation
    addressPrefix: '10.10.0.0/16'
    aksSubnetPrefix: '10.10.1.0/20'
    ilbSubnetPrefix: '10.10.2.0/24'
  }
}
// ---------------------------------------------------------------------------
// VNet Peering — full mesh (every VNet peers with every other)
// Each cluster gets a module that creates outbound peerings to all others.
// ---------------------------------------------------------------------------

var vnetDefinitions = [
  for (cluster, i) in clusters: {
    id: resourceId(
      subscription().subscriptionId,
      rgs[i].name,
      'Microsoft.Network/virtualNetworks',
      'vnet-${environmentName}-${cluster.name}'
    )
    name: 'vnet-${environmentName}-${cluster.name}'
  }
]

var allVnetDefinitions = union(vnetDefinitions, [
  {
    id: hubVnet.outputs.id
    name: hubVnet.outputs.name
  }
])

module clusterPeerings 'modules/vnetPeeringSet.bicep' = [
  for (cluster, i) in clusters: {
    name: 'peerings-from-${cluster.name}'
    scope: rgs[i]
    params: {
      localVnetName: vnetDefinitions[i].name
      allVnets: vnetDefinitions
    }
  }
]

module hubPeerings 'modules/vnetPeeringSet.bicep' = {
  name: 'peerings-from-global'
  scope: rgGlobal
  params: {
    localVnetName: hubVnet.outputs.name
    allVnets: allVnetDefinitions
  }
}

// ---------------------------------------------------------------------------
// Private DNS Zone + VNet Links (all VNets linked)
// ---------------------------------------------------------------------------

module privateDns 'modules/privateDnsZone.bicep' = {
  name: 'private-dns'
  scope: rgGlobal
  dependsOn: [
    vnets
  ]
  params: {
    zoneName: privateDnsZoneName
    vnetLinks: [
      for (cluster, i) in clusters: {
        name: 'link-${cluster.name}'
        vnetId: vnetDefinitions[i].id
      }
    ]
  }
}

// ---------------------------------------------------------------------------
// AKS Clusters (private, Azure CNI, Flux GitOps) — one per cluster
// ---------------------------------------------------------------------------

module aksClusters 'modules/aks.bicep' = [
  for (cluster, i) in clusters: {
    name: 'aks-${cluster.name}'
    scope: rgs[i]
    dependsOn: [
      vnets
    ]
    params: {
      name: 'aks-${environmentName}-${cluster.name}'
      location: cluster.location
      kubernetesVersion: kubernetesVersion
      vnetSubnetId: vnets[i].outputs.aksSubnetId
      gitRepositoryUrl: gitRepositoryUrl
      gitRepositoryBranch: gitRepositoryBranch
      kustomizationPath: cluster.kustomizationPath
      privateDnsZoneId: privateDns.outputs.id
    }
  }
]
