//azurevelo
//Version: 0.1.1
//Author: msdirtbag

//Scope
targetScope = 'resourceGroup'

//Variables
var blobrole = '/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var environmentid = uniqueString(subscription().id, resourceGroup().id, tenant().tenantId, env)
var location = resourceGroup().location

//Parameters
@description('Chose a variable for the environment. Example: dev, test, soc')
param env string

@description('Chose a root password for the veloadmin account')
@secure()
param velopassword string


//Resources

//User Managed Identity
resource managedidentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2024-11-30' = {
  name: 'umi-azurevelo-${environmentid}'
  location: location
}

//Blob Storage Role Assignments
resource blobroleassign 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(environmentid, blobrole, subscription().id)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'ba92f5b4-2d11-453d-a403-e96b0029c9fe')
    principalId: managedidentity.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

//Storage Account
resource storage01 'Microsoft.Storage/storageAccounts@2024-01-01' = {
  name: 'stazurevelo${environmentid}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedidentity.id}': {}
    }
  }
  kind: 'StorageV2'
  sku: {
    name: 'Standard_LRS'
  }
  properties: {
    encryption: {
      keySource: 'Microsoft.Storage'
      requireInfrastructureEncryption: true
      services: {
        blob: {
          enabled: true
        }
        file: {
          enabled: true
        }
        queue: {
          enabled: true
          keyType: 'Service'
        }
        table: {
          enabled: true
          keyType: 'Service'
        }
      }
    }
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    publicNetworkAccess: 'Enabled'
    minimumTlsVersion: 'TLS1_2'
  }
}

resource azurefiles 'Microsoft.Storage/storageAccounts/fileServices@2024-01-01' = {
  parent: storage01
  name: 'default'
  properties: {
    shareDeleteRetentionPolicy: {
      days: 7
      enabled: true
    }
  }
}

// SMB Shares for Velociraptor Storage
resource artifactsshare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: azurefiles
  name: 'artifacts'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
  }
}

resource datastoreshare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: azurefiles
  name: 'datastore'
  properties: {
    accessTier: 'Hot'
    enabledProtocols: 'SMB'
  }
}

resource filestoreshare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: azurefiles
  name: 'filestore'
  properties: {
    accessTier: 'Hot'
    enabledProtocols: 'SMB'
  }
}

resource logsshare 'Microsoft.Storage/storageAccounts/fileServices/shares@2024-01-01' = {
  parent: azurefiles
  name: 'logs'
  properties: {
    accessTier: 'TransactionOptimized'
    enabledProtocols: 'SMB'
  }
}

//App Service Plan
resource appserviceplan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-azurevelo-${environmentid}'
  location: location
  properties: {
    reserved: true
    elasticScaleEnabled: false
  }
  sku: {
    tier: 'PremiumV3'
    name: 'P0v3'    
  }
  kind: 'linux'
}

//This deploys the Azure App Service.
resource appservice 'Microsoft.Web/sites@2022-09-01' = {
  name: 'ase-azurevelo-${environmentid}'
  location: location
  kind: 'container'
  properties: {
    serverFarmId: appserviceplan.id
    publicNetworkAccess: 'Enabled'
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|ghcr.io/msdirtbag/azurevelo'
      numberOfWorkers: 1
      requestTracingEnabled: false
      remoteDebuggingEnabled: false
      httpLoggingEnabled: true
      logsDirectorySizeLimit: 35
      detailedErrorLoggingEnabled: true
      webSocketsEnabled: true
      alwaysOn: true
      autoHealEnabled: true
      ipSecurityRestrictions: [
        {
          ipAddress: 'Any'
          action: 'Allow'
          priority: 2147483647
          name: 'Allow all'
          description: 'Allow all access'
        }
      ]
      scmIpSecurityRestrictions: [
        {
          ipAddress: 'Any'
          action: 'Deny'
          priority: 2147483647
          name: 'Block all'
          description: 'Block all access'
        }
      ]
      scmIpSecurityRestrictionsUseMain: false
      http20Enabled: false
      minTlsVersion: '1.2'
      scmMinTlsVersion: '1.2'
      ftpsState: 'Disabled'
      minimumElasticInstanceCount: 1
    }
  }
}

//This deploys the App Settings
resource appsettings 'Microsoft.Web/sites/config@2022-09-01' = {
  name: 'appsettings'
  kind: 'calappsettings'
  parent: appservice
  properties: {
    WEBSITES_ENABLE_APP_SERVICE_STORAGE: 'true'
    VELOX_FRONTEND_HOSTNAME: appservice.properties.defaultHostName
    VELOX_PASSWORD: velopassword
    VELOX_ROLE: 'administrator'
    VELOX_SERVER_URL: 'wss://${appservice.properties.defaultHostName}/'
    VELOX_USER: 'veloadmin'
    WEBSITE_HTTPLOGGING_RETENTION_DAYS: '30'
    WEBSITES_PORT: '8000'
  }
}

//This deploys the Azure Files Config
resource azurefilesconfig 'Microsoft.Web/sites/config@2024-04-01' = {
  parent: appservice
  name: 'web'
  properties: {
    azureStorageAccounts: {
      artifacts: {
        type: 'AzureFiles'
        accountName: storage01.name
        accessKey: listKeys(storage01.id, '2024-01-01').keys[0].value
        shareName: 'artifacts'
        mountPath: '/mnt/artifacts'
        protocol: 'Smb'
      }
      datastore: {
        type: 'AzureFiles'
        accountName: storage01.name
        accessKey: listKeys(storage01.id, '2024-01-01').keys[0].value
        shareName: 'datastore'
        mountPath: '/mnt/datastore'
        protocol: 'Smb'
      }
      filestore: {
        type: 'AzureFiles'
        accountName: storage01.name
        accessKey: listKeys(storage01.id, '2024-01-01').keys[0].value
        shareName: 'filestore'
        mountPath: '/mnt/filestore'
        protocol: 'Smb'
      }
      logs: {
        type: 'AzureFiles'
        accountName: storage01.name
        accessKey: listKeys(storage01.id, '2024-01-01').keys[0].value
        shareName: 'logs'
        mountPath: '/mnt/logs'
        protocol: 'Smb'
      }
    }
  }
}
