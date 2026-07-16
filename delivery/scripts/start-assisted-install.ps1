[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..'),
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'install.ps1') -PackageRoot $PackageRoot
$installedStart = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold\engine\start.ps1'
& $installedStart -Handoff -TimeoutSeconds $TimeoutSeconds
