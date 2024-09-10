param virtualNetworkName string
param virtualNetworkAddressSpace array
param location string = resourceGroup().location
param gatewaySubnetName string
param gatewaySubnetAddressPrefix string
param dnsPrivateResolverInboundSubnetName string
param dnsPrivateResolverInboundSubnetAddressPrefix string
param dnsPrivateResolverInboundSubnetNsgName string
param dnsPrivateResolverOutboundSubnetName string
param dnsPrivateResolverOutboundSubnetAddressPrefix string
param dnsPrivateResolverOutboundSubnetNsgName string

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
    delegations:[
    ]
  }
}

resource dnsPrivateResolverInboundSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: dnsPrivateResolverInboundSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: dnsPrivateResolverInboundSubnetAddressPrefix
    networkSecurityGroup: {
      id: dnsPrivateResolverInboundSubnetNsg.id
    }
    delegations:[
      {
        name: 'Microsoft.Network.dnsResolvers'
        properties: {
          serviceName: 'Microsoft.Network/dnsResolvers'
        }
      }
    ]
  }
}

resource dnsPrivateResolverOutboundSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' = {
  name: dnsPrivateResolverOutboundSubnetName
  parent: virtualNetwork
  properties: {
    addressPrefix: dnsPrivateResolverOutboundSubnetAddressPrefix
    networkSecurityGroup: {
      id: dnsPrivateResolverOutboundSubnetNsg.id
    }
    delegations:[
      {
        name: 'Microsoft.Network/dnsResolvers'
        properties: {
          serviceName: 'Microsoft.Network/dnsResolvers'
        }
      }
    ]
  }
}

resource dnsPrivateResolverInboundSubnetNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: dnsPrivateResolverInboundSubnetNsgName
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

resource dnsPrivateResolverOutboundSubnetNsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: dnsPrivateResolverOutboundSubnetNsgName
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
output dnsPrivateResolverInboundSubnetId string = dnsPrivateResolverInboundSubnet.id
output dnsPrivateResolverOutboundSubnetId string = dnsPrivateResolverOutboundSubnet.id
