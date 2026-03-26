@description('Azure region for all resources.')
param location string

@description('Subnet resource ID for the VM NIC.')
param subnetResourceId string

@description('Resource token for unique naming.')
param resourceToken string

@description('Abbreviations object for resource naming.')
param abbrs object

@description('Admin username for the VM.')
@secure()
param adminUsername string

@description('SSH public key data for key-based authentication (no password auth).')
param adminPublicKey string

@description('Cloud-init script content for GitHub Actions runner registration.')
param customData string

@description('Static private IP address for the VM.')
param privateIPAddress string = '10.255.1.5'

@description('Image publisher for the VM.')
param publisher string = 'canonical'

@description('Image offer for the VM.')
param offer string = 'ubuntu-24_04-lts'

@description('Image SKU for the VM.')
param sku string = 'server'

@description('Image version for the VM.')
param version string = 'latest'

@description('VM size.')
param vmSize string = 'Standard_D8ds_v4'

@description('OS disk size in GB.')
param diskSizeGB int = 1024

var vmName = '${abbrs.computeVirtualMachines}${resourceToken}'
var nicName = '${abbrs.networkNetworkInterfaces}${resourceToken}'

resource nic 'Microsoft.Network/networkInterfaces@2024-03-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig01'
        properties: {
          subnet: {
            id: subnetResourceId
          }
          privateIPAddress: privateIPAddress
          privateIPAllocationMethod: 'Static'
        }
      }
    ]
    enableAcceleratedNetworking: false
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      customData: base64(customData)
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        patchSettings: {
          patchMode: 'AutomaticByPlatform'
          assessmentMode: 'AutomaticByPlatform'
          automaticByPlatformSettings: {
            bypassPlatformSafetyChecksOnUserSchedule: true
          }
        }
        ssh: {
          publicKeys: [
            {
              keyData: adminPublicKey
              path: '/home/${adminUsername}/.ssh/authorized_keys'
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: publisher
        offer: offer
        sku: sku
        version: version
      }
      osDisk: {
        createOption: 'FromImage'
        caching: 'ReadWrite'
        deleteOption: 'Delete'
        diskSizeGB: diskSizeGB
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
  }
}

resource azureMonitorAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'AzureMonitorLinuxAgent'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.Monitor'
    type: 'AzureMonitorLinuxAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    enableAutomaticUpgrade: true
  }
}

resource networkWatcherAgentExtension 'Microsoft.Compute/virtualMachines/extensions@2024-07-01' = {
  parent: vm
  name: 'NetworkWatcherAgentLinux'
  location: location
  properties: {
    publisher: 'Microsoft.Azure.NetworkWatcher'
    type: 'NetworkWatcherAgentLinux'
    typeHandlerVersion: '1.4'
    autoUpgradeMinorVersion: true
  }
}

output virtualMachineId string = vm.id
output virtualMachineName string = vm.name
output virtualMachinePrincipalId string = vm.identity.principalId
