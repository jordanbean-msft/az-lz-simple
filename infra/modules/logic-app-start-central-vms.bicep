param resourceToken string
param abbrs object
param location string
param managedIdentityId string
param timeZone string
param interval int
param frequency string
param scheduleHours array
param logAnalyticsWorkspaceId string

resource armConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'arm'
  location: location
  properties: {
    displayName: 'managedIdentity'
    api: {
      name: 'arm'
      displayName: 'Azure Resource Manager'
      description: 'Azure Resource Manager exposes the APIs to manage all of your Azure resources.'
      id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/arm'
      type: 'Microsoft.Web/locations/managedApis'
    }
  }
}

resource vmConnection 'Microsoft.Web/connections@2016-06-01' = {
  name: 'azurevm'
  location: location
  properties: {
    displayName: 'vm-connection'
    api: {
      name: 'azurevm'
      displayName: 'Azure VM'
      description: 'Azure VM connector allows you to manage virtual machines.'
      id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/azurevm'
      type: 'Microsoft.Web/locations/managedApis'
    }
  }
}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: '${abbrs.logicWorkflows}central-${location}-${resourceToken}-start-central-vms'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentityId}': {}
    }
  }
  properties: {
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        '$connections': {
          defaultValue: {}
          type: 'Object'
        }
      }
      triggers: {
        Recurrence: {
          recurrence: {
            interval: interval
            frequency: frequency
            schedule: {
              hours: scheduleHours
            }
            timeZone: timeZone
          }
          evaluatedRecurrence: {
            interval: interval
            frequency: frequency
            schedule: {
              hours: scheduleHours
            }
            timeZone: timeZone
          }
          type: 'Recurrence'
        }
      }
      actions: {
        'List_resources_by_subscription_-_VMs': {
          runAfter: {
            'Initialize_variables_-_central_resource_group_name': [
              'Succeeded'
            ]
          }
          type: 'ApiConnection'
          inputs: {
            host: {
              connection: {
                name: '@parameters(\'$connections\')[\'arm\'][\'connectionId\']'
              }
            }
            method: 'get'
            path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resources'
            queries: {
              'x-ms-api-version': '2016-06-01'
              '$filter': 'resourceType eq \'Microsoft.Compute/virtualMachines\' and resourceGroup eq \'@{variables(\'central_resource_group_name\')}\''
            }
          }
        }
        For_each_3: {
          foreach: '@body(\'List_resources_by_subscription_-_VMs\')?[\'value\']'
          actions: {
            'Compose_-_Get_Resource_Group_Name_-_VMs': {
              type: 'Compose'
              inputs: '@split(item()?[\'id\'], \'/\')[4]'
            }
            Start_virtual_machine: {
              runAfter: {
                'Compose_-_Get_Resource_Group_Name_-_VMs': [
                  'Succeeded'
                ]
              }
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '@parameters(\'$connections\')[\'azurevm\'][\'connectionId\']'
                  }
                }
                method: 'post'
                path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(outputs(\'Compose_-_Get_Resource_Group_Name_-_VMs\'))}/providers/Microsoft.Compute/virtualMachines/@{encodeURIComponent(item()?[\'name\'])}/start'
                queries: {
                  'api-version': '2019-12-01'
                }
              }
            }
          }
          runAfter: {
            'List_resources_by_subscription_-_VMs': [
              'Succeeded'
            ]
          }
          type: 'Foreach'
        }
        'Initialize_variables_-_central_resource_group_name': {
          runAfter: {}
          type: 'InitializeVariable'
          inputs: {
            variables: [
              {
                name: 'central_resource_group_name'
                type: 'string'
                value: resourceGroup().name
              }
            ]
          }
        }
      }
      outputs: {}
    }
    parameters: {
      '$connections': {
        value: {
          arm: {
            id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/arm'
            connectionId: armConnection.id
            connectionName: 'arm'
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: managedIdentityId
              }
            }
          }
          azurevm: {
            id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/${location}/managedApis/azurevm'
            connectionId: vmConnection.id
            connectionName: 'azurevm'
            connectionProperties: {
              authentication: {
                type: 'ManagedServiceIdentity'
                identity: managedIdentityId
              }
            }
          }
        }
      }
    }
  }
}

resource logicAppLogging 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'logging'
  scope: workflow
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output logicAppId string = workflow.id
