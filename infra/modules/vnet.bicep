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

@description('Bastion subnet prefix')
param bastionSubnetPrefix string

@description('VM subnet prefix')
param utilityVMSubnetPrefix string

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
      {
        name: 'AzureBastionSubnet'
        properties: {
          addressPrefix: bastionSubnetPrefix
        }
      }
      {
        name: 'snet-utility'
        properties: {
          addressPrefix: utilityVMSubnetPrefix
        }
      }
    ]
  }
}

output id string = vnet.id
output name string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output ilbSubnetId string = vnet.properties.subnets[1].id
output bastionSubnetId string = vnet.properties.subnets[2].id
output utilityVMSubnetId string = vnet.properties.subnets[3].id
