using './main.bicep'

// environmentName is provided by `azd` via AZURE_ENV_NAME, or set manually.
param environmentName = readEnvironmentVariable('AZURE_ENV_NAME', 'istio-mesh')

param kubernetesVersion = '1.35'

// URL of the Git repository Flux will sync from.
param gitRepositoryUrl = readEnvironmentVariable('GIT_REPOSITORY_URL', 'https://github.com/colincmac/aks-multiregion-internal')

param gitRepositoryBranch = readEnvironmentVariable('GIT_REPOSITORY_BRANCH', 'main')

param privateDnsZoneName = readEnvironmentVariable('PRIVATE_DNS_ZONE_NAME', 'internal.contoso.com')

// globalResourcesLocation is provided by `azd` via AZURE_LOCATION, or set manually.
param globalResourcesLocation = readEnvironmentVariable('AZURE_LOCATION', 'eastus')

// Define one entry per cluster. Every cluster must use a non-overlapping
// addressPrefix. Add or remove entries to scale the mesh.
param clusters = [
  {
    name: 'eastus2'
    location: 'eastus2'
    addressPrefix: '10.1.0.0/16'
    aksSubnetPrefix: '10.1.0.0/20'
    ilbSubnetPrefix: '10.1.16.0/24'
    bastionSubnetPrefix: '10.1.17.0/26'
    utilityVMSubnetPrefix: '10.1.18.0/28'
    albSubnetPrefix: '10.1.19.0/24'
    kustomizationPath: './clusters/east'
  }
  {
    name: 'centralus'
    location: 'centralus'
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
    bastionSubnetPrefix: '10.2.17.0/26'
    utilityVMSubnetPrefix: '10.2.18.0/28'
    albSubnetPrefix: '10.2.19.0/24'
    kustomizationPath: './clusters/west'
  }
]
