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

@description('Subnet prefix for the AGC-delegated subnet. Must be /24 or larger, empty (no-op) if AGC is not being deployed in this region.')
param albSubnetPrefix string = ''

resource vnet 'Microsoft.Network/virtualNetworks@2025-05-01' = {
  name: name
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [addressPrefix]
    }
    subnets: concat(
      [
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
      ],
      !empty(albSubnetPrefix)
        ? [
            {
              // Delegated subnet for Azure Application Gateway for Containers (AGC).
              // Must be /24 or larger and empty before delegation.
              name: 'snet-agc'
              properties: {
                addressPrefix: albSubnetPrefix
                delegations: [
                  {
                    name: 'Microsoft.ServiceNetworking.trafficControllers'
                    properties: {
                      serviceName: 'Microsoft.ServiceNetworking/trafficControllers'
                    }
                  }
                ]
              }
            }
          ]
        : []
    )
  }
}

output id string = vnet.id
output name string = vnet.name
output aksSubnetId string = vnet.properties.subnets[0].id
output ilbSubnetId string = vnet.properties.subnets[1].id
output bastionSubnetId string = vnet.properties.subnets[2].id
output utilityVMSubnetId string = vnet.properties.subnets[3].id
// albSubnetId is only populated when albSubnetPrefix is provided; empty string otherwise.
output albSubnetId string = !empty(albSubnetPrefix) ? vnet.properties.subnets[4].id : ''
