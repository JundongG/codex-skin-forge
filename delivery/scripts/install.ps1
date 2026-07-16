[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
& (Join-Path $PSScriptRoot 'preflight.ps1') -PackageRoot $PackageRoot | Out-Null
. (Join-Path $PackageRoot 'engine\common.ps1')

$stateRoot = $script:StateRoot
$engineRoot = $script:EngineRoot
$themeRoot = $script:ThemeRoot
$backupRoot = Join-Path $stateRoot ('backups\' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
$stagingRoot = Join-Path $stateRoot ('install-staging-' + [guid]::NewGuid().ToString('N'))
$transactionPath = Join-Path $stateRoot 'install-transaction.json'
$previousInstall = $null
$previousShortcuts = @()
$createdShortcuts = @()
$backedUpPaths = @()
$managedPaths = @('engine', 'theme', 'runtime', 'uninstall.ps1', 'install.json')
$lifecycleMutex = $null
$committed = $false

function Set-ProductShortcut {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$Path, [string]$ScriptPath, [string]$Arguments, [string]$Description)
    if (-not $PSCmdlet.ShouldProcess($Path, 'Create or update Codex Skin Forge shortcut')) { return }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($Path)
    $shortcut.TargetPath = Get-SystemPowerShellPath
    $shortcut.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $Arguments".Trim()
    $shortcut.WorkingDirectory = $stateRoot
    $shortcut.Description = $Description
    $shortcut.Save()
}

function Test-AllowedShortcutPath([string]$Path) {
    if ([IO.Path]::GetExtension($Path) -ne '.lnk') { return $false }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($root in @((Get-DesktopDirectory), (Get-StartMenuProgramsDirectory))) {
        $prefix = [IO.Path]::GetFullPath($root).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if ($full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Invoke-InstallFailPoint([string]$Name) {
    $failPoint = Get-Variable -Name CodexSkinForgeInstallFailPoint -Scope Script -ErrorAction SilentlyContinue
    if ($failPoint -and [string]$failPoint.Value -eq $Name) {
        throw "Simulated install failure at $Name."
    }
}

function Restore-InterruptedInstall {
    $journal = Read-JsonFile -Path $transactionPath
    if (-not $journal) {
        if (Test-Path -LiteralPath $transactionPath) { Remove-Item -LiteralPath $transactionPath -Force }
        return
    }
    $journalBackupValue = Get-OptionalProperty -Object $journal -Name 'backupRoot'
    $phase = [string](Get-OptionalProperty -Object $journal -Name 'phase')
    if (-not $journalBackupValue) { throw 'Interrupted install journal is missing backupRoot.' }
    $journalBackup = Assert-PathWithin -Path ([string]$journalBackupValue) -Root $stateRoot -Label 'transaction backup root'
    if ($phase -eq 'committed') {
        Remove-Item -LiteralPath $transactionPath -Force
        return
    }
    if (-not (Test-Path -LiteralPath $journalBackup -PathType Container)) {
        throw "Interrupted install backup is missing: $journalBackup"
    }
    if ($phase -eq 'preparing') {
        foreach ($relative in $managedPaths) {
            $backupSource = Join-Path $journalBackup $relative
            Assert-PathWithin -Path $backupSource -Root $journalBackup -Label 'transaction backup source' | Out-Null
            if (Test-Path -LiteralPath $backupSource) {
                [void](Restore-ProductPathFromBackup -RelativePath $relative -BackupRoot $journalBackup)
            }
        }
    } elseif ($phase -eq 'backed-up') {
        foreach ($relative in $managedPaths) {
            $target = Get-ProductPath -RelativePath $relative -Label 'interrupted install cleanup'
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        }
        foreach ($relative in $managedPaths) {
            $backupSource = Join-Path $journalBackup $relative
            Assert-PathWithin -Path $backupSource -Root $journalBackup -Label 'transaction backup source' | Out-Null
            if (Test-Path -LiteralPath $backupSource) {
                [void](Restore-ProductPathFromBackup -RelativePath $relative -BackupRoot $journalBackup)
            }
        }
    } else {
        throw "Unknown interrupted install phase: $phase"
    }
    Remove-Item -LiteralPath $transactionPath -Force
}

try {
    $lifecycleMutex = Enter-ProductMutex -Purpose 'lifecycle' -TimeoutMilliseconds 3000
    Restore-InterruptedInstall
    $previousInstall = Read-JsonFile -Path (Join-Path $stateRoot 'install.json')
    $previousShortcutValue = Get-OptionalProperty -Object $previousInstall -Name 'shortcuts'
    $previousShortcuts = if ($previousShortcutValue) {
        @($previousShortcutValue | ForEach-Object { [string]$_ })
    } else {
        @()
    }
    if (Get-ActiveHandoffWorker) { throw 'A themed-launch handoff is in progress. Wait for it to finish before installing or upgrading.' }
    if (Test-ActiveThemedSession) { throw 'A themed Codex session is active. Restore or close it before installing or upgrading.' }
    if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    if (Test-Path -LiteralPath $script:HandoffPath) { Remove-Item -LiteralPath $script:HandoffPath -Force }

    [IO.Directory]::CreateDirectory($stateRoot) | Out-Null
    Assert-PathWithin -Path $stagingRoot -Root $stateRoot -Label 'staging path' | Out-Null
    [IO.Directory]::CreateDirectory($stagingRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'engine') -Destination $stagingRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PackageRoot 'client') -Destination $stagingRoot -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'uninstall.ps1') -Destination (Join-Path $stagingRoot 'uninstall.ps1') -Force

    $stagedTheme = Get-Content -LiteralPath (Join-Path $stagingRoot 'client\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($stagedTheme.customizationRequired -ne $false) { throw 'Refusing to install an uncustomized theme.' }

    [IO.Directory]::CreateDirectory($backupRoot) | Out-Null
    Write-JsonFile -Path $transactionPath -Value ([ordered]@{
        schemaVersion = 1
        phase = 'preparing'
        backupRoot = $backupRoot
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
    foreach ($relative in $managedPaths) {
        if (Move-ProductPathToBackup -RelativePath $relative -BackupRoot $backupRoot) {
            $backedUpPaths += $relative
        }
    }
    Write-JsonFile -Path $transactionPath -Value ([ordered]@{
        schemaVersion = 1
        phase = 'backed-up'
        backupRoot = $backupRoot
        startedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
    Invoke-InstallFailPoint 'after-backup'

    Move-Item -LiteralPath (Join-Path $stagingRoot 'engine') -Destination $engineRoot
    Move-Item -LiteralPath (Join-Path $stagingRoot 'client') -Destination $themeRoot
    Copy-Item -LiteralPath (Join-Path $stagingRoot 'uninstall.ps1') -Destination (Join-Path $stateRoot 'uninstall.ps1') -Force

    $runtime = Install-BundledNodeRuntime
    $injector = Join-Path $engineRoot 'injector.mjs'
    & $script:NodePath $injector --validate-theme --theme-root $themeRoot *> $null
    if ($LASTEXITCODE -ne 0) { throw 'The installed customer theme failed post-copy validation.' }
    Invoke-InstallFailPoint 'after-copy'
    $theme = Get-Content -LiteralPath (Join-Path $themeRoot 'theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json

    $safeClientName = ([string]$theme.name -replace '[<>:"/\\|?*]', '').Trim()
    if ([string]::IsNullOrWhiteSpace($safeClientName)) { $safeClientName = 'Codex 专属皮肤' }
    $desktop = Get-DesktopDirectory
    $startMenu = Get-StartMenuProgramsDirectory
    $launchShortcut = Join-Path $desktop ($safeClientName + '.lnk')
    $restoreShortcut = Join-Path $desktop ($safeClientName + ' - 恢复原版.lnk')
    $startShortcut = Join-Path $startMenu ($safeClientName + '.lnk')
    $intendedShortcuts = @($launchShortcut, $startShortcut, $restoreShortcut)

    $manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $installRecord = [ordered]@{
        schemaVersion = 2
        installedAt = (Get-Date).ToUniversalTime().ToString('o')
        packageName = [string]$manifest.name
        packageVersion = [string]$manifest.version
        clientId = [string]$theme.id
        clientName = [string]$theme.name
        heroSha256 = [string]$manifest.client.heroSha256
        assetRightsConfirmed = [bool]$manifest.client.assetRightsConfirmed
        runtime = $runtime
        shortcuts = @($intendedShortcuts)
        previousVersionBackup = if ($backedUpPaths.Count -gt 0) { $backupRoot } else { $null }
        codexFilesModified = $false
        networkUsed = $false
    }
    Write-JsonFile -Path (Join-Path $stateRoot 'install.json') -Value $installRecord
    Write-JsonFile -Path $transactionPath -Value ([ordered]@{
        schemaVersion = 1
        phase = 'committed'
        backupRoot = $backupRoot
        committedAt = (Get-Date).ToUniversalTime().ToString('o')
    })
    $committed = $true
    Remove-Item -LiteralPath $transactionPath -Force

    foreach ($shortcutSpec in @(
        @{ Path = $launchShortcut; Script = (Join-Path $engineRoot 'start.ps1'); Arguments = '-Handoff'; Description = '启动客户专属 Codex 视觉皮肤' },
        @{ Path = $startShortcut; Script = (Join-Path $engineRoot 'start.ps1'); Arguments = '-Handoff'; Description = '启动客户专属 Codex 视觉皮肤' },
        @{ Path = $restoreShortcut; Script = (Join-Path $engineRoot 'restore.ps1'); Arguments = '-RestartNormal'; Description = '移除当前视觉注入并打开原版 Codex' }
    )) {
        try {
            Set-ProductShortcut -Path $shortcutSpec.Path -ScriptPath $shortcutSpec.Script -Arguments $shortcutSpec.Arguments -Description $shortcutSpec.Description
            $createdShortcuts += $shortcutSpec.Path
        } catch {
            Write-Warning "The installation succeeded, but shortcut creation failed: $($shortcutSpec.Path)"
        }
    }
    foreach ($oldShortcut in $previousShortcuts) {
        if ($oldShortcut -notin $intendedShortcuts -and (Test-AllowedShortcutPath $oldShortcut) -and (Test-Path -LiteralPath $oldShortcut)) {
            try { Remove-Item -LiteralPath $oldShortcut -Force } catch { Write-Warning "Could not remove old shortcut '$oldShortcut'." }
        }
    }
    if ($backedUpPaths.Count -eq 0 -and (Test-Path -LiteralPath $backupRoot)) {
        Remove-Item -LiteralPath $backupRoot -Recurse -Force
    }

    Write-Output "INSTALLED: $($theme.name)"
    if (Test-Path -LiteralPath $launchShortcut) {
        Write-Output "Launch shortcut: $launchShortcut"
    } else {
        Write-Output "Launch command: powershell -ExecutionPolicy Bypass -File `"$engineRoot\start.ps1`" -Handoff"
    }
    Write-Output 'Codex application files were not modified. No network download was used.'
} catch {
    if (-not $committed) {
        foreach ($shortcut in $createdShortcuts) {
            if ($shortcut -notin $previousShortcuts -and (Test-AllowedShortcutPath $shortcut) -and (Test-Path -LiteralPath $shortcut)) {
                Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
            }
        }
        foreach ($relative in $managedPaths) {
            $target = Get-ProductPath -RelativePath $relative -Label 'rollback target'
            if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
        }
        foreach ($relative in $backedUpPaths) {
            [void](Restore-ProductPathFromBackup -RelativePath $relative -BackupRoot $backupRoot)
        }
        if (Test-Path -LiteralPath $transactionPath) { Remove-Item -LiteralPath $transactionPath -Force }
        if (Test-Path -LiteralPath $backupRoot) {
            Assert-PathWithin -Path $backupRoot -Root $stateRoot -Label 'failed backup cleanup' | Out-Null
            Remove-Item -LiteralPath $backupRoot -Recurse -Force
        }
    }
    throw
} finally {
    if (Test-Path -LiteralPath $stagingRoot) {
        Assert-PathWithin -Path $stagingRoot -Root $stateRoot -Label 'staging cleanup' | Out-Null
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force
    }
    Exit-ProductMutex -Mutex $lifecycleMutex
}
