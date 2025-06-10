param logicAppName string
param location string
param managedIdentityId string
param timeZone string
param interval int
param frequency string
param scheduleHours array

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

resource logicApp 'Microsoft.Logic/workflows@2017-07-01' = {
  name: logicAppName
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
        'List_resources_by_subscription_-_Container_Apps': {
          runAfter: {}
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
              '$filter': 'resourceType eq \'Microsoft.App/containerApps\''
            }
          }
        }
        For_each: {
          foreach: '@body(\'List_resources_by_subscription_-_Container_Apps\')?[\'value\']'
          actions: {
            'Invoke_resource_operation_-_Stop_Container_App': {
              runAfter: {
                'Compose_-_Get_Resource_Group_Name_-_Container_App': [
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
                method: 'post'
                path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(outputs(\'Compose_-_Get_Resource_Group_Name_-_Container_App\'))}/providers/@{encodeURIComponent(\'Microsoft.App/containerApps\')}/@{encodeURIComponent(item()?[\'name\'])}/@{encodeURIComponent(\'stop\')}'
                queries: {
                  'x-ms-api-version': '2024-03-01'
                }
              }
            }
            'Compose_-_Get_Resource_Group_Name_-_Container_App': {
              type: 'Compose'
              inputs: '@split(item()?[\'id\'], \'/\')[4]'
            }
          }
          runAfter: {
            'List_resources_by_subscription_-_AKS': [
              'Succeeded'
            ]
          }
          type: 'Foreach'
        }
        For_each_1: {
          foreach: '@body(\'List_resources_by_subscription_-_Function_Apps\')?[\'value\']'
          actions: {
            'Compose_-_Get_Resource_Group_Name_-_Function': {
              type: 'Compose'
              inputs: '@split(item()?[\'id\'], \'/\')[4]'
            }
            'Invoke_resource_operation_-_Function_App': {
              runAfter: {
                'Compose_-_Get_Resource_Group_Name_-_Function': [
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
                method: 'post'
                path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(outputs(\'Compose_-_Get_Resource_Group_Name_-_Function\'))}/providers/@{encodeURIComponent(\'Microsoft.Web/sites/functions\')}/@{encodeURIComponent(item()?[\'name\'])}/@{encodeURIComponent(\'stop\')}'
                queries: {
                  'x-ms-api-version': '2024-03-01'
                }
              }
            }
          }
          runAfter: {
            'List_resources_by_subscription_-_AKS': [
              'Succeeded'
            ]
          }
          type: 'Foreach'
        }
        'List_resources_by_subscription_-_Function_Apps': {
          runAfter: {
            'List_resources_by_subscription_-_Container_Apps': [
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
              '$filter': 'resourceType eq \'Microsoft.Web/sites/functions\''
            }
          }
        }
        'List_resources_by_subscription_-_AKS': {
          runAfter: {
            'List_resources_by_subscription_-_Function_Apps': [
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
              '$filter': 'resourceType eq \'Microsoft.ContainerService/managedClusters\''
            }
          }
        }
        For_each_2: {
          type: 'Foreach'
          foreach: '@body(\'List_resources_by_subscription_-_AKS\')?[\'value\']'
          actions: {
            'Compose_-_Get_Resource_Group_Name_-_AKS': {
              type: 'Compose'
              inputs: '@split(item()?[\'id\'], \'/\')[4]'
            }
            Condition: {
              type: 'If'
              expression: {
                and: [
                  {
                    equals: [
                      '@body(\'Read_a_resource\')?[\'properties\'][\'powerState\'][\'code\']'
                      'Running'
                    ]
                  }
                ]
              }
              actions: {
                'Invoke_resource_operation_-_AKS_-_Stop': {
                  type: 'ApiConnection'
                  inputs: {
                    host: {
                      connection: {
                        name: '@parameters(\'$connections\')[\'arm\'][\'connectionId\']'
                      }
                    }
                    method: 'post'
                    path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(outputs(\'Compose_-_Get_Resource_Group_Name_-_AKS\'))}/providers/@{encodeURIComponent(\'Microsoft.ContainerService/managedClusters\')}/@{encodeURIComponent(item()?[\'name\'])}/@{encodeURIComponent(\'stop\')}'
                    queries: {
                      'x-ms-api-version': '2024-01-01'
                    }
                  }
                }
              }
              else: {
                actions: {}
              }
              runAfter: {
                Read_a_resource: [
                  'Succeeded'
                ]
              }
            }
            Read_a_resource: {
              type: 'ApiConnection'
              inputs: {
                host: {
                  connection: {
                    name: '@parameters(\'$connections\')[\'arm\'][\'connectionId\']'
                  }
                }
                method: 'get'
                path: '/subscriptions/@{encodeURIComponent(\'${subscription().subscriptionId}\')}/resourcegroups/@{encodeURIComponent(outputs(\'Compose_-_Get_Resource_Group_Name_-_AKS\'))}/providers/@{encodeURIComponent(\'Microsoft.ContainerService/managedClusters\')}/@{encodeURIComponent(item()?[\'name\'])}'
                queries: {
                  'x-ms-api-version': '2025-04-01'
                }
              }
              runAfter: {
                'Compose_-_Get_Resource_Group_Name_-_AKS': [
                  'Succeeded'
                ]
              }
            }
          }
          runAfter: {
            'List_resources_by_subscription_-_AKS': [
              'Succeeded'
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
            id: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Web/locations/eastus2/managedApis/arm'
            connectionId: armConnection.id
            connectionName: 'arm'
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

output logicAppId string = logicApp.id
