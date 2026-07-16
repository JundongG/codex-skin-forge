[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ZipPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-noir-gold-release-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $testRoot -Force
    foreach ($relative in @(
        'LICENSE', 'NOTICE.md', 'ASSET_POLICY.md',
        'START_HERE.md', 'INSTALL_PROMPT.txt', 'VERIFY_PROMPT.txt', 'ASSET_DECLARATION.md',
        'package-manifest.json', 'SHA256SUMS.txt', 'scripts\preflight.ps1',
        'scripts\install.ps1', 'scripts\start-assisted-install.ps1', 'scripts\verify.ps1',
        'scripts\diagnostics.ps1', 'scripts\uninstall.ps1',
        'engine\common.ps1', 'engine\injector.mjs', 'engine\start.ps1',
        'engine\start-worker.ps1', 'engine\verify.ps1', 'engine\restore.ps1',
        'engine\diagnostics.ps1', 'client\theme.json', 'client\noir-gold.css',
        'client\renderer-inject.js'
    )) {
        if (-not (Test-Path -LiteralPath (Join-Path $testRoot $relative))) { throw "Release is missing: $relative" }
    }
    if (Test-Path -LiteralPath (Join-Path $testRoot 'third_party')) { throw 'Customer release unexpectedly contains third-party runtime source.' }
    $theme = Get-Content -LiteralPath (Join-Path $testRoot 'client\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($theme.customizationRequired -ne $false) { throw 'Packaged theme is not customized.' }
    if (($theme | ConvertTo-Json -Depth 20) -match 'CLIENT_(ID|NAME|TAGLINE|SIGNATURE)') { throw 'Packaged theme contains template tokens.' }
    $hero = Join-Path (Join-Path $testRoot 'client') ([string]$theme.heroAsset)
    if (-not (Test-Path -LiteralPath $hero -PathType Leaf)) { throw 'Packaged customer hero image is missing.' }
    & (Join-Path $testRoot 'scripts\preflight.ps1') -PackageRoot $testRoot -SkipCodexCheck | Out-Null
    $node = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
    if ($node) {
        & $node (Join-Path $testRoot 'engine\injector.mjs') --validate-theme --theme-root (Join-Path $testRoot 'client') | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Packaged renderer payload validation failed.' }
    }
    Write-Output "Release verification passed: $ZipPath"
} finally {
    $full = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
