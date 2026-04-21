#!/usr/bin/env pwsh
<#
  .SYNOPSIS
    Deploys the multi-region AKS infrastructure.

  .DESCRIPTION
    Registers required resource providers, runs a what-if preview, and then
    performs the subscription-scoped Bicep deployment that creates VNets,
    private AKS clusters with Flux GitOps, the Tier-1 AGC resources,
    VNet peering, and a Private DNS zone. After provisioning, the script
    syncs the regional Flux overlays with the concrete deployment outputs.

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
    [string]$Location = "eastus",
    [switch]$SkipGitOpsConfigUpdate
)

$ErrorActionPreference = 'Stop'
$ResolvedParameterFile = (Resolve-Path $ParameterFile).Path
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
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
    'Microsoft.ManagedIdentity'
    'Microsoft.Network'
    'Microsoft.ServiceNetworking'
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

# --- Preview ------------------------------------------------------------
Write-Host "`nRunning what-if preview..." -ForegroundColor Cyan
az deployment sub what-if `
    --name "$DeploymentName-preview" `
    --location $Location `
    --template-file "$RepoRoot/infra/main.bicep" `
    --parameters $ResolvedParameterFile

if ($LASTEXITCODE -ne 0) {
    Write-Error "What-if validation failed."
    exit 1
}

# --- Deploy -------------------------------------------------------------
Write-Host "`nStarting deployment: $DeploymentName" -ForegroundColor Green
Write-Host "  Location   : $Location"
Write-Host "  Parameters : $ResolvedParameterFile"

az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --template-file "$RepoRoot/infra/main.bicep" `
    --parameters $ResolvedParameterFile `
    --verbose

if ($LASTEXITCODE -ne 0) {
    Write-Error "Deployment failed."
    exit 1
}

if (-not $SkipGitOpsConfigUpdate) {
    Write-Host "`nSyncing Flux overlay values from deployment outputs..." -ForegroundColor Cyan
    & "$PSScriptRoot/sync-gitops-config.ps1" -DeploymentName $DeploymentName -RepoRoot $RepoRoot
}

Write-Host "`nDeployment completed successfully." -ForegroundColor Green
