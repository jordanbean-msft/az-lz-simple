@description('Unique token used to generate resource names')
param resourceToken string

@description('Azure resource abbreviation prefixes')
param abbrs object

@description('Location for the network security perimeter')
param location string

@description('List of approved inbound IP address prefixes (e.g. 203.0.113.10/32). Sourced from the azd environment so the values are not checked into source control.')
param allowedInboundIpAddresses array

@description('Resource ids of the resources to associate with the network security perimeter')
param associatedResourceIds array

@description('Access mode used for the resource associations')
@allowed(['Learning', 'Enforced'])
param associationAccessMode string = 'Enforced'

resource networkSecurityPerimeter 'Microsoft.Network/networkSecurityPerimeters@2024-07-01' = {
  name: '${abbrs.networkNetworkSecurityPerimeters}${resourceToken}'
  location: location
}

resource profile 'Microsoft.Network/networkSecurityPerimeters/profiles@2024-07-01' = {
  parent: networkSecurityPerimeter
  name: 'default'
}

resource inboundAccessRule 'Microsoft.Network/networkSecurityPerimeters/profiles/accessRules@2024-07-01' = if (!empty(allowedInboundIpAddresses)) {
  parent: profile
  name: 'allow-approved-inbound-ip-addresses'
  properties: {
    direction: 'Inbound'
    addressPrefixes: allowedInboundIpAddresses
  }
}

resource resourceAssociations 'Microsoft.Network/networkSecurityPerimeters/resourceAssociations@2024-07-01' = [
  for (associatedResourceId, i) in associatedResourceIds: {
    parent: networkSecurityPerimeter
    name: 'assoc-${uniqueString(associatedResourceId)}'
    properties: {
      accessMode: associationAccessMode
      privateLinkResource: {
        id: associatedResourceId
      }
      profile: {
        id: profile.id
      }
    }
  }
]

output networkSecurityPerimeterId string = networkSecurityPerimeter.id
output networkSecurityPerimeterName string = networkSecurityPerimeter.name
output profileId string = profile.id
