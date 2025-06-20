param location string
param abbrs object
param resourceToken string

module identity 'br/public:avm/res/managed-identity/user-assigned-identity:0.2.1' = {
  name: 'identity'
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}central-${location}-${resourceToken}'
    location: location
  }
}

output managedIdentityResourceId string = identity.outputs.resourceId
output managedIdentityClientId string = identity.outputs.clientId
output managedIdentityPrincipalId string = identity.outputs.principalId
output managedIdentityName string = identity.outputs.name
