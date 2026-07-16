[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
& (Join-Path $PSScriptRoot 'preflight.ps1') -PackageRoot $PackageRoot | Out-Null

$stateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold'
$engineRoot = Join-Path $stateRoot 'engine'
$themeRoot = Join-Path $stateRoot 'theme'
$backupRoot = Join-Path $stateRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
$stagingRoot = Join-Path $stateRoot ('install-staging-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$previousInstall = $null
$previousInstallPath = Join-Path $stateRoot 'install.json'
if (Test-Path -LiteralPath $previousInstallPath -PathType Leaf) {
    try { $previousInstall = Get-Content -LiteralPath $previousInstallPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$previousShortcuts = if ($previousInstall -and $previousInstall.shortcuts) { @($previousInstall.shortcuts | ForEach-Object { [string]$_ }) } else { @() }
$createdShortcuts = @()

function Assert-StatePath([string]$Path, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $root = [IO.Path]::GetFullPath($stateRoot).TrimEnd('\', '/')
    if (-not $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped the product state root: $full"
    }
    return $full
}

function New-ProductShortcut {
    param([string]$Path, [string]$ScriptPath, [string]$Arguments, [string]$Description)
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = 'powershell.exe'
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $Arguments".Trim()
    $shortcut.WorkingDirectory = $stateRoot
    $shortcut.Description = $Description
    $shortcut.Save()
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

[IO.Directory]::CreateDirectory($stateRoot) | Out-Null
Assert-StatePath $stagingRoot 'staging path' | Out-Null
[IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
$previousEngine = $false
$previousTheme = $false
try {
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'engine') -Destination $stagingRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'client') -Destination $stagingRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $stagingRoot 'uninstall.ps1') -Force

    $stagedTheme = Get-Content -LiteralPath (Join-Path $stagingRoot 'client\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($stagedTheme.customizationRequired -ne $false) { throw 'Refusing to install an uncustomized theme.' }

    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    if (Test-Path -LiteralPath $engineRoot) {
        Assert-StatePath $engineRoot 'existing engine' | Out-Null
        Move-Item -LiteralPath $engineRoot -Destination (Join-Path $backupRoot 'engine')
        $previousEngine = $true
    }
    if (Test-Path -LiteralPath $themeRoot) {
        Assert-StatePath $themeRoot 'existing theme' | Out-Null
        Move-Item -LiteralPath $themeRoot -Destination (Join-Path $backupRoot 'theme')
        $previousTheme = $true
    }
    Move-Item -LiteralPath (Join-Path $stagingRoot 'engine') -Destination $engineRoot
    Move-Item -LiteralPath (Join-Path $stagingRoot 'client') -Destination $themeRoot
    Copy-Item -LiteralPath (Join-Path $stagingRoot 'uninstall.ps1') -Destination (Join-Path $stateRoot 'uninstall.ps1') -Force

    . (Join-Path $engineRoot 'common.ps1')
    $runtime = Install-BundledNodeRuntime
    $theme = Get-Content -LiteralPath (Join-Path $themeRoot 'theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $safeClientName = ([string]$theme.name -replace '[<>:"/\\|?*]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($safeClientName)) { $safeClientName = 'Codex 专属皮肤' }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $startMenu = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
    $launchShortcut = Join-Path $desktop ($safeClientName + '.lnk')
    $restoreShortcut = Join-Path $desktop ($safeClientName + ' - 恢复原版.lnk')
    $startShortcut = Join-Path $startMenu ($safeClientName + '.lnk')
    New-ProductShortcut -Path $launchShortcut -ScriptPath (Join-Path $engineRoot 'start.ps1') -Arguments '-Handoff' -Description '启动客户专属 Codex 视觉皮肤'
    New-ProductShortcut -Path $startShortcut -ScriptPath (Join-Path $engineRoot 'start.ps1') -Arguments '-Handoff' -Description '启动客户专属 Codex 视觉皮肤'
    New-ProductShortcut -Path $restoreShortcut -ScriptPath (Join-Path $engineRoot 'restore.ps1') -Arguments '-RestartNormal' -Description '移除当前视觉注入并打开原版 Codex'
    $createdShortcuts = @($launchShortcut, $startShortcut, $restoreShortcut)

    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $installRecord = [ordered]@{
        schemaVersion = 1
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        packageName = [string]$manifest.name
        packageVersion = [string]$manifest.version
        clientId = [string]$theme.id
        clientName = [string]$theme.name
        heroSha256 = [string]$manifest.client.heroSha256
        assetRightsConfirmed = [bool]$manifest.client.assetRightsConfirmed
        runtime = $runtime
        shortcuts = @($launchShortcut, $startShortcut, $restoreShortcut)
        previousVersionBackup = if ($previousEngine -or $previousTheme) { $backupRoot } else { $null }
        codexFilesModified = $false
        networkUsed = $false
    }
    [IO.File]::WriteAllText((Join-Path $stateRoot 'install.json'), ($installRecord | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8NoBom)
    foreach ($oldShortcut in $previousShortcuts) {
        if ($oldShortcut -notin $createdShortcuts -and (Test-AllowedShortcutPath $oldShortcut) -and (Test-Path -LiteralPath $oldShortcut)) {
            Remove-Item -LiteralPath $oldShortcut -Force
        }
    }
    Write-Output "INSTALLED: $($theme.name)"
    Write-Output "Launch shortcut: $launchShortcut"
    Write-Output 'Codex application files were not modified. No network download was used.'
} catch {
    foreach ($shortcut in $createdShortcuts) {
        if ($shortcut -notin $previousShortcuts -and (Test-AllowedShortcutPath $shortcut) -and (Test-Path -LiteralPath $shortcut)) {
            Remove-Item -LiteralPath $shortcut -Force
        }
    }
    foreach ($target in @($engineRoot, $themeRoot)) {
        if (Test-Path -LiteralPath $target) {
            Assert-StatePath $target 'rollback target' | Out-Null
            Remove-Item -LiteralPath $target -Recurse -Force
        }
    }
    if ($previousEngine -and (Test-Path -LiteralPath (Join-Path $backupRoot 'engine'))) {
        Move-Item -LiteralPath (Join-Path $backupRoot 'engine') -Destination $engineRoot
    }
    if ($previousTheme -and (Test-Path -LiteralPath (Join-Path $backupRoot 'theme'))) {
        Move-Item -LiteralPath (Join-Path $backupRoot 'theme') -Destination $themeRoot
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-StatePath $stagingRoot 'staging cleanup' | Out-Null
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
}
