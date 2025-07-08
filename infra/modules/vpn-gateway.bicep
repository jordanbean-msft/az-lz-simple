param clientAddressPoolAddressPrefix string
param vpnGatewayServicePrincipalClientId string
param customRoutesAddressPrefixes array
param resourceToken string
param abbrs object
param location string
param gatewaySubnetId string

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${abbrs.networkPublicIPAddresses}central-${location}-${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource vpnGateway 'Microsoft.Network/virtualNetworkGateways@2024-01-01' = {
  name: '${abbrs.networkVpnGateways}central-${location}-${resourceToken}'
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
        addressPrefixes: [clientAddressPoolAddressPrefix]
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
