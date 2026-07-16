[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..'),
    [switch]$SkipCodexCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')

function Assert-InsidePackage {
    param([string]$Path, [string]$Label)
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $PackageRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped the package root: $full"
    }
    return $full
}

if ($env:OS -ne 'Windows_NT') { throw 'This customer package supports Windows only.' }
foreach ($relative in @(
    'package-manifest.json', 'SHA256SUMS.txt', 'engine\common.ps1', 'engine\injector.mjs',
    'engine\start.ps1', 'engine\verify.ps1', 'engine\restore.ps1',
    'client\theme.json', 'client\noir-gold.css', 'client\renderer-inject.js'
)) {
    $path = Assert-InsidePackage (Join-Path $PackageRoot $relative) $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Package file is missing: $relative" }
}

$checksumPath = Join-Path $PackageRoot 'SHA256SUMS.txt'
$checksumLines = @(Get-Content -LiteralPath $checksumPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($checksumLines.Count -lt 8) { throw 'SHA256SUMS.txt is unexpectedly short.' }
foreach ($line in $checksumLines) {
    if ($line -notmatch '^([0-9a-f]{64})\s{2}(.+)$') { throw "Malformed checksum line: $line" }
    $expected = $matches[1]
    $relative = $matches[2].Replace('/', '\')
    $target = Assert-InsidePackage (Join-Path $PackageRoot $relative) 'checksum path'
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Checksum target is missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum mismatch: $relative" }
}

$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$theme = Get-Content -LiteralPath (Join-Path $PackageRoot 'client\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $theme.schemaVersion -ne 1) { throw 'Unsupported package or theme schema.' }
if ($theme.customizationRequired -ne $false) { throw 'The theme is still a template and cannot be installed.' }
if ([string]$theme.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') { throw 'The client theme id is invalid.' }

$serializedTheme = $theme | ConvertTo-Json -Depth 20
if ($serializedTheme -match 'CLIENT_(ID|NAME|TAGLINE|SIGNATURE)') { throw 'Unresolved client template tokens remain in theme.json.' }
$hero = Assert-InsidePackage (Join-Path (Join-Path $PackageRoot 'client') ([string]$theme.heroAsset)) 'hero asset'
if (-not (Test-Path -LiteralPath $hero -PathType Leaf)) { throw 'The customer hero image is missing.' }
if ([IO.Path]::GetExtension($hero).ToLowerInvariant() -notin @('.png', '.jpg', '.jpeg')) {
    throw 'The customer hero image must be PNG or JPEG.'
}
if ((Get-Item -LiteralPath $hero).Length -gt 16MB) { throw 'The customer hero image exceeds 16 MiB.' }
$image = $null
try {
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($hero)
    if ($image.Width -lt 1200 -or $image.Height -lt 600) { throw 'The customer hero image is below 1200x600.' }
    if ([int]$manifest.client.heroWidth -ne $image.Width -or [int]$manifest.client.heroHeight -ne $image.Height) {
        throw 'The customer hero dimensions do not match the package manifest.'
    }
} finally {
    if ($image) { $image.Dispose() }
}
$heroHash = (Get-FileHash -LiteralPath $hero -Algorithm SHA256).Hash.ToLowerInvariant()
if ($heroHash -ne ([string]$manifest.client.heroSha256).ToLowerInvariant()) { throw 'The customer hero hash does not match the manifest.' }
if ($manifest.client.assetRightsConfirmed -ne $true) { throw 'The package does not contain an affirmative customer asset-rights declaration.' }

$codexVersion = $null
$runtimeVersion = $null
if (-not $SkipCodexCheck) {
    $package = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending | Select-Object -First 1)
    if ($package.Count -eq 0) { throw 'Microsoft Store OpenAI Codex is not installed for this Windows user.' }
    $codexVersion = [string]$package[0].Version
    $nodeSource = Join-Path $package[0].InstallLocation 'app\resources\cua_node\bin\node.exe'
    if (-not (Test-Path -LiteralPath $nodeSource -PathType Leaf)) { throw 'This Codex version does not contain the expected bundled Node.js runtime.' }
    $signature = Get-AuthenticodeSignature -LiteralPath $nodeSource
    $signer = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
    if ($signature.Status -ne 'Valid' -or $signer -notmatch 'OpenJS Foundation') {
        throw 'The Node.js runtime bundled with Codex failed signature validation.'
    }
    $runtimeVersion = 'copied and version-checked during installation'
}

[ordered]@{
    status = 'ready'
    package = [string]$manifest.name
    version = [string]$manifest.version
    client = [string]$theme.name
    heroSha256 = $heroHash
    codexVersion = $codexVersion
    runtime = $runtimeVersion
    networkRequired = $false
    codexFilesModified = $false
} | ConvertTo-Json -Depth 10
