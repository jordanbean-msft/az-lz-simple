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
@description('Schedule for stopping compute resources')
param stopCompute object

@description('Schedule for starting central VMs')
param startCentralVMs object
param githubRepoUrl string
@secure()
param githubPat string
@secure()
param adminUsername string
@secure()
param adminPassword string
@description('SSH public key for the GitHub Actions runner VM')
param githubActionsAdminPublicKey string = ''

@description('Configuration for the DNS resolver VM')
param dnsResolverVm object = {
  diskSizeGB: 30
  publisher: 'Canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
  vmSize: 'Standard_B2ts_v2'
  privateIPAddress: '10.255.1.4'
}

@description('Configuration for the GitHub Actions runner VM')
param githubActionsRunnerVm object = {
  publisher: 'canonical'
  offer: 'ubuntu-24_04-lts'
  sku: 'server'
  version: 'latest'
  vmSize: 'Standard_D8ds_v4'
  diskSizeGB: 1024
  privateIPAddress: '10.255.1.5'
  vmName: ''
  nicName: ''
  ipConfigurationName: 'ipconfig01'
  // Optional: override adminUsername per-VM to match an existing deployed VM.
  // Leave empty to inherit the shared adminUsername parameter.
  adminUsername: ''
}

var dnsResolverCloudInitTemplate = loadTextContent('cloud-init/dns-resolver.txt')
var githubActionsRunnerCloudInitTemplate = loadTextContent('cloud-init/github-actions-runner.txt')

//replace the string "<YOUR_GITHUB_REPO_URL>" with the actual GitHub repo URL
var githubActionsRunnerCloudInit = replace(
  replace(githubActionsRunnerCloudInitTemplate, '<YOUR_GITHUB_REPO_URL>', githubRepoUrl),
  '<YOUR_GITHUB_PAT>',
  githubPat
)

var dnsResolverCloudInit = dnsResolverCloudInitTemplate

@description('Id of the user or app to assign application roles')
var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
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
    diskSizeGB: dnsResolverVm.diskSizeGB
    osType: 'Linux'
    sku: dnsResolverVm.sku
    publisher: dnsResolverVm.publisher
    offer: dnsResolverVm.offer
    version: dnsResolverVm.version
    vmSize: dnsResolverVm.vmSize
    privateIPAddress: dnsResolverVm.privateIPAddress
  }
}

module githubActionsRunnerDeployment './modules/github-actions-runner-vm.bicep' = {
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
    adminUsername: empty(githubActionsRunnerVm.?adminUsername ?? '') ? adminUsername : githubActionsRunnerVm.adminUsername
    adminPublicKey: githubActionsAdminPublicKey
    customData: githubActionsRunnerCloudInit
    publisher: githubActionsRunnerVm.publisher
    offer: githubActionsRunnerVm.offer
    sku: githubActionsRunnerVm.sku
    version: githubActionsRunnerVm.version
    vmSize: githubActionsRunnerVm.vmSize
    diskSizeGB: githubActionsRunnerVm.diskSizeGB
    privateIPAddress: githubActionsRunnerVm.privateIPAddress
    vmName: githubActionsRunnerVm.vmName
    nicName: githubActionsRunnerVm.nicName
    ipConfigurationName: githubActionsRunnerVm.ipConfigurationName
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
  }
}

module readerRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'managed-identity-reader-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader
  }
}

module aksRbacClusterAdminRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'aks-rbac-cluster-admin-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'b1ff04bb-8a4e-4dc4-8eb5-8693973ce19b' // AKS RBAC Cluster Admin
  }
}

module privateDnsZoneContributorRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'private-dns-zone-contributor-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: 'befefa01-2a29-4197-83a8-272ff33ce314' // Private DNS Zone Contributor
  }
}

module webPlanContributorAdminRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'web-plan-contributor-admin-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: '2cc479cb-7b4d-49a8-b449-8c00fd0f0a4b' // Web Plan Contributor Admin
  }
}

module vmContributorRoleAssignmentDeployment './modules/subscription-role-assignment.bicep' = {
  name: 'vm-contributor-role-assignment-deployment'
  params: {
    principalId: managedIdentityDeployment.outputs.managedIdentityPrincipalId
    roleDefinitionId: '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'
  }
}

// Example usage of stopCompute and startCentralVMs object parameters:
// You will need to update the logic app module(s) to use these objects as needed.

module stopComputeLogicApp './modules/logic-app-stop-compute.bicep' = {
  name: 'logic-app-stop-compute'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    managedIdentityId: managedIdentityDeployment.outputs.managedIdentityResourceId
    timeZone: stopCompute.timeZone
    interval: stopCompute.interval
    frequency: stopCompute.frequency
    scheduleHours: stopCompute.scheduleHours
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
  }
}

module startCentralVMsLogicApp './modules/logic-app-start-central-vms.bicep' = {
  name: 'logic-app-start-central-vms'
  scope: resourceGroup
  params: {
    resourceToken: resourceToken
    abbrs: abbrs
    location: location
    managedIdentityId: managedIdentityDeployment.outputs.managedIdentityResourceId
    timeZone: startCentralVMs.timeZone
    interval: startCentralVMs.interval
    frequency: startCentralVMs.frequency
    scheduleHours: startCentralVMs.scheduleHours
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceDeployment.outputs.logAnalyticsWorkspaceId
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
