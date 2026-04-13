#!/usr/bin/env python3
import argparse
import ipaddress
import json
import sys


def build_parser():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument('--used-spaces', default='')
    parser.add_argument('--prefix', type=int, required=True)
    parser.add_argument('--json', action='store_true', dest='json_output')
    return parser


def main():
    args = build_parser().parse_args()

    used = []
    for cidr in args.used_spaces.strip().splitlines():
        cidr = cidr.strip()
        if not cidr:
            continue
        try:
            used.append(ipaddress.ip_network(cidr, strict=False))
        except ValueError:
            continue

    search_space = ipaddress.ip_network('10.0.0.0/8')
    suggestions = []

    for candidate in search_space.subnets(new_prefix=args.prefix):
        if any(candidate.overlaps(existing) for existing in used):
            continue
        suggestions.append(str(candidate))
        if len(suggestions) >= 5:
            break

    if args.json_output:
        print(json.dumps({
            'usedAddressSpaces': [str(network) for network in used],
            'suggestions': suggestions,
            'prefixLength': args.prefix,
        }, indent=2))
    else:
        print(f'── Suggested available /{args.prefix} blocks ──')
        print()
        for index, suggestion in enumerate(suggestions, 1):
            print(f'  {index}. {suggestion}')
        print()
        if not suggestions:
            print(f'  No available /{args.prefix} blocks found in 10.0.0.0/8!')

    return 0


if __name__ == '__main__':
    sys.exit(main())