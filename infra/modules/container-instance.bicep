param containerInstanceName string
param location string
param subnetId string
param containerInstanceImage string
param managedIdentityName string
param containerRegistryName string

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' existing = {
  name: managedIdentityName
}

resource containerInstance 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerInstanceName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    containers: [
      {
        name: containerInstanceName
        properties: {
          image: containerInstanceImage
          resources: {
            requests: {
              cpu: 1
              memoryInGB: 1
            }
          }
          ports: [
            {
              port: 53
              protocol: 'UDP'
            }
          ]
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    ipAddress: {
      ports: [
        {
          port: 53
          protocol: 'UDP'
        }
      ]
      type: 'Private'
    }
    subnetIds: [
      {
        id: subnetId
      }
    ]
    imageRegistryCredentials: [
      {
        server: '${containerRegistryName}${environment().suffixes.acrLoginServer}'
        identity: managedIdentity.id
      }
    ]
  }
}
