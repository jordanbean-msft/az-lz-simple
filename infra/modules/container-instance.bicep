param resourceToken string
param abbrs object
param location string
param subnetId string
param containerInstanceImage string
param managedIdentityResourceId string
param containerRegistryName string
param logAnalyticsWorkspaceId string

module containerInstance 'br/public:avm/res/container-instance/container-group:0.6.0' = {
  name: 'container-instance'
  params: {
    name: '${abbrs.containerInstanceContainerGroups}central-${location}-${resourceToken}-dns'
    location: location
    managedIdentities: {
      userAssignedResourceIds: [
        managedIdentityResourceId
      ]
    }
    availabilityZone: -1
    containers: [
      {
        name: 'dns'
        properties: {
          image: containerInstanceImage
          resources: {
            requests: {
              cpu: 1
              memoryInGB: '1'
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
    subnets: [
      {
        subnetResourceId: subnetId
      }
    ]
    imageRegistryCredentials: [
      {
        server: '${containerRegistryName}${environment().suffixes.acrLoginServer}'
        identity: managedIdentityResourceId
      }
    ]
    logAnalytics: {
      logType: 'ContainerInstanceLogs'
      workspaceResourceId: logAnalyticsWorkspaceId
    }
  }
}

output containerInstanceName string = containerInstance.outputs.name
output containerInstanceResourceId string = containerInstance.outputs.resourceId
output containerInstanceFqdn string = containerInstance.outputs.iPv4Address
