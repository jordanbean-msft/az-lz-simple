param resourceToken string
param abbrs object
param location string
param privateEndpointSubnetResourceId string

resource storageAccount 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: '${abbrs.storageStorageAccounts}${location}${resourceToken}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    publicNetworkAccess: 'Disabled'
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    largeFileSharesState: 'Enabled'
    networkAcls: {
      bypass: 'AzureServices'
      defaultAction: 'Allow'
    }
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2021-05-01' = {
  name: 'pe-blob-${storageAccount.name}'
  location: location
  properties: {
    subnet: {
      id: privateEndpointSubnetResourceId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-blob-${storageAccount.name}'
        properties: {
          privateLinkServiceId: storageAccount.id
          groupIds: [
            'blob'
          ]
        }
      }
    ]
  }
}

// resource storageAccountLogging 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
//   name: 'logging'
//   scope: storageAccount
//   properties: {
//     workspaceId: logAnalyticsWorkspaceId
//     logs: [
//       {
//         category: 'transaction'
//         enabled: true
//       }
//     ]
//     metrics: [
//       {
//         category: 'AllMetrics'
//         enabled: true
//       }
//     ]
//   }
// }

output storageAccountId string = storageAccount.id
output storageAccountName string = storageAccount.name
