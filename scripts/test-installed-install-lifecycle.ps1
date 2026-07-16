[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-skin-installed-lifecycle-' + [guid]::NewGuid().ToString('N'))
$packageOutput = Join-Path $tempRoot 'package'
$expanded = Join-Path $tempRoot 'expanded'
$testState = Join-Path $tempRoot 'state'
$testDesktop = Join-Path $tempRoot 'desktop'
$testStartMenu = Join-Path $tempRoot 'start-menu'

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

foreach ($directory in @($packageOutput, $expanded, $testDesktop, $testStartMenu)) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}
try {
    Add-Type -AssemblyName System.Drawing
    $imagePath = Join-Path $tempRoot 'hero.png'
    $bitmap = New-Object Drawing.Bitmap 1600, 760
    try { $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }

    & (Join-Path $workspace 'scripts\create-client-package.ps1') `
        -ClientId 'installed-lifecycle' `
        -ClientName 'Installed Lifecycle' `
        -HeroImage $imagePath `
        -Tagline 'Transactional lifecycle test' `
        -Signature 'TEST' `
        -ConfirmAssetRights `
        -OutputDirectory $packageOutput | Out-Null
    $zip = Get-ChildItem -LiteralPath $packageOutput -Filter '*.zip' -File | Select-Object -First 1
    if (-not $zip) { throw 'Lifecycle test did not produce a customer ZIP.' }
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded

    $script:CodexSkinForgeStateRootOverride = $testState
    $script:CodexSkinForgeDesktopOverride = $testDesktop
    $script:CodexSkinForgeStartMenuOverride = $testStartMenu
    $installScript = Join-Path $expanded 'scripts\install.ps1'
    . $installScript -PackageRoot $expanded | Out-Null

    foreach ($relative in @('engine\common.ps1', 'theme\theme.json', 'runtime\node.exe', 'install.json', 'uninstall.ps1')) {
        Assert-True (Test-Path -LiteralPath (Join-Path $testState $relative) -PathType Leaf) "Installed lifecycle path is missing: $relative"
    }
    $shortcuts = @(Get-ChildItem -LiteralPath $testDesktop -Filter '*.lnk' -File) +
        @(Get-ChildItem -LiteralPath $testStartMenu -Filter '*.lnk' -File)
    Assert-True ($shortcuts.Count -eq 3) 'Expected three isolated test shortcuts.'

    $marker = Join-Path $testState 'engine\rollback-marker.txt'
    [IO.File]::WriteAllText($marker, 'old')
    $installHashBefore = (Get-FileHash -LiteralPath (Join-Path $testState 'install.json') -Algorithm SHA256).Hash
    $runtimeHashBefore = (Get-FileHash -LiteralPath (Join-Path $testState 'runtime\node.exe') -Algorithm SHA256).Hash

    $script:CodexSkinForgeInstallFailPoint = 'after-copy'
    $rejected = $false
    try { . $installScript -PackageRoot $expanded | Out-Null } catch { $rejected = $true }
    Remove-Variable -Name CodexSkinForgeInstallFailPoint -Scope Script -ErrorAction SilentlyContinue
    Assert-True $rejected 'Simulated upgrade failure was not raised.'
    Assert-True ((Get-Content -LiteralPath $marker -Raw) -eq 'old') 'Failed upgrade did not restore the previous engine.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $testState 'install.json') -Algorithm SHA256).Hash -eq $installHashBefore) 'Failed upgrade did not restore install.json.'
    Assert-True ((Get-FileHash -LiteralPath (Join-Path $testState 'runtime\node.exe') -Algorithm SHA256).Hash -eq $runtimeHashBefore) 'Failed upgrade did not restore the copied runtime.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testState 'install-transaction.json'))) 'Failed upgrade leaked its transaction journal.'
    Assert-True (@(Get-ChildItem -LiteralPath $testState -Filter 'install-staging-*' -Directory -ErrorAction SilentlyContinue).Count -eq 0) 'Failed upgrade leaked a staging directory.'

    $interruptedBackup = Join-Path $testState 'backups\simulated-hard-interruption'
    [IO.Directory]::CreateDirectory($interruptedBackup) | Out-Null
    foreach ($relative in @('engine', 'theme', 'runtime', 'uninstall.ps1', 'install.json')) {
        [void](Move-ProductPathToBackup -RelativePath $relative -BackupRoot $interruptedBackup)
    }
    [IO.Directory]::CreateDirectory((Join-Path $testState 'engine')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $testState 'engine\rollback-marker.txt'), 'partial')
    Write-JsonFile -Path (Join-Path $testState 'install-transaction.json') -Value ([ordered]@{
        schemaVersion = 1
        phase = 'backed-up'
        backupRoot = $interruptedBackup
    })
    $script:CodexSkinForgeInstallFailPoint = 'after-backup'
    $interruptionRejected = $false
    try { . $installScript -PackageRoot $expanded | Out-Null } catch { $interruptionRejected = $true }
    Remove-Variable -Name CodexSkinForgeInstallFailPoint -Scope Script -ErrorAction SilentlyContinue
    Assert-True $interruptionRejected 'Post-recovery simulated failure was not raised.'
    Assert-True ((Get-Content -LiteralPath $marker -Raw) -eq 'old') 'Interrupted-install recovery did not restore the previous engine before retrying.'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $testState 'install-transaction.json'))) 'Interrupted-install recovery leaked its journal.'

    . (Join-Path $expanded 'scripts\uninstall.ps1') | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $testState)) 'Uninstall left the isolated product state root behind.'
    Assert-True (@(Get-ChildItem -LiteralPath $testDesktop -Filter '*.lnk' -File).Count -eq 0) 'Uninstall left desktop shortcuts behind.'
    Assert-True (@(Get-ChildItem -LiteralPath $testStartMenu -Filter '*.lnk' -File).Count -eq 0) 'Uninstall left Start Menu shortcuts behind.'

    Write-Output 'Installed package lifecycle and rollback tests passed.'
} finally {
    foreach ($name in @('CodexSkinForgeInstallFailPoint', 'CodexSkinForgeStateRootOverride', 'CodexSkinForgeDesktopOverride', 'CodexSkinForgeStartMenuOverride')) {
        Remove-Variable -Name $name -Scope Script -ErrorAction SilentlyContinue
    }
    $full = [IO.Path]::GetFullPath($tempRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
