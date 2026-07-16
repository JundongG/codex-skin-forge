[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$package = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $package) { throw 'Microsoft Store OpenAI Codex is not installed.' }
$asar = Join-Path $package.InstallLocation 'app\resources\app.asar'
if (-not (Test-Path -LiteralPath $asar -PathType Leaf)) { throw "app.asar was not found: $asar" }
$rg = Get-Command rg.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source
if (-not $rg) {
    $rg = Join-Path $package.InstallLocation 'app\resources\rg.exe'
}
if (-not (Test-Path -LiteralPath $rg -PathType Leaf)) { throw 'ripgrep is required for the installed compatibility audit.' }

$selectors = @(
    'app-shell-left-panel',
    'main-surface',
    'composer-surface-chrome',
    'home-suggestions',
    'home-icon',
    'data-feature="game-source"'
)
$results = @()
foreach ($selector in $selectors) {
    & $rg -a -q --fixed-strings $selector $asar
    $present = ($LASTEXITCODE -eq 0)
    $results += [ordered]@{ selector = $selector; present = $present }
}
$missing = @($results | Where-Object { -not $_.present })
$report = [ordered]@{
    codexVersion = [string]$package.Version
    appAsar = $asar
    compatible = ($missing.Count -eq 0)
    selectors = $results
}
$report | ConvertTo-Json -Depth 10
if ($missing.Count -gt 0) {
    throw "Installed Codex is missing required selectors: $(($missing.selector) -join ', ')"
}
