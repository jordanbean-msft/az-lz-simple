param clientAddressPoolAddressPrefix string
param vpnGatewayServicePrincipalClientId string
param customRoutesAddressPrefixes array
param resourceToken string
param abbrs object
param location string
param gatewaySubnetId string
param logAnalyticsWorkspaceId string

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-01-01' = {
  name: '${abbrs.networkPublicIPAddresses}central-${location}-${resourceToken}'
  location: location
  sku: {
    name: 'Standard'
  }
  // AZ VPN gateway SKUs require a zone-redundant (Standard) Public IP with explicit zones.
  zones: ['1', '2', '3']
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
      // AZ SKU is required by Azure — non-AZ SKUs (VpnGw1-5) are no longer supported for new/updated gateways.
      name: 'VpnGw1AZ'
      tier: 'VpnGw1AZ'
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

resource vpnGatewayLogging 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'logging'
  scope: vpnGateway
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output vpnGatewayName string = vpnGateway.name
