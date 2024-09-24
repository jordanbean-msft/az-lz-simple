targetScope = 'subscription'

@minLength(1)
@maxLength(64)
@description('Name of the the environment which is used to generate a short unique hash used in all resources.')
param environmentName string

@minLength(1)
@description('Primary location for all resources')
param location string

param resourceGroupName string = ''

param virtualNetworkAddressSpace array
param gatewaySubnetName string
param gatewaySubnetAddressPrefix string
param dnsPrivateResolverInboundSubnetName string
param dnsPrivateResolverInboundSubnetAddressPrefix string
param dnsPrivateResolverOutboundSubnetName string
param dnsPrivateResolverOutboundSubnetAddressPrefix string
param clientAddressPoolAddressPrefixes array
param vpnGatewayServicePrincipalClientId string
param customRoutesAddressPrefixes array
@allowed(['commercial', 'government'])
param privateZonesMappingDataFileType string

@description('Id of the user or app to assign application roles')

var abbrs = loadJsonContent('./abbreviations.json')
var resourceToken = toLower(uniqueString(subscription().id, environmentName, location))
var tags = { 'azd-env-name': environmentName }
var privateZonesMappingData = (privateZonesMappingDataFileType == 'commercial') ? loadJsonContent('./commercial.private-zones.json') : loadJsonContent('./government.private-zones.json')

resource resourceGroup 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: !empty(resourceGroupName) ? resourceGroupName : '${abbrs.resourcesResourceGroups}central-${location}-${resourceToken}'
  location: location
  tags: tags
}

module names 'resource-names.bicep' = {
  scope: az.resourceGroup(resourceGroup.name)
  name: 'resource-names'
  params: {
    resourceToken: resourceToken
  }
}

module virtualNetwork './modules/virtual-network.bicep' = {
  name: 'virtual-network'
  scope: resourceGroup
  params: {
    virtualNetworkName: '${abbrs.networkVirtualNetworks}central-${location}-${resourceToken}'
    location: location
    virtualNetworkAddressSpace: virtualNetworkAddressSpace
    gatewaySubnetName: gatewaySubnetName
    gatewaySubnetAddressPrefix: gatewaySubnetAddressPrefix
    dnsPrivateResolverInboundSubnetName: dnsPrivateResolverInboundSubnetName
    dnsPrivateResolverInboundSubnetAddressPrefix: dnsPrivateResolverInboundSubnetAddressPrefix
    dnsPrivateResolverInboundSubnetNsgName: '${abbrs.networkNetworkSecurityGroups}central-inbound-${location}-${resourceToken}'
    dnsPrivateResolverOutboundSubnetName: dnsPrivateResolverOutboundSubnetName
    dnsPrivateResolverOutboundSubnetAddressPrefix: dnsPrivateResolverOutboundSubnetAddressPrefix
    dnsPrivateResolverOutboundSubnetNsgName: '${abbrs.networkNetworkSecurityGroups}central-outbound-${location}-${resourceToken}'
  }
}

module dnsPrivateResolver './modules/dns-private-resolver.bicep' = {
  name: 'dns-private-resolver'
  scope: resourceGroup
  params: {
    dnsResolverName: 'dnsresolver-central-${location}-${resourceToken}'
    location: location
    virtualNetworkName: virtualNetwork.outputs.virtualNetworkName
    inboundSubnetName: dnsPrivateResolverInboundSubnetName
    outboundSubnetName: dnsPrivateResolverOutboundSubnetName
  }
}

module managedIdentity './modules/managed-identity.bicep' = {
  name: 'managed-identity'
  scope: resourceGroup
  params: {
    name: '${abbrs.managedIdentityUserAssignedIdentities}central-${location}-${resourceToken}'
    location: location
  }
}

module roleAssignment './modules/role-assignment.bicep' = {
  name: 'managed-identity-network-contributor-role-assignment'
  params: {
    principalId: managedIdentity.outputs.managedIdentityPrincipalId
    roleDefinitionId: '4d97b98b-1d4f-4787-a291-c67834d212e7' // Network Contributor
  }
}

module vpnGateway './modules/vpn-gateway.bicep' = {
  name: 'vpn-gateway'
  scope: resourceGroup
  params: {
    publicIpName: '${abbrs.networkPublicIPAddresses}central-${location}-${resourceToken}'
    vpnGatewayName: '${abbrs.networkVpnGateways}central-${location}-${resourceToken}'
    location: location
    gatewaySubnetId: virtualNetwork.outputs.gatewaySubnetId
    clientAddressPoolAddressPrefixes: clientAddressPoolAddressPrefixes
    vpnGatewayServicePrincipalClientId: vpnGatewayServicePrincipalClientId
    customRoutesAddressPrefixes: customRoutesAddressPrefixes
  }
}

module azureMonitorPrivateLinkScope './modules/azure-monitor-private-link-scope.bicep' = {
  name: 'azure-monitor-private-link-scope'
  scope: resourceGroup
  params: {
    name: 'ampls-central-${location}-${resourceToken}'
  }
}

module policies './modules/policies.bicep' = {
  name: 'policies'
  params: {
    resourceGroupName: resourceGroup.name
    userAssignedIdentityName: managedIdentity.outputs.managedIdentityName
    location: location
    virtualNetworkName: virtualNetwork.outputs.virtualNetworkName
    privateZonesMappingData: privateZonesMappingData
  }
}

output AZURE_LOCATION string = location
output AZURE_TENANT_ID string = tenant().tenantId
