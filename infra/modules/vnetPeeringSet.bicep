@description('Name of the local VNet')
param localVnetName string

@description('All VNets in the mesh: array of { name, id }. Self-peering is skipped automatically.')
param allVnets array

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' existing = {
  name: localVnetName
}

resource peerings 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2025-05-01' = [
  for remote in allVnets: if (remote.name != localVnetName) {
    parent: vnet
    name: '${localVnetName}-to-${remote.name}'
    properties: {
      remoteVirtualNetwork: {
        id: remote.id
      }
      allowVirtualNetworkAccess: true
      allowForwardedTraffic: true
      allowGatewayTransit: false
      useRemoteGateways: false
    }
  }
]

