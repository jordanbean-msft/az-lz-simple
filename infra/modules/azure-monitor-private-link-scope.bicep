param name string

resource privateLinkScope 'Microsoft.Insights/privateLinkScopes@2021-07-01-preview' = {
  name: name
  location: 'global'
  properties: {
    accessModeSettings: {
      ingestionAccessMode: 'PrivateOnly'
      queryAccessMode: 'PrivateOnly'
    }
  }
}

output privateLinkScopeName string = privateLinkScope.name
