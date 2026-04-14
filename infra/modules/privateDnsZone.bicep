@description('Private DNS zone name')
param zoneName string

@description('VNet links: array of {name, vnetId}')
param vnetLinks array

resource dnsZone 'Microsoft.Network/privateDnsZones@2020-06-01' = {
  name: zoneName
  location: 'global'
}

resource links 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [
  for link in vnetLinks: {
    parent: dnsZone
    name: link.name
    location: 'global'
    properties: {
      virtualNetwork: {
        id: link.vnetId
      }
      registrationEnabled: false
    }
  }
]

output id string = dnsZone.id
output name string = dnsZone.name
