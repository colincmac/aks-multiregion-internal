#!/usr/bin/env pwsh
<#
  .SYNOPSIS
    Synchronizes the regional Flux/Kustomize overlays with the latest Azure deployment outputs.

  .DESCRIPTION
    Reads the subscription-scoped deployment outputs from infra/main.bicep and
    updates the per-region overlay patch files with the concrete AGC association IDs,
    Workload Identity client IDs, Private DNS zone name, and subscription-scoped values.
#>
param(
    [string]$DeploymentName,
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

$ErrorActionPreference = 'Stop'

function Set-RegexValue {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [Parameter(Mandatory = $true)][string]$Replacement
    )

    if (-not (Test-Path $Path)) {
        Write-Warning "Skipping missing file: $Path"
        return
    }

    $content = Get-Content -Raw -Path $Path
    $updated = [regex]::Replace($content, $Pattern, $Replacement)
    Set-Content -Path $Path -Value $updated -NoNewline
}

if (-not $DeploymentName) {
    $DeploymentName = az deployment sub list --query "sort_by([?starts_with(name, 'aks-multi-region-')], &properties.timestamp)[-1].name" -o tsv
}

if (-not $DeploymentName) {
    throw 'No matching subscription deployment was found.'
}

Write-Host "Loading deployment outputs from $DeploymentName..." -ForegroundColor Cyan
$deployment = az deployment sub show --name $DeploymentName -o json | ConvertFrom-Json
$outputs = $deployment.properties.outputs

if (-not $outputs.clusterGitOpsConfig) {
    throw 'The deployment does not expose clusterGitOpsConfig outputs. Re-run with the updated infra/main.bicep.'
}

$activeSubscriptionId = az account show --query id -o tsv
$globalResourceGroupName = $outputs.globalResourceGroupName.value
$clusters = @($outputs.clusterGitOpsConfig.value)

foreach ($cluster in $clusters) {
    $relativeOverlayPath = ($cluster.kustomizationPath -replace '^[./\\]+', '') -replace '/', [IO.Path]::DirectorySeparatorChar
    $overlayPath = Join-Path $RepoRoot $relativeOverlayPath

    if (-not (Test-Path $overlayPath)) {
        Write-Warning "Overlay path not found for cluster $($cluster.name): $overlayPath"
        continue
    }

    Write-Host "Updating overlay for cluster $($cluster.name) at $overlayPath" -ForegroundColor Green

    $externalDnsPatchPath = Join-Path $overlayPath 'externaldns-patch.yaml'
    Set-RegexValue -Path $externalDnsPatchPath -Pattern '(?m)(--azure-resource-group=).+$' -Replacement ('$1' + $globalResourceGroupName)
    Set-RegexValue -Path $externalDnsPatchPath -Pattern '(?m)(--azure-subscription-id=).+$' -Replacement ('$1' + $activeSubscriptionId)
    Set-RegexValue -Path $externalDnsPatchPath -Pattern '(?m)(--domain-filter=).+$' -Replacement ('$1' + $cluster.privateDnsZoneName)

    $externalDnsSaPatchPath = Join-Path $overlayPath 'externaldns-serviceaccount-patch.yaml'
    if ($cluster.externalDnsIdentityClientId) {
        Set-RegexValue -Path $externalDnsSaPatchPath -Pattern '(?m)(azure\.workload\.identity/client-id:\s*).+$' -Replacement ('$1' + $cluster.externalDnsIdentityClientId)
    }

    $agcAssociationPatchPath = Join-Path $overlayPath 'agc-association-patch.yaml'
    if ($cluster.albAssociationId) {
        Set-RegexValue -Path $agcAssociationPatchPath -Pattern '(?ms)(associations:\s*\r?\n\s*-\s*).+' -Replacement ('$1' + $cluster.albAssociationId)
    }

    $albControllerPatchPath = Join-Path $overlayPath 'alb-controller-identity-patch.yaml'
    if ($cluster.albControllerIdentityClientId) {
        Set-RegexValue -Path $albControllerPatchPath -Pattern '(?m)(clientId:\s*).+$' -Replacement ('$1' + $cluster.albControllerIdentityClientId)
    }
}

Write-Host 'Regional GitOps overlays updated successfully.' -ForegroundColor Green
