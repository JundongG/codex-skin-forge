[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$template = Get-Content -LiteralPath (Join-Path $workspace 'advanced\noir-gold\theme.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
Assert-True ($template.customizationRequired -eq $true) 'Source theme must remain an unshippable customer template.'
Assert-True ([string]$template.heroAsset -eq 'assets/customer-hero.png') 'Unexpected template hero path.'

$renderer = Get-Content -LiteralPath (Join-Path $workspace 'advanced\noir-gold\renderer-inject.js') -Raw -Encoding UTF8
$css = Get-Content -LiteralPath (Join-Path $workspace 'advanced\noir-gold\noir-gold.css') -Raw -Encoding UTF8
$injector = Get-Content -LiteralPath (Join-Path $workspace 'engine\injector.mjs') -Raw -Encoding UTF8
$startWorker = Get-Content -LiteralPath (Join-Path $workspace 'engine\start-worker.ps1') -Raw -Encoding UTF8
Assert-True ($renderer -match '__NOIR_HERO_JSON__') 'Renderer template must receive the packaged customer image.'
Assert-True ($css -match 'pointer-events:\s*none') 'Decorative layer must not intercept user input.'
Assert-True ($injector -match 'http://127\.0\.0\.1:') 'CDP discovery must use explicit loopback.'
Assert-True ($injector -match 'target\.url\.startsWith\("app://"\)') 'Injector must target only Codex app pages.'
Assert-True ($startWorker -match '--remote-debugging-address=127\.0\.0\.1') 'Codex debugging must bind to loopback.'
Assert-True ($startWorker -notmatch 'Stop-Process.+ChatGPT|taskkill') 'The themed launcher must not force-close Codex.'

$forbiddenInstallerPatterns = @('Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'irm\s*\|', 'curl\s+.+\|')
$installSources = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'delivery\scripts') -Filter '*.ps1' -File) + @(Get-Item -LiteralPath (Join-Path $workspace 'scripts\create-client-package.ps1'))
foreach ($sourceFile in $installSources) {
    $source = Get-Content -LiteralPath $sourceFile.FullName -Raw -Encoding UTF8
    foreach ($pattern in $forbiddenInstallerPatterns) {
        Assert-True ($source -notmatch $pattern) "Network installer primitive found in $($sourceFile.Name): $pattern"
    }
}

$scriptFiles = @(Get-ChildItem -LiteralPath (Join-Path $workspace 'delivery\scripts') -Filter '*.ps1' -File)
$scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $workspace 'engine') -Filter '*.ps1' -File)
$scriptFiles += @(Get-ChildItem -LiteralPath (Join-Path $workspace 'scripts') -Filter '*.ps1' -File)
foreach ($scriptFile in $scriptFiles) {
    $tokens = $null
    $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($scriptFile.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        $details = ($errors | ForEach-Object { $_.Message }) -join '; '
        throw "PowerShell syntax error in $($scriptFile.FullName): $details"
    }
}

$nodeCandidates = @(
    (Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
    (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold\runtime\node.exe')
) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
if ($nodeCandidates) {
    & $nodeCandidates --check (Join-Path $workspace 'engine\injector.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'node --check failed for engine/injector.mjs.' }
    & $nodeCandidates --check (Join-Path $workspace 'advanced\noir-gold\renderer-inject.js')
    if ($LASTEXITCODE -ne 0) { throw 'node --check failed for renderer-inject.js.' }
} else {
    Write-Warning 'Node.js was not available for JavaScript syntax checks; package preflight will copy Codex bundled Node on the client.'
}

Write-Output 'Advanced customer-skin source checks passed.'
