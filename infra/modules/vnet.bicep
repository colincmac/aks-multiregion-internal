@description('Name of the virtual network')
param name string

@description('Azure region')
param location string

@description('VNet address prefix')
param addressPrefix string

@description('AKS node subnet prefix')
param aksSubnetPrefix string

@description('Internal load balancer subnet prefix')
param ilbSubnetPrefix string

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: [
      {
        name: 'snet-aks'
        properties: {
          addressPrefix: aksSubnetPrefix
        }
      }
      {
        name: 'snet-ilb'
        properties: {
          addressPrefix: ilbSubnetPrefix
        }
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output ilbSubnetId string = vnet.properties.subnets[1].id
