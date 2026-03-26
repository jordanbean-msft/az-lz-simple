param location string
param subnetResourceId string
param resourceToken string
param abbrs object
@secure()
param adminUsername string
@secure()
param adminPassword string
param customData string
param offer string
param publisher string
param sku string
param version string
param diskSizeGB int
param vmSize string
param osType string
param privateIPAddress string

module virtualMachine 'br/public:avm/res/compute/virtual-machine:0.17.0' = {
  name: 'virtual-machine-${resourceToken}'
  params: {
    name: '${abbrs.computeVirtualMachines}${resourceToken}'
    location: location
    adminUsername: adminUsername
    adminPassword: adminPassword
    availabilityZone: -1
    imageReference: {
      offer: offer
      publisher: publisher
      sku: sku
      version: version
    }
    nicConfigurations: [
      {
        ipConfigurations: [
          {
            name: 'ipconfig01'
            subnetResourceId: subnetResourceId
            privateIPAddress: privateIPAddress
          }
        ]
        nicSuffix: '-nic-01'
        enableAcceleratedNetworking: false
        deleteOption: 'Delete'
      }
    ]
    osDisk: {
      caching: 'ReadWrite'
      diskSizeGB: diskSizeGB
      managedDisk: {
        storageAccountType: 'StandardSSD_LRS'
      }
      deleteOption: 'Delete'
    }
    vmSize: vmSize
    customData: customData
    osType: osType
    bootDiagnostics: true
  }
}

output virtualMachineId string = virtualMachine.outputs.resourceId
output virtualMachineName string = virtualMachine.outputs.name
