param publicIpName string
param vpnGatewayName string
param location string
param gatewaySubnetId string
param clientAddressPoolAddressPrefixes array
param vpnGatewayServicePrincipalClientId string
param customRoutesAddressPrefixes array

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: publicIpName
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'    
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: vpnGatewayName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'default'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: gatewaySubnetId
        }
      }
    }
    ]
    sku: {
      name: 'VpnGw1'
      tier: 'VpnGw1'
    }
    gatewayType: 'Vpn'
    enableBgp: true
    vpnClientConfiguration: {
      vpnClientProtocols: [
        'OpenVPN'
      ]
      vpnClientAddressPool: {
        addressPrefixes: clientAddressPoolAddressPrefixes        
      }
      vpnAuthenticationTypes: [
        'AAD'
      ]
      aadTenant: '${environment().authentication.loginEndpoint}${subscription().tenantId}/'
      aadIssuer: 'https://sts.windows.net/${subscription().tenantId}/'
      aadAudience: vpnGatewayServicePrincipalClientId
    }
    vpnGatewayGeneration: 'Generation1'
    customRoutes: {
      addressPrefixes: customRoutesAddressPrefixes
    }
    bgpSettings: {
      asn: 65515
      peerWeight: 0
      bgpPeeringAddresses: []
    }
    allowRemoteVnetTraffic: false
    allowVirtualWanTraffic: false
    vpnType: 'RouteBased'
    enableBgpRouteTranslationForNat: false
    disableIPSecReplayProtection: false
    natRules: []
    enablePrivateIpAddress: false
  }
}

output vpnGatewayName string = vpnGateway.name
