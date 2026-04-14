using './main.bicep'

param environmentName = 'istio-mesh'
param kubernetesVersion = '1.35'
param gitRepositoryUrl = 'https://github.com/<org>/<repo>'
param gitRepositoryBranch = 'main'
param privateDnsZoneName = 'internal.contoso.com'
param globalResourcesLocation = 'eastus'

// Define as many clusters as needed. Each must have a unique name and
// non-overlapping addressPrefix. Add or remove entries to scale the mesh.
param clusters = [
  {
    name: 'eastus2'
    location: 'eastus2'
    addressPrefix: '10.1.0.0/16'
    aksSubnetPrefix: '10.1.0.0/20'
    ilbSubnetPrefix: '10.1.16.0/24'
    kustomizationPath: './clusters/east'
  }
  {
    name: 'centralus'
    location: 'centralus'
    addressPrefix: '10.2.0.0/16'
    aksSubnetPrefix: '10.2.0.0/20'
    ilbSubnetPrefix: '10.2.16.0/24'
    kustomizationPath: './clusters/west'
  }
]
