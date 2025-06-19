param virtualNetworkName string
param virtualNetworkAddressSpace array
param location string = resourceGroup().location
param gatewaySubnetName string
param gatewaySubnetAddressPrefix string
param containerInstanceSubnetName string
param containerInstanceSubnetAddressPrefix string
param containerInstanceSubnetNsgName string
param privateEndpointSubnetName string
param privateEndpointSubnetAddressPrefix string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: virtualNetworkName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: virtualNetworkAddressSpace
    }
  }
}

resource gatewaySubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: gatewaySubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: gatewaySubnetAddressPrefix
    delegations: []
  }
}

resource containerInstanceSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: containerInstanceSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: containerInstanceSubnetAddressPrefix
    networkSecurityGroup: {
      id: containerInstanceSubnetNsg.id
    }
    delegations: [
      {
        name: 'containerGroups'
        properties: {
          serviceName: 'Microsoft.ContainerInstance/containerGroups'
        }
      }
    ]
  }
}

resource containerInstanceSubnetNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: containerInstanceSubnetNsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAllInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAllOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource privateEndpointSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: privateEndpointSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: privateEndpointSubnetAddressPrefix
    delegations: []
  }
}

resource privateEndpointSubnetNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${privateEndpointSubnetName}-nsg'
  location: location
  properties: {
    securityRules: [
      {
        name: 'AllowAllInbound'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
      {
        name: 'AllowAllOutbound'
        properties: {
          priority: 100
          direction: 'Outbound'
          access: 'Allow'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: '*'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

output virtualNetworkName string = virtualNetwork.name
output gatewaySubnetName string = gatewaySubnet.name
output gatewaySubnetId string = gatewaySubnet.id
output containerInstanceSubnetId string = containerInstanceSubnet.id
output privateEndpointSubnetId string = privateEndpointSubnet.id
