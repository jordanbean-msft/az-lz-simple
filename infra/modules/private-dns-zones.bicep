param privateDnsZoneNames array
param virtualNetworkName string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2020-11-01' existing = {
  name: virtualNetworkName
}

resource privateDnsZones 'Microsoft.Network/privateDnsZones@2020-06-01' = [
  for privateDnsZoneName in privateDnsZoneNames: {
    name: privateDnsZoneName
    location: 'global'
    properties: {}
  }
]

// Virtual network link resource names are capped at 80 characters by Azure. Fall back to a
// truncated, hashed name when the natural '{vnet}-{zone}' combination would exceed that limit
// (e.g. long regional zone names like privatelink.swedencentral.azurecontainerapps.io).
resource virtualNetworkLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for privateDnsZoneName in privateDnsZoneNames: {
    name: '${privateDnsZoneName}/${length('${virtualNetworkName}-${privateDnsZoneName}') > 80 ? '${take(virtualNetworkName, 10)}-${uniqueString(virtualNetworkName, privateDnsZoneName)}-${take(replace(privateDnsZoneName, '.', '-'), 40)}' : '${virtualNetworkName}-${privateDnsZoneName}'}'
    location: 'global'
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: virtualNetwork.id
      }
      resolutionPolicy: contains(privateDnsZoneName, 'privatelink') ? 'NxDomainRedirect' : null
    }
    dependsOn: [
      privateDnsZones
    ]
  }
]
