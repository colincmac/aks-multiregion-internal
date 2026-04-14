param privateDnsZoneName string
param privateDnsZoneResourceGroup string
param principalId string 

resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = {
  name: privateDnsZoneName
  scope: resourceGroup(privateDnsZoneResourceGroup)
}

resource externalDnsDnsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  // Scope to the specific Private DNS Zone so the identity cannot modify other zones.
  name: guid(dnsZone.id, principalId, 'b12aa53e-6015-4669-85d0-8515ebb3ae7f')
  properties: {
    principalId: principalId
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      'b12aa53e-6015-4669-85d0-8515ebb3ae7f' // Private DNS Zone Contributor
    )
    principalType: 'ServicePrincipal'
  }
}
