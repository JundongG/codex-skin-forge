[CmdletBinding()]
param([switch]$RemoveBackups)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold'
$engineRoot = Join-Path $stateRoot 'engine'
$installPath = Join-Path $stateRoot 'install.json'

function Assert-StatePath([string]$Path, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetFullPath($stateRoot).TrimEnd('\', '/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped the product state root: $full"
    }
    return $full
}

function Test-AllowedShortcutPath([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ne '.lnk') { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'))) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$install = $null
if (Test-Path -LiteralPath $installPath -PathType Leaf) {
    try { $install = Get-Content -LiteralPath $installPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
if (Test-Path -LiteralPath (Join-Path $engineRoot 'restore.ps1') -PathType Leaf) {
    try { & (Join-Path $engineRoot 'restore.ps1') } catch { Write-Warning $_.Exception.Message }
}
if ($install -and $install.shortcuts) {
    foreach ($shortcut in @($install.shortcuts)) {
        if ((Test-AllowedShortcutPath ([string]$shortcut)) -and (Test-Path -LiteralPath ([string]$shortcut))) {
            Remove-Item -LiteralPath ([string]$shortcut) -Force
        }
    }
}
foreach ($relative in @('engine', 'theme', 'runtime', 'state.json', 'latest-result.json', 'diagnostics.json')) {
    $target = Join-Path $stateRoot $relative
    if (Test-Path -LiteralPath $target) {
        Assert-StatePath $target 'uninstall target' | Out-Null
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}
Get-ChildItem -LiteralPath $stateRoot -Filter 'injector-*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
    Assert-StatePath $_.FullName 'log cleanup' | Out-Null
    Remove-Item -LiteralPath $_.FullName -Force
}
if ($RemoveBackups) {
    $backups = Join-Path $stateRoot 'backups'
    if (Test-Path -LiteralPath $backups) {
        Assert-StatePath $backups 'backup cleanup' | Out-Null
        Remove-Item -LiteralPath $backups -Recurse -Force
    }
}
Write-Output 'Noir Gold engine, customer theme, copied runtime and shortcuts were removed.'
Write-Output 'The official Codex installation and user conversations were not changed.'
