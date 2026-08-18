# GitHub Copilot Instructions for az-lz-simple

## Project Overview

This repository deploys a **hub-spoke Azure landing zone** using **Azure Bicep** and **Azure Developer CLI (azd)**. It provisions a hub virtual network with a VPN gateway, DNS resolver VM, GitHub Actions self-hosted runner VM, private DNS zones with Azure Policy auto-registration, a Network Security Perimeter protecting the Terraform-state storage account, and supporting infrastructure (Log Analytics, private endpoint, Logic Apps for compute scheduling).

## Repository Structure

```
infra/                          # All Bicep infrastructure-as-code
  main.bicep                    # Entry point (subscription-scoped deployment)
  main.parameters.json          # Parameters file (uses ${AZD_ENV_VAR} syntax)
  resource-names.bicep          # Centralized resource naming
  abbreviations.json            # Azure resource abbreviation prefixes (CAF)
  commercial.private-zones.json # Private DNS zone mappings for Azure commercial cloud
  government.private-zones.json # Private DNS zone mappings for Azure government cloud
  cloud-init/                   # Cloud-init scripts for VM provisioning
    dns-resolver.txt            # CoreDNS setup on Ubuntu VM
    github-actions-runner.txt   # GitHub Actions runner setup on Ubuntu VM
  modules/                      # Reusable Bicep modules
scripts/
  debug/                        # Network connectivity diagnostic scripts
  ipam/                         # Spoke VNet provisioning (IPAM) scripts
.github/
  copilot-instructions.md       # Copilot project-wide instructions
  agents/
    network-troubleshooter.agent.md  # Copilot agent for network debugging
.vscode/
  tasks.json                    # VS Code tasks for azd, Bicep, IPAM, debugging
azure.yaml                      # Azure Developer CLI configuration
.azure-debug-config.json        # Local Azure environment config (gitignored)
.azure-debug-config.example.json # Template for the above
```

## Bicep Conventions

### Naming

- Use the `abbreviations.json` file for all Azure resource name prefixes. Load it with `loadJsonContent('./abbreviations.json')`.
- Resource names follow the pattern: `{abbreviation}{resourceToken}` where `resourceToken` is a unique hash derived from `toLower(uniqueString(subscription().id, environmentName, location))`.
- Use the `abbrs` variable (loaded from `abbreviations.json`) to look up the correct prefix for each resource type.

### Azure Verified Modules (AVM)

