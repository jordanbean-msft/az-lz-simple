targetScope = 'subscription'

param resourceGroupName string
param userAssignedIdentityName string
param location string
param virtualNetworkName string
param privateZonesMappingData object

var privateDnsZoneNames = union(flatten(map(privateZonesMappingData.privateZonesMapping, privateDnsZone => privateDnsZone.privateDnsZoneName)), [])

module privateDnsZones './private-dns-zones.bicep' = {
  name: 'private-dns-zones'
  scope: resourceGroup(resourceGroupName)
  params: {
    privateDnsZoneNames: privateDnsZoneNames
    virtualNetworkName: virtualNetworkName
  }
}

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: userAssignedIdentityName
  scope: resourceGroup(resourceGroupName)
}

resource privateDnsZoneGroupPolicyAssignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = [for privateDnsZonePolicy in privateZonesMappingData.privateZonesMapping: if(!empty(privateDnsZonePolicy.privateLinkResourceType)) {
  name: '${replace(toLower(privateDnsZonePolicy.resource), ' ', '-')}-${toLower(privateDnsZonePolicy.subresource)}'
  dependsOn: [
    privateDnsZones
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  location: location
  properties: {
    displayName: 'Azure PaaS Private DNS Zone - ${privateDnsZonePolicy.privateLinkResourceType}/${privateDnsZonePolicy.subresource}'
    policyDefinitionId: policyDefinition.id    
    parameters: {
      privateDnsZoneIds: {
        value: [for zone in privateDnsZonePolicy.privateDnsZoneName: '${subscription().id}/resourceGroups/${resourceGroupName}/providers/Microsoft.Network/privateDnsZones/${zone}']
      }
      privateEndpointPrivateLinkServiceId: {
        value: privateDnsZonePolicy.privateLinkResourceType
      }
      privateEndpointGroupId: {
        value: privateDnsZonePolicy.subresource
      }
    }
  }
}]

var deployPolicy = loadJsonContent('./deploy-policy.json')

resource policyDefinition 'Microsoft.Authorization/policyDefinitions@2023-04-01' = {
  name: 'private-dns-zone-policy-definition'
  dependsOn: [
    privateDnsZones
  ]
  properties: {
    policyType: 'Custom'
    mode: 'Indexed'
    parameters: deployPolicy.properties.parameters
    policyRule: deployPolicy.properties.policyRule
  }
}
