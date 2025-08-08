targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

param resourceGroupName string

param virtualNetworkAddressSpace array
param gatewaySubnetName string
param gatewaySubnetAddressPrefix string
param clientAddressPoolAddressPrefix string
param vmSubnetName string
param vmSubnetAddressPrefix string
param vpnGatewayServicePrincipalClientId string
param customRoutesAddressPrefixes array
@allowed(['commercial', 'government'])
param privateZonesMappingDataFileType string
param privateEndpointSubnetName string
param privateEndpointSubnetAddressPrefix string
param timeZone string
param interval int
param frequency string
param scheduleHours array
//param dnsResolverImageName string
param containerRegistryName string
param githubRepoUrl string
@secure()
param githubRunnerToken string
@secure()
param adminUsername string
@secure()
param adminPassword string

var dnsResolverCloudInitTemplate = loadTextContent('cloud-init/dns-resolver.txt')
var githubActionsRunnerCloudInitTemplate = loadTextContent('cloud-init/github-actions-runner.txt')

//replace the string "<YOUR_GITHUB_REPO_URL>" with the actual GitHub repo URL
var githubActionsRunnerCloudInit = replace(
  replace(githubActionsRunnerCloudInitTemplate, '<YOUR_GITHUB_REPO_URL>', githubRepoUrl),
  '<YOUR_RUNNER_TOKEN>',
  githubRunnerToken
)

var dnsResolverCloudInit = dnsResolverCloudInitTemplate

@description('Id of the user or app to assign application roles')
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var privateZonesMappingData = (privateZonesMappingDataFileType == 'commercial')
  ? loadJsonContent('./commercial.private-zones.json')
  : loadJsonContent('./government.private-zones.json')

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' existing = {
  name: resourceGroupName
}

module names 'resource-names.bicep' = {
  scope: az.resourceGroup(resourceGroup.name)
  name: 'resource-names'
  params: {
    resourceToken: resourceToken
  }
}

module logAnalyticsWorkspaceDeployment './modules/log-analytics.bicep' = {
  name: 'log-analytics-workspace-deployment'
  scope: resourceGroup
  params: {
    location: location
    resourceToken: resourceToken
    abbrs: abbrs
  }
}

module virtualNetworkDeployment './modules/virtual-network.bicep' = {
  name: 'virtual-network-deployment'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    virtualNetworkAddressSpace: virtualNetworkAddressSpace
    gatewaySubnetName: gatewaySubnetName
    gatewaySubnetAddressPrefix: gatewaySubnetAddressPrefix
    vmSubnetName: vmSubnetName
    vmSubnetAddressPrefix: vmSubnetAddressPrefix
    privateEndpointSubnetName: privateEndpointSubnetName
    privateEndpointSubnetAddressPrefix: privateEndpointSubnetAddressPrefix
  }
}

module acrPullRoleAssignmentDeployment './modules/acr-pull-role-assignment.bicep' = {
  name: 'acr-pull-role-assignment-deployment'
  scope: resourceGroup
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
    containerRegistryName: containerRegistryName
  }
}

// module containerInstanceDeployment './modules/container-instance.bicep' = {
//   name: 'container-instance-deployment'
//   scope: resourceGroup
//   params: {
//     location: location
//     subnetId: virtualNetworkDeployment.outputs.containerInstanceSubnetResourceId
//     containerInstanceImage: dnsResolverImageName
//     managedIdentityResourceId: managedIdentityDeployment.outputs.managedIdentityResourceId
//     containerRegistryName: containerRegistryName
//     logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
//     abbrs: abbrs
//     resourceToken: resourceToken
//   }
//   dependsOn: [
//     acrPullRoleAssignmentDeployment
//   ]
// }

// module dnsPrivateResolver './modules/dns-private-resolver.bicep' = {
//   name: 'dns-private-resolver'
//   scope: resourceGroup
//   params: {
//     dnsResolverName: 'dnsresolver-central-${location}-${resourceToken}'
//     location: location
//     virtualNetworkName: virtualNetwork.outputs.virtualNetworkName
//     inboundSubnetName: dnsPrivateResolverInboundSubnetName
//     outboundSubnetName: dnsPrivateResolverOutboundSubnetName
//   }
// }

