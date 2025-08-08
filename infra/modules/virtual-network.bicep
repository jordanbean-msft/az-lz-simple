param virtualNetworkAddressSpace array
param location string
param gatewaySubnetAddressPrefix string
param gatewaySubnetName string
param vmSubnetName string
param vmSubnetAddressPrefix string
param privateEndpointSubnetName string
param privateEndpointSubnetAddressPrefix string
param resourceToken string
param abbrs object

module privateEndpointNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.1' = {
  name: 'private-endpoint-network-security-group'
  params: {
    name: '${abbrs.networkNetworkSecurityGroups}${resourceToken}-private-endpoint'
    location: location
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: 'Tcp'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetAddressPrefix
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

module vmNetworkSecurityGroup 'br/public:avm/res/network/network-security-group:0.5.1' = {
  name: 'vm-network-security-group'
  params: {
    name: '${abbrs.networkNetworkSecurityGroups}${resourceToken}-vm'
    location: location
    securityRules: [
      {
        name: 'AllowHttpsInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: vmSubnetAddressPrefix
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'AllowDnsInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: 'VirtualNetwork'
          sourcePortRange: '*'
          destinationAddressPrefix: vmSubnetAddressPrefix
          destinationPortRanges: ['53']
        }
      }
      {
        name: 'AllowAzurePortalAccessInbound'
        properties: {
          access: 'Allow'
          direction: 'Inbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: vmSubnetAddressPrefix
          destinationPortRange: '19390'
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          access: 'Deny'
          direction: 'Inbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
      {
        name: 'AllowHttpsOutboundToPrivateEndpoints'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 100
          protocol: '*'
          sourceAddressPrefix: vmSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: privateEndpointSubnetAddressPrefix
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'AllowHttpsOutbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 110
          protocol: '*'
          sourceAddressPrefix: vmSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: 'Internet'
          destinationPortRanges: ['80', '443']
        }
      }
      {
        name: 'AllowDnsOutbound'
        properties: {
          access: 'Allow'
          direction: 'Outbound'
          priority: 120
          protocol: '*'
          sourceAddressPrefix: vmSubnetAddressPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['53']
        }
      }
      {
        name: 'DenyAllOutbound'
        properties: {
          access: 'Deny'
          direction: 'Outbound'
          priority: 4096
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

module virtualNetwork 'br/public:avm/res/network/virtual-network:0.6.1' = {
  name: 'virtual-network'
  params: {
    addressPrefixes: virtualNetworkAddressSpace
    name: '${abbrs.networkVirtualNetworks}central-${location}-${resourceToken}'
    location: location
    subnets: [
      {
        name: gatewaySubnetName
        addressPrefix: gatewaySubnetAddressPrefix
      }
      {
        name: vmSubnetName
        addressPrefix: vmSubnetAddressPrefix
        networkSecurityGroupResourceId: vmNetworkSecurityGroup.outputs.resourceId
      }
      {
        name: privateEndpointSubnetName
        addressPrefix: privateEndpointSubnetAddressPrefix
        networkSecurityGroupResourceId: privateEndpointNetworkSecurityGroup.outputs.resourceId
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.outputs.name
output gatewaySubnetName string = gatewaySubnetName
output gatewaySubnetResourceId string = '${virtualNetwork.outputs.resourceId}/subnets/${gatewaySubnetName}'
output vmSubnetName string = vmSubnetName
output vmSubnetResourceId string = '${virtualNetwork.outputs.resourceId}/subnets/${vmSubnetName}'
output privateEndpointSubnetName string = privateEndpointSubnetName
output privateEndpointSubnetResourceId string = '${virtualNetwork.outputs.resourceId}/subnets/${privateEndpointSubnetName}'