- Prefer [Azure Verified Modules](https://aka.ms/avm) from the Bicep public registry (`br/public:avm/...`) when available.
- Examples already used in this repo:
  - `br/public:avm/res/compute/virtual-machine`
  - `br/public:avm/res/operational-insights/workspace`
  - `br/public:avm/res/managed-identity/user-assigned-identity`
  - `br/public:avm/res/network/virtual-network`
  - `br/public:avm/res/network/network-security-group`

### Module Structure

- Each module file in `infra/modules/` deploys a single logical resource or tightly related set of resources.
- Modules accept `resourceToken`, `abbrs`, and `location` as standard parameters.
- The main deployment is **subscription-scoped** (`targetScope = 'subscription'`) and references an existing resource group.
- Use `@description()` decorators on all parameters.
- Use `@secure()` for sensitive parameters (passwords, tokens, keys).

### Diagnostics & Monitoring

- All major resources should send diagnostic logs to the Log Analytics workspace.
- Use `diagnosticSettings` configuration blocks pointing to the shared `logAnalyticsWorkspaceId`.

### Security

- VMs use `TrustedLaunch` security profile with Secure Boot and vTPM enabled.
- The Terraform-state storage account uses `publicNetworkAccess: 'SecuredByPerimeter'`, an enforced Network Security Perimeter association, and a private endpoint.
- NSP inbound access rules are sourced from the `AZURE_ALLOWED_INBOUND_IP_ADDRESSES` azd environment variable as comma-separated `/32` CIDRs; do not check these IPs into source control.
- NSP association mode defaults to `Enforced`; `Learning` is only a temporary transition mode.
- VPN Gateway uses Microsoft Entra ID (AAD) authentication.

### Private DNS

- Private DNS zones are managed via Azure Policy (defined in `modules/policies.bicep`).
- Zone mappings come from `commercial.private-zones.json` or `government.private-zones.json` depending on the `privateZonesMappingDataFileType` parameter.
- Policy auto-creates DNS zones and links them to the hub VNet when private endpoints are created.

## Cloud-Init Scripts

- Cloud-init scripts in `infra/cloud-init/` use `#cloud-config` YAML format.
- They are loaded into Bicep via `loadTextContent()` and passed to VMs as `customData`.
- Template placeholders like `<YOUR_GITHUB_REPO_URL>` are replaced at deployment time using Bicep's `replace()` function.

## Azure Developer CLI (azd)

- The `azure.yaml` file defines the azd project.
- Infrastructure is in the `infra/` directory using the Bicep provider.
- Parameters that use `${AZURE_*}` syntax in `main.parameters.json` are populated from azd environment variables set via `azd env set`.
- Deploy with `azd up` (provisions infrastructure).

## Role Assignments

- Role assignments are subscription-scoped (see `modules/subscription-role-assignment.bicep`).
- Always include a comment with the role name next to the `roleDefinitionId` GUID for readability.
- The managed identity is assigned roles for: Network Contributor, Reader, AKS RBAC Cluster Admin, Private DNS Zone Contributor, Web Plan Contributor Admin, VM Contributor.

## Compute Scheduling

- Logic Apps handle scheduled start/stop of compute resources.
- `logic-app-stop-compute.bicep` stops VMs, Container Apps, Function Apps, and AKS clusters.
- `logic-app-start-central-vms.bicep` starts VMs in the resource group.
- Schedules are configurable via `stopCompute` and `startCentralVMs` parameters.

## IPAM — Spoke VNet Provisioning

The repo includes a VS Code task-driven IPAM tool for creating spoke VNets. Scripts are in `scripts/ipam/`.

### Workflow

1. **Discover** available address space: `IPAM: Discover available address space` task (or `./scripts/ipam/discover-address-space.sh`)
2. **Preview** the provisioning: `IPAM: Provision spoke (dry run)` task
3. **Provision** the spoke: `IPAM: Provision new spoke VNet` task
4. **List** all spokes: `IPAM: List spoke VNets` task
5. **Remove** a spoke: `IPAM: Remove spoke VNet` task

### What `provision-spoke.sh` does

1. Creates the resource group (if `--create-rg`)
2. Creates the spoke VNet with the specified address space and subnets
3. Queries Azure for the hub DNS resolver VM's private IP and sets it as the spoke VNet's custom DNS
4. Creates the hub→spoke peering first (with `--allow-gateway-transit`)
5. Creates the spoke→hub peering (with `--use-remote-gateways` and `--allow-forwarded-traffic`)
6. Verifies both peerings are in `Connected` state
7. Appends the new spoke to `.azure-debug-config.json`

### Address space conventions

- Hub uses `10.255.0.0/16`
- Spokes should use other ranges within `10.0.0.0/8` (which is advertised by the VPN gateway as a custom route)
- The discovery script finds unused `/16` blocks automatically (configurable with `--prefix`)
- Spoke-to-spoke communication requires direct mesh peering (traffic is not force-tunneled through the hub)

### Spoke naming

- VNet names follow: `vnet-{spoke-name}-{location}`
- Peering names: hub→spoke = `spoke-{vnet-name}`, spoke→hub = `hub-{hub-vnet-name}`

## Connectivity Debugging

The repo includes diagnostic scripts in `scripts/debug/` for troubleshooting WSL2 → VPN → Azure connectivity. These are available as VS Code tasks (prefixed with "Debug:") and as Copilot agentic tools.

### Local configuration

All debug and IPAM scripts read from `.azure-debug-config.json` (gitignored). Users must copy `.azure-debug-config.example.json` and fill in their values. The file tracks:

- Hub VNet, address space, subnets, resource group, DNS server VM details
- VPN gateway name, SKU, P2S address pool
- GitHub Actions runner VM name and resource ID
- Private DNS zone list
- Spoke VNets with address spaces (populated automatically by `provision-spoke.sh`)
- Local environment info (Windows VPN adapter name)

Sync runs automatically (>1 hour TTL) or manually via `./scripts/ipam/sync-config.sh`. It refreshes all cached fields from live Azure state.

### Diagnostic scripts

| Script                       | VS Code Task                          | What it checks                                                                                                                                    |
| ---------------------------- | ------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `trace-resource.sh`          | Debug: Trace resource networking      | Full chain from resource ID: PE → NIC/IP → VNet → peering → NSG → DNS → TCP. Use when you have a resource ID                                      |
| `diagnose-all.sh`            | Debug: Run all diagnostics            | Runs all checks in sequence. Use `--all` to scan all spoke RGs for PEs                                                                            |
| `check-vpn.sh`               | Debug: Check VPN connection           | VPN routes, hub reachability, gateway health, Windows VPN adapter                                                                                 |
| `check-dns.sh`               | Debug: Check DNS resolution           | DNS server reachability, resolution of hostnames, privatelink CNAME chain                                                                         |
| `check-dns-server.sh`        | Debug: Check DNS server VM            | VM power state, CoreDNS port 53, resolution test. Use `--restart` to start a stopped VM                                                           |
| `check-gha-runner.sh`        | Debug: Check GitHub Actions runner VM | VM power state, GitHub egress, runner repo target, and runner service health                                                                      |
| `check-peerings.sh`          | Debug: Check VNet peerings            | Hub peerings, spoke→hub reverse peerings, gateway transit settings                                                                                |
| `check-private-dns-zones.sh` | Debug: Check private DNS zones        | Zone existence, VNet links, A records, Azure Policy assignments                                                                                   |
| `check-private-endpoints.sh` | Debug: Check private endpoints        | PE connection status, DNS zone groups, NIC IPs, DNS cross-check. Use `--all` for all RGs, `--hostname` to find by FQDN                            |
| `check-dns-policy.sh`        | Debug: Check DNS DINE policy          | Verify DINE policies created DNS zone groups on PEs. Use `--remediate` to trigger Azure Policy remediation                                        |
| `check-nsg.sh`               | Debug: Check NSG rules                | NSG rules on hub/spoke subnets, effective rules per NIC, orphaned NSGs, unprotected subnets. Use `--all` for all RGs, `--nic` for effective rules |
| `manage-vm.sh`               | VM: DNS/GHA tasks                     | Start, stop, restart, or check status of DNS server and GHA runner VMs                                                                            |

### VM-specific troubleshooting steps

When the issue is clearly tied to one of the hub VMs, use these shorter playbooks before running every network script.

#### GitHub Actions runner VM

Use this sequence when a self-hosted workflow stays queued, the runner looks offline, or a workflow that needs private network access never starts:

1. Check power state: `./scripts/debug/manage-vm.sh status gha-runner`
2. Start the VM if needed: `./scripts/debug/manage-vm.sh start gha-runner`
3. Run `./scripts/debug/check-gha-runner.sh`
4. If GitHub is unreachable, verify the runner NIC still has its public IP attached or that subnet egress is provided by NAT.
5. If network is healthy, check whether the workflow labels match the default runner labels: `self-hosted`, `Linux`, `X64`.
6. **To change the repository the runner points to**, use: `./scripts/debug/update-gha-runner.sh https://github.com/owner/repo`

**Updating Runner Repository (Fully Automated)**

The new `update-gha-runner.sh` script automates the entire re-registration process:

```bash
# Simplest usage — auto-discovers VM, generates PAT, reconfigures runner
./scripts/debug/update-gha-runner.sh https://github.com/jordanbean-msft/my-repo

# Or use the VS Code task:
# Tasks → Run Task → VM: GHA Runner — Update to Repo
```

**What it does automatically:**
- ✅ Discovers runner VM name from `.azure-debug-config.json`
- ✅ Confirms runner path on VM (`/home/azureuser/actions-runner`)
- ✅ Ensures VM is running, starts if needed
- ✅ Uses `gh CLI` to obtain GitHub authentication token (if available)
- ✅ Stops old runner service and unregisters from old repo
- ✅ Requests new registration token from GitHub
- ✅ Configures runner for new repo
- ✅ Installs and starts systemd service
- ✅ Verifies runner is ONLINE in new repo
- ✅ Updates azd env var `AZURE_GITHUB_REPO_URL`

**Troubleshooting:**
- If `gh CLI` auth fails, the script will prompt for a PAT manually
- You can pre-set the PAT: `GITHUB_PAT=ghp_xxx ./scripts/debug/update-gha-runner.sh https://github.com/owner/repo`
- For detailed logging during reconfiguration, check: `./scripts/debug/update-gha-runner.sh --help`

**Legacy option** (manual steps, not recommended):
- Old script: `./scripts/debug/retarget-gha-runner.sh --repo-url https://github.com/owner/repo --pat YOUR_PAT`


#### DNS resolver VM

Use this sequence when DNS times out, private names resolve publicly, or Windows and WSL report different answers:

1. Check power state: `./scripts/debug/manage-vm.sh status dns`
2. Start the VM if needed: `./scripts/debug/manage-vm.sh start dns`
3. Validate the resolver path:

- `./scripts/debug/check-dns-server.sh`
- `./scripts/debug/check-dns.sh <hostname>`

4. If direct queries to the DNS VM succeed but Windows resolution fails, fix the VPN DNS configuration or refresh WSL after reconnect.
5. If both direct and Windows-side queries fail, inspect the CoreDNS container with `az vm run-command invoke`, then verify private DNS zones and DINE policy with `check-private-dns-zones.sh` and `check-dns-policy.sh --all`.

### Common failure scenarios and resolution

1. **DNS resolves to public IP instead of private**: Missing private DNS zone or zone not linked to hub VNet → `check-private-dns-zones.sh`
2. **Cannot reach any Azure resources**: VPN not connected → `check-vpn.sh`, verify Azure VPN Client on Windows
3. **DNS times out**: DNS resolver VM stopped (Logic App schedule) → `manage-vm.sh start dns`
4. **VPN reconnected but DNS broken**: Re-downloaded VPN XML profile missing `<dnsservers>` entry → Add DNS server IP to XML config
5. **Cannot reach spoke resources from another spoke**: Spokes not mesh-peered → `check-peerings.sh`, create direct spoke-to-spoke peering
6. **Private endpoint created but not resolving**: DINE policy hasn't created DNS zone group yet → `check-dns-policy.sh --all --remediate`
7. **New resource deployed but A record missing**: DINE policy needs time (15-30 min) or remediation → `check-dns-policy.sh --remediate`
8. **TCP connection fails despite correct DNS**: NSG on PE subnet or spoke subnet blocking traffic → `check-nsg.sh --all`, check effective rules with `check-nsg.sh --nic`
9. **GitHub workflow stays queued on the self-hosted runner**: Runner VM stopped, runner lost GitHub egress, or workflow labels do not match → `manage-vm.sh status gha-runner`, `az network watcher test-connectivity`, then inspect the runner service
10. **DNS scripts fail even though private endpoints look correct**: DNS VM stopped, CoreDNS not listening, or Windows VPN DNS settings drifted → `manage-vm.sh status dns`, `check-dns-server.sh`, then compare `Resolve-DnsName` with direct `nslookup`

## Custom Copilot Agents

### Network Troubleshooter (`@network-troubleshooter`)

A specialized Copilot agent for diagnosing Azure hub-spoke connectivity issues. It has deep knowledge of this landing zone architecture, the diagnostic scripts, and common failure patterns. Invoke it in Copilot Chat when you have a network connectivity problem — it will systematically diagnose the issue using the debug scripts and Azure CLI.

Located at: `.github/agents/network-troubleshooter.agent.md`

### IPAM (`@ipam`)

A Copilot agent for provisioning and managing spoke VNets. It discovers available address space, designs subnet plans, provisions VNets with peering and DNS, and manages the spoke inventory. Invoke it when you need a new spoke VNet — it will walk you through discovery, planning, dry run, and provisioning.

Located at: `.github/agents/ipam.agent.md`

## Deployment Safety

### Resource Deletion Policy

**CRITICAL:** Never delete, recreate, or destroy existing Azure resources (VMs, VNets, storage accounts, etc.) without explicit user permission.

When you encounter deployment errors related to existing resources:

1. **Always** use `azd what-if` or `--what-if` flag to preview changes before deployment
2. **Always** report what changes the deployment intends to make
3. **Always** ask the user for explicit confirmation before modifying or deleting any resource
4. **Never** automatically resolve errors by deleting resources
5. **Never** assume deletion is acceptable even if it would fix the error

### Common deployment errors and safe resolutions

| Error                                                                   | Cause                                              | Safe Resolution                                                                                                               |
| ----------------------------------------------------------------------- | -------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `PropertyChangeNotAllowed: Changing property 'osProfile.customData'`    | Attempting to modify VM custom data after creation | Cannot be fixed by updating the VM. Requires manual intervention or user approval to delete and recreate the VM.              |
| `A resource with this name already exists or is in a conflicting state` | Resource already exists or is soft-deleted         | Ask user if resource should be deleted, or use a different naming strategy. Check Azure Portal for soft-deleted resources.    |
| `Deployment failed: resource ... already exists`                        | Resource name collision or existing deployment     | Use `az deployment group show` to inspect existing deployment. Ask user before changing resource names or deleting conflicts. |

### Pre-deployment checklist

Before running `azd up`, `azd provision`, or any deployment command:

1. Run `azd what-if` to preview all changes
2. Report the output to the user with clear descriptions of what will be created, modified, or deleted
3. Wait for explicit user approval before proceeding with deployment
4. If the preview shows resource deletions, ask the user whether this is intentional

## Package Management

### New Package Lookup

**ALWAYS look up the latest package information on the internet whenever a new package is added to a project.**

When adding a new package (dependency, module, library, tool, etc.):

1. **Search for the package** using web search or package registry lookup (e.g., npm, PyPI, NuGet, Maven, etc.)
2. **Verify latest version** - Check the official package registry for the most recent stable release
3. **Review package documentation** - Visit the official repository or documentation to understand:
   - Purpose and features of the package
   - Installation requirements and compatibility
   - Configuration options
   - Known issues or deprecated versions to avoid
4. **Check for security advisories** - Look for any reported vulnerabilities or security warnings
5. **Verify compatibility** - Ensure the package is compatible with:
   - The project's runtime/framework version
   - Other existing dependencies
   - The target platform (OS, architecture)

This practice ensures we use current, secure, and compatible packages rather than relying on potentially outdated information.