module dnsResolverDeployment './modules/virtual-machine.bicep' = {
  name: 'dns-resolver-deployment'
  scope: resourceGroup
  params: {
    location: location
    subnetResourceId: virtualNetworkDeployment.outputs.vmSubnetResourceId
    resourceToken: '-dns-${resourceToken}'
    abbrs: abbrs
    adminUsername: adminUsername
    adminPassword: adminPassword
    customData: dnsResolverCloudInit
    diskSizeGB: 30
    osType: 'Linux'
    sku: '22_04-lts'
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    version: 'latest'
    vmSize: 'Standard_B1s'
    privateIPAddress: '10.255.1.4'
  }
}

module githubActionsRunnerDeployment './modules/virtual-machine.bicep' = {
  name: 'github-actions-runner-deployment'
  scope: resourceGroup
  dependsOn: [
    dnsResolverDeployment
  ]
  params: {
    location: location
    subnetResourceId: virtualNetworkDeployment.outputs.vmSubnetResourceId
    resourceToken: '-gha-${resourceToken}'
    abbrs: abbrs
    adminUsername: adminUsername
    adminPassword: adminPassword
    customData: githubActionsRunnerCloudInit
    diskSizeGB: 30
    osType: 'Linux'
    sku: '22_04-lts'
    publisher: 'Canonical'
    offer: '0001-com-ubuntu-server-jammy'
    version: 'latest'
    vmSize: 'Standard_B1s'
    privateIPAddress: '10.255.1.5'
  }
}

module managedIdentityDeployment './modules/managed-identity.bicep' = {
  name: 'managed-identity-deployment'
  scope: resourceGroup
  params: {
    location: location
    abbrs: abbrs
    resourceToken: resourceToken
  }
}

module networkContributorRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'managed-identity-network-contributor-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
  }
}

module vpnGatewayDeployment './modules/vpn-gateway.bicep' = {
  name: 'vpn-gateway-deployment'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    clientAddressPoolAddressPrefix: clientAddressPoolAddressPrefix
    vpnGatewayServicePrincipalClientId: vpnGatewayServicePrincipalClientId
    customRoutesAddressPrefixes: customRoutesAddressPrefixes
    gatewaySubnetId: virtualNetworkDeployment.outputs.gatewaySubnetResourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
  }
}

// Removing AMPLS module as it is not used in the current setup
// module azureMonitorPrivateLinkScope './modules/azure-monitor-private-link-scope.bicep' = {
//   name: 'azure-monitor-private-link-scope'
//   scope: resourceGroup
//   params: {
//     name: 'ampls-central-${location}-${resourceToken}'
//   }
// }

module policiesDeployment './modules/policies.bicep' = {
  name: 'policies-deployment'
  params: {
    resourceGroupName: resourceGroup.name
    userAssignedIdentityName: managedIdentityDeployment.outputs.managedIdentityName
    location: location
    virtualNetworkName: virtualNetworkDeployment.outputs.virtualNetworkName
    privateZonesMappingData: privateZonesMappingData
  }
}

module storageAccountDeployment './modules/storage-account.bicep' = {
  name: 'storage-account-deployment'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    privateEndpointSubnetResourceId: virtualNetworkDeployment.outputs.privateEndpointSubnetResourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
  }
}

module readerRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'managed-identity-reader-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  }
}

module containerAppsOperatorRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'container-apps-operator-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'f3bd1b5c-91fa-40e7-afe7-0c11d331232c' // Container Apps Operator
  }
}

module aksRbacClusterAdminRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'aks-rbac-cluster-admin-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b' // AKS RBAC Cluster Admin
  }
}

module webPlanContributorAdminRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'web-plan-contributor-admin-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: '2cc479cb-7b4d-49a8-b449-8c00fd0f0a4b' // Web Plan Contributor Admin
  }
}

module logicAppDeployment './modules/logic-app.bicep' = {
  name: 'logic-app-deployment'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    managedIdentityId: managedIdentityDeployment.outputs.managedIdentityResourceId
    timeZone: timeZone
    interval: interval
    frequency: frequency
    scheduleHours: scheduleHours
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
