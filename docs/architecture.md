# Architecture

This landing zone uses a hub-and-spoke network with centralized VPN access, DNS resolution, private endpoints, and a Network Security Perimeter (NSP) for the Terraform-state storage account.

```mermaid
flowchart LR
    internet((Approved public IPs\n/32)) -->|HTTPS, NSP inbound rule| nsp[Network Security Perimeter\nEnforced]
    vpn[User workstation\nPoint-to-Site VPN] --> vpnGw[VPN Gateway\nEntra ID auth]
    vpnGw --> hub

    subgraph hub[Central resource group / hub VNet]
        dns[DNS resolver VM\nCoreDNS]
        runner[GitHub Actions\nrunner VM]
        pe[Private Endpoint subnet]
        storage[(Terraform-state\nStorage Account)]
        nsp -->|SecuredByPerimeter association| storage
        storage --- pe
        dns --> zones[Private DNS zones\nAzure Policy managed]
    end

    hub <-->|VNet peering\nGateway transit| spoke[Spoke VNet(s)]
    pe -.->|Private Link| storage
```

## Network Security Perimeter

The NSP is deployed in the central resource group with a `default` profile and an inbound access rule. The rule receives a comma-separated list from the `AZURE_ALLOWED_INBOUND_IP_ADDRESSES` azd environment variable; each entry must be an IPv4 `/32`, such as `203.0.113.10/32`.

The storage account is configured with:

- `publicNetworkAccess: SecuredByPerimeter`
- A resource association with `accessMode: Enforced`
- A private endpoint in the hub VNet

In Enforced mode, public traffic must match an NSP rule. The storage account's own firewall settings and trusted-service bypass do not supersede the NSP. Private endpoint traffic bypasses NSP public access rules.

## Traffic paths

| Source | Destination | Expected control |
|---|---|---|
| Approved public IP | Storage public endpoint | NSP inbound `/32` rule, then storage authorization |
| Non-approved public IP | Storage public endpoint | Denied by NSP |
| Hub/spoke resource | Storage private endpoint | Private Link; not evaluated by public NSP rules |
| VPN client | Hub/spoke private resources | VPN gateway, peering, NSG, DNS, and private endpoint controls |

## Deployment parameters

`infra/main.parameters.json` maps these azd variables into the subscription-scoped Bicep deployment:

```shell
azd env set AZURE_ALLOWED_INBOUND_IP_ADDRESSES "203.0.113.10/32,198.51.100.25/32"
azd env set AZURE_NSP_ACCESS_MODE "Enforced"
azd provision
```

The IP list is intentionally kept in the azd environment rather than source control.
