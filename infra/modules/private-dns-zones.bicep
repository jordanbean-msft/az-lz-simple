param privateDnsZoneNames array
param virtualNetworkName string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2020-11-01' existing = {
  name: virtualNetworkName
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [for privateDnsZoneName in privateDnsZoneNames: {
  name: privateDnsZoneName
  location: 'global'
  properties: {}
}]

resource virtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for privateDnsZoneName in privateDnsZoneNames: {
  name: '${privateDnsZoneName}/${virtualNetworkName}-${privateDnsZoneName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}]
