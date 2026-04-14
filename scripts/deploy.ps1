#!/usr/bin/env pwsh
<#
  .SYNOPSIS
    Deploys the multi-region AKS infrastructure.

  .DESCRIPTION
    Registers required resource providers, then runs a subscription-scoped
    Bicep deployment that creates VNets, private AKS clusters with Flux
    GitOps, VNet peering, and a Private DNS zone.

  .PARAMETER SubscriptionId
    Target Azure subscription. Uses current az context if omitted.

  .PARAMETER ParameterFile
    Path to the .bicepparam file. Defaults to ../infra/main.bicepparam.

  .PARAMETER Location
    Deployment metadata location. Defaults to eastus.
#>
param(
    [string]$SubscriptionId,
    [string]$ParameterFile = "$PSScriptRoot/../infra/main.bicepparam",
    [string]$Location = "eastus"
)

$ErrorActionPreference = 'Stop'
$DeploymentName = "aks-multi-region-$(Get-Date -Format 'yyyyMMddHHmmss')"

# --- Set subscription --------------------------------------------------
if ($SubscriptionId) {
    Write-Host "Setting subscription to $SubscriptionId..." -ForegroundColor Cyan
    az account set --subscription $SubscriptionId
}

# --- Register providers -------------------------------------------------
$providers = @(
    'Microsoft.ContainerService'
    'Microsoft.KubernetesConfiguration'
    'Microsoft.Network'
)

Write-Host "Ensuring resource providers are registered..." -ForegroundColor Cyan
foreach ($provider in $providers) {
    $state = az provider show --namespace $provider --query "registrationState" -o tsv 2>$null
    if ($state -ne 'Registered') {
        Write-Host "  Registering $provider..."
        az provider register --namespace $provider
    } else {
        Write-Host "  $provider — already registered"
    }
}

# --- Deploy -------------------------------------------------------------
Write-Host "`nStarting deployment: $DeploymentName" -ForegroundColor Green
Write-Host "  Location   : $Location"
Write-Host "  Parameters : $ParameterFile"

az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --template-file "$PSScriptRoot/../infra/main.bicep" `
    --parameters $ParameterFile `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed."
    exit 1
}

Write-Host "`nDeployment completed successfully." -ForegroundColor Green
