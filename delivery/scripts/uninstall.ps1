[CmdletBinding()]
param(
    [switch]$KeepBackups,
    [switch]$ForceClose,
    [switch]$RemoveBackups
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$stateRootOverride = Get-Variable -Name CodexSkinForgeStateRootOverride -Scope Script -ErrorAction SilentlyContinue
$stateRoot = if ($stateRootOverride -and -not [string]::IsNullOrWhiteSpace([string]$stateRootOverride.Value)) {
    [IO.Path]::GetFullPath([string]$stateRootOverride.Value)
} else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold'
}
$engineRoot = Join-Path $stateRoot 'engine'
$installPath = Join-Path $stateRoot 'install.json'
$commonCandidates = @(
    (Join-Path $engineRoot 'common.ps1'),
    (Join-Path (Join-Path $PSScriptRoot '..\engine') 'common.ps1')
)
$backupCommon = Get-ChildItem -LiteralPath (Join-Path $stateRoot 'backups') -Filter 'common.ps1' -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -match '\\engine\\common\.ps1$' } |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if ($backupCommon) { $commonCandidates += $backupCommon.FullName }
$common = $commonCandidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
if (-not $common) { throw 'The installed recovery helper is missing. Reinstall the same customer package, then uninstall again.' }
. $common

function Test-AllowedShortcutPath([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ne '.lnk') { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @((Get-DesktopDirectory), (Get-StartMenuProgramsDirectory))) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

$lifecycleMutex = $null
$removeRootAfterRelease = $false
try {
    $lifecycleMutex = Enter-ProductMutex -Purpose 'lifecycle' -TimeoutMilliseconds 3000
    if (Get-ActiveHandoffWorker) { throw 'A themed-launch handoff is active. Wait for it to finish or close it before uninstalling.' }

    $restore = Join-Path $engineRoot 'restore.ps1'
    if (Test-ActiveThemedSession) {
        if (-not (Test-Path -LiteralPath $restore -PathType Leaf)) {
            throw 'An active themed session was detected, but restore.ps1 is missing. Close Codex and reinstall before uninstalling.'
        }
        & $restore -ForceClose:$ForceClose
    } elseif (Test-Path -LiteralPath $script:StatePath) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }

    $install = Read-JsonFile -Path $installPath
    $installedShortcuts = Get-OptionalProperty -Object $install -Name 'shortcuts'
    if ($installedShortcuts) {
        foreach ($shortcut in @($installedShortcuts)) {
            if ((Test-AllowedShortcutPath ([string]$shortcut)) -and (Test-Path -LiteralPath ([string]$shortcut))) {
                Remove-Item -LiteralPath ([string]$shortcut) -Force
            }
        }
    }

    foreach ($relative in @('engine', 'theme', 'runtime', 'state.json', 'handoff.json', 'install-transaction.json', 'latest-result.json', 'diagnostics.json')) {
        $target = Get-ProductPath -RelativePath $relative -Label 'uninstall target'
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
    }
    Get-ChildItem -LiteralPath $stateRoot -Filter 'injector-*.log' -File -ErrorAction SilentlyContinue | ForEach-Object {
        Assert-PathWithin -Path $_.FullName -Root $stateRoot -Label 'log cleanup' | Out-Null
        Remove-Item -LiteralPath $_.FullName -Force
    }

    if (-not $KeepBackups -or $RemoveBackups) {
        foreach ($relative in @('backups', 'install.json')) {
            $target = Get-ProductPath -RelativePath $relative -Label 'uninstall metadata'
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        }
        $removeRootAfterRelease = $true
    }
} finally {
    Exit-ProductMutex -Mutex $lifecycleMutex
}

if ($removeRootAfterRelease) {
    $installedUninstaller = Join-Path $stateRoot 'uninstall.ps1'
    if (Test-Path -LiteralPath $installedUninstaller) {
        Assert-PathWithin -Path $installedUninstaller -Root $stateRoot -Label 'uninstaller cleanup' | Out-Null
        Remove-Item -LiteralPath $installedUninstaller -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $installedUninstaller) {
            Write-Warning "The uninstaller could not remove itself: $installedUninstaller"
        }
    }
    if ((Test-Path -LiteralPath $stateRoot) -and @(Get-ChildItem -LiteralPath $stateRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $stateRoot -Force -ErrorAction SilentlyContinue
    }
    Write-Output 'Codex Skin Forge, customer assets, copied runtime, backups and shortcuts were removed.'
} else {
    Write-Output "Codex Skin Forge was removed, but customer backups were retained at '$stateRoot\backups'."
}
Write-Output 'The official Codex installation and user conversations were not changed.'
