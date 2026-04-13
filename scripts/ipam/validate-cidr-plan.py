#!/usr/bin/env python3
import argparse
import ipaddress
import json
import sys
from pathlib import Path
from typing import Dict


def parse_mapping(raw_value: str, label: str):
    mapping: Dict[str, str] = {}
    if not raw_value:
        return mapping, []
    errors = []
    for item in raw_value.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" not in item:
            errors.append(
                f"Invalid {label} entry '{item}'. Expected <name>:<value> format."
            )
            continue
        key, value = item.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not key or not value:
            errors.append(
                f"Invalid {label} entry '{item}'. Expected non-empty name and value."
            )
            continue
        mapping[key] = value
    return mapping, errors


def build_parser():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--address-space", required=True)
    parser.add_argument("--subnets", default="")
    parser.add_argument("--delegations", default="")
    parser.add_argument("--profiles", default="")
    parser.add_argument("--config-file", required=True)
    parser.add_argument("--live-vnets-json", default="[]")
    parser.add_argument("--json", action="store_true", dest="json_output")
    return parser


def main():
    args = build_parser().parse_args()

    address_space = args.address_space
    subnets_raw = args.subnets
    delegations_raw = args.delegations
    profiles_raw = args.profiles
    config_file = Path(args.config_file)
    live_vnets_json = args.live_vnets_json
    json_output = args.json_output

    errors = []
    warnings = []

    try:
        proposed_vnet = ipaddress.ip_network(address_space, strict=True)
    except ValueError as exc:
        errors.append(f"Invalid VNet CIDR '{address_space}': {exc}")
        proposed_vnet = None

    subnet_map, subnet_parse_errors = parse_mapping(subnets_raw, "subnet")
    errors.extend(subnet_parse_errors)

    delegation_map, delegation_parse_errors = parse_mapping(
        delegations_raw, "delegation"
    )
    errors.extend(delegation_parse_errors)

    profile_map, profile_parse_errors = parse_mapping(profiles_raw, "profile")
    errors.extend(profile_parse_errors)

    subnets = {}
    for subnet_name, subnet_cidr in subnet_map.items():
        try:
            network = ipaddress.ip_network(subnet_cidr, strict=True)
            subnets[subnet_name] = network
        except ValueError as exc:
            errors.append(
                f"Invalid subnet CIDR for '{subnet_name}' ('{subnet_cidr}'): {exc}"
            )

    for subnet_name, delegation_service in delegation_map.items():
        if subnet_name not in subnet_map:
            errors.append(
                f"Delegation specified for unknown subnet '{subnet_name}' ({delegation_service})."
            )

    for subnet_name, profile_name in profile_map.items():
        if subnet_name not in subnet_map:
            errors.append(
                f"Profile '{profile_name}' specified for unknown subnet '{subnet_name}'."
            )

    if proposed_vnet is not None:
        if proposed_vnet.prefixlen < 8 or proposed_vnet.prefixlen > 29:
            errors.append(
                f"VNet prefix '/{proposed_vnet.prefixlen}' is outside the supported planning range."
            )

        for subnet_name, subnet_network in subnets.items():
            if subnet_network.prefixlen > 29:
                errors.append(
                    f"Subnet '{subnet_name}' uses {subnet_network} which is smaller than Azure minimum /29."
                )
            if not subnet_network.subnet_of(proposed_vnet):
                errors.append(
                    f"Subnet '{subnet_name}' ({subnet_network}) is not fully contained within VNet {proposed_vnet}."
                )

        subnet_items = list(subnets.items())
        for idx, (left_name, left_network) in enumerate(subnet_items):
            for right_name, right_network in subnet_items[idx + 1 :]:
                if left_network.overlaps(right_network):
                    errors.append(
                        f"Subnets '{left_name}' ({left_network}) and '{right_name}' ({right_network}) overlap."
                    )

    profile_rules = {
        "compute": {"max_prefix": 29},
        "private-endpoint": {"max_prefix": 27},
        "app-service": {
            "max_prefix": 27,
            "delegation": "Microsoft.Web/serverFarms",
        },
        "functions": {
            "max_prefix": 27,
            "delegation": "Microsoft.Web/serverFarms",
        },
        "foundry-agent-service": {
            "max_prefix": 26,
            "delegation": "Microsoft.App/environments",
        },
        "container-apps": {
            "max_prefix": 23,
            "delegation": "Microsoft.App/environments",
        },
        "ml-compute": {
            "max_prefix": 27,
            "delegation": "Microsoft.MachineLearningServices/workspaces",
        },
        "aks-api": {
            "max_prefix": 28,
            "delegation": "Microsoft.ContainerService/managedClusters",
        },
        "sql-mi": {
            "max_prefix": 27,
            "delegation": "Microsoft.Sql/managedInstances",
        },
        "app-gateway": {"max_prefix": 26},
        "bastion": {"max_prefix": 26, "required_name": "AzureBastionSubnet"},
        "firewall": {"max_prefix": 26, "required_name": "AzureFirewallSubnet"},
        "firewall-management": {
            "max_prefix": 26,
            "required_name": "AzureFirewallManagementSubnet",
        },
        "route-server": {"max_prefix": 27, "required_name": "RouteServerSubnet"},
    }

    exact_name_rules = {
        "AzureBastionSubnet": {"max_prefix": 26},
        "AzureFirewallSubnet": {"max_prefix": 26},
        "AzureFirewallManagementSubnet": {"max_prefix": 26},
        "RouteServerSubnet": {"max_prefix": 27},
        "GatewaySubnet": {"max_prefix": 27},
    }

    delegation_min_prefix = {
        "Microsoft.Web/serverFarms": 27,
        "Microsoft.ContainerService/managedClusters": 28,
        "Microsoft.MachineLearningServices/workspaces": 27,
        "Microsoft.Sql/managedInstances": 27,
    }

    for subnet_name, subnet_network in subnets.items():
        if subnet_name in exact_name_rules:
            max_prefix = exact_name_rules[subnet_name]["max_prefix"]
            if subnet_network.prefixlen > max_prefix:
                errors.append(
                    f"Subnet '{subnet_name}' must be at least /{max_prefix}, got {subnet_network}."
                )

    for subnet_name, profile_name in profile_map.items():
        profile_rule = profile_rules.get(profile_name)
        if profile_rule is None:
            errors.append(
                f"Unsupported profile '{profile_name}' for subnet '{subnet_name}'."
            )
            continue
        subnet_network = subnets.get(subnet_name)
        if subnet_network is None:
            continue
        max_prefix = profile_rule.get("max_prefix")
        if max_prefix is not None and subnet_network.prefixlen > max_prefix:
            errors.append(
                f"Subnet '{subnet_name}' with profile '{profile_name}' must be at least /{max_prefix}, got {subnet_network}."
            )
        required_name = profile_rule.get("required_name")
        if required_name is not None and subnet_name != required_name:
            errors.append(
                f"Profile '{profile_name}' requires subnet name '{required_name}', got '{subnet_name}'."
            )
        required_delegation = profile_rule.get("delegation")
        if required_delegation is not None:
            actual_delegation = delegation_map.get(subnet_name)
            if actual_delegation != required_delegation:
                errors.append(
                    f"Profile '{profile_name}' on subnet '{subnet_name}' requires delegation '{required_delegation}', got '{actual_delegation or 'none'}'."
                )

    for subnet_name, delegation_service in delegation_map.items():
        subnet_network = subnets.get(subnet_name)
        if subnet_network is None:
            continue
        if subnet_name == "private-endpoint":
            errors.append("Subnet 'private-endpoint' must not be delegated.")
        max_prefix = delegation_min_prefix.get(delegation_service)
        if max_prefix is not None and subnet_network.prefixlen > max_prefix:
            errors.append(
                f"Delegated subnet '{subnet_name}' with service '{delegation_service}' must be at least /{max_prefix}, got {subnet_network}."
            )
        if (
            delegation_service == "Microsoft.App/environments"
            and subnet_name not in profile_map
        ):
            warnings.append(
                f"Subnet '{subnet_name}' uses Microsoft.App/environments. Provide a profile of 'container-apps' or 'foundry-agent-service' for stricter validation."
            )

    with config_file.open("r", encoding="utf-8") as fh:
        config = json.load(fh)

    existing_ranges = []
    hub_space = config.get("hub", {}).get("addressSpace")
    if hub_space:
        try:
            existing_ranges.append(
                (
                    f"hub:{config.get('hub', {}).get('vnetName', 'hub')}",
                    ipaddress.ip_network(hub_space, strict=False),
                )
            )
        except ValueError:
            warnings.append(
                f"Ignoring invalid hub address space in config: {hub_space}"
            )

    for pool in (
        config.get("hub", {}).get("vpnGateway", {}).get("p2sAddressPool", []) or []
    ):
        try:
            existing_ranges.append(
                (f"vpn-pool:{pool}", ipaddress.ip_network(pool, strict=False))
            )
        except ValueError:
            warnings.append(f"Ignoring invalid VPN pool in config: {pool}")

    for spoke in config.get("spokes", []) or []:
        address = spoke.get("addressSpace")
        if not address:
            continue
        try:
            existing_ranges.append(
                (
                    f"config-spoke:{spoke.get('vnetName', spoke.get('name', 'unknown'))}",
                    ipaddress.ip_network(address, strict=False),
                )
            )
        except ValueError:
            warnings.append(
                f"Ignoring invalid spoke address space in config: {address}"
            )

    try:
        live_vnets = json.loads(live_vnets_json)
    except json.JSONDecodeError:
        live_vnets = []
        warnings.append("Ignoring invalid live VNet JSON returned by Azure CLI.")

    for vnet in live_vnets:
        vnet_name = vnet.get("name", "unknown-vnet")
        for prefix in vnet.get("addressSpace", []) or []:
            try:
                existing_ranges.append(
                    (
                        f"live-vnet:{vnet_name}",
                        ipaddress.ip_network(prefix, strict=False),
                    )
                )
            except ValueError:
                warnings.append(
                    f"Ignoring invalid live VNet address space for {vnet_name}: {prefix}"
                )

    seen = set()
    deduped_ranges = []
    for label, network in existing_ranges:
        key = (label, str(network))
        if key not in seen:
            seen.add(key)
            deduped_ranges.append((label, network))

    if proposed_vnet is not None:
        for label, existing_network in deduped_ranges:
            if proposed_vnet.overlaps(existing_network):
                errors.append(
                    f"Proposed VNet {proposed_vnet} overlaps existing range {existing_network} ({label})."
                )

    result = {
        "valid": not errors,
        "vnet": str(proposed_vnet) if proposed_vnet is not None else None,
        "subnets": {name: str(network) for name, network in subnets.items()},
        "errors": errors,
        "warnings": warnings,
        "checkedExistingRanges": [
            {"label": label, "cidr": str(network)} for label, network in deduped_ranges
        ],
    }

    if json_output:
        print(json.dumps(result, indent=2))
    else:
        print()
        print("═══════════════════════════════════════════════════════")
        print("  CIDR Plan Validation")
        print("═══════════════════════════════════════════════════════")
        print()
        print(f"  Proposed VNet: {result['vnet'] or address_space}")
        if subnets:
            print("  Proposed subnets:")
            for subnet_name, subnet_network in subnets.items():
                print(f"    - {subnet_name}: {subnet_network}")
            print()
        if errors:
            print("  ❌ Validation failed")
            print()
            for error in errors:
                print(f"  - {error}")
            if warnings:
                print()
                print("  Warnings:")
                for warning in warnings:
                    print(f"  - {warning}")
        else:
            print("  ✅ Validation passed")
            if warnings:
                print()
                print("  Warnings:")
                for warning in warnings:
                    print(f"  - {warning}")

    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
