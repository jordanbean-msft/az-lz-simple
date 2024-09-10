param dnsResolverName string
param location string
param virtualNetworkName string
param inboundSubnetName string
param outboundSubnetName string

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2023-11-01' existing = {
  name: virtualNetworkName
}

resource inboundSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: inboundSubnetName
  parent: virtualNetwork
}

resource outboundSubnet 'Microsoft.Network/virtualNetworks/subnets@2023-11-01' existing = {
  name: outboundSubnetName
  parent: virtualNetwork
}

resource resolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: dnsResolverName
  location: location
  properties: {
    virtualNetwork: {
      id: virtualNetwork.id
    }
  }
}

resource inEndpoint 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: resolver
  name: inboundSubnetName
  location: location
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Dynamic'
        subnet: {
          id: inboundSubnet.id
        }
      }
    ]
  }
}

resource outEndpoint 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: resolver
  name: outboundSubnetName
  location: location
  properties: {
    subnet: {
      id: outboundSubnet.id
    }
  }
}
