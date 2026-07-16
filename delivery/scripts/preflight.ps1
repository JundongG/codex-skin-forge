[CmdletBinding()]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..'),
    [switch]$SkipCodexCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PackageRoot = [IO.Path]::GetFullPath($PackageRoot).TrimEnd('\', '/')
$maximumExpandedBytes = 32MB
$maximumHeroPixels = 40000000

function Assert-InsidePackage {
    param([string]$Path, [string]$Label)
    $full = [IO.Path]::GetFullPath($Path)
    $prefix = $PackageRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped the package root: $full"
    }
    return $full
}

function Get-PackageRelativePath([string]$Path) {
    return [IO.Path]::GetFullPath($Path).Substring($PackageRoot.Length).TrimStart('\', '/').Replace('\', '/')
}

function Assert-SafeText([object]$Value, [string]$Label, [int]$MaximumLength) {
    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text) -or $text.Length -gt $MaximumLength) {
        throw "$Label must be non-empty and at most $MaximumLength characters."
    }
    if ($text -match '[\x00-\x08\x0B\x0C\x0E-\x1F\u202A-\u202E\u2066-\u2069]') {
        throw "$Label contains disallowed control or bidirectional characters."
    }
}

if ($env:OS -ne 'Windows_NT') { throw 'This customer package supports Windows only.' }
if (-not (Test-Path -LiteralPath $PackageRoot -PathType Container)) { throw 'PackageRoot does not exist.' }

$requiredFiles = @(
    'LICENSE', 'NOTICE.md', 'ASSET_POLICY.md',
    'package-manifest.json', 'SHA256SUMS.txt',
    'engine\common.ps1', 'engine\injector.mjs', 'engine\start.ps1', 'engine\start-worker.ps1',
    'engine\verify.ps1', 'engine\restore.ps1', 'engine\diagnostics.ps1',
    'client\theme.json', 'client\noir-gold.css', 'client\renderer-inject.js',
    'scripts\preflight.ps1', 'scripts\install.ps1', 'scripts\start-assisted-install.ps1',
    'scripts\verify.ps1', 'scripts\diagnostics.ps1', 'scripts\uninstall.ps1'
)
foreach ($relative in $requiredFiles) {
    $path = Assert-InsidePackage (Join-Path $PackageRoot $relative) $relative
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Package file is missing: $relative" }
}

$allItems = @(Get-ChildItem -LiteralPath $PackageRoot -Recurse -Force)
$reparseItems = @($allItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
if ($reparseItems.Count -gt 0) { throw "Package contains a reparse point: $(Get-PackageRelativePath $reparseItems[0].FullName)" }
$allFiles = @($allItems | Where-Object { -not $_.PSIsContainer })
$expandedBytes = ($allFiles | Measure-Object -Property Length -Sum).Sum
if ($expandedBytes -gt $maximumExpandedBytes) { throw "Expanded package exceeds $maximumExpandedBytes bytes." }

$checksumPath = Join-Path $PackageRoot 'SHA256SUMS.txt'
$checksumLines = @(Get-Content -LiteralPath $checksumPath -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
if ($checksumLines.Count -lt 12) { throw 'SHA256SUMS.txt is unexpectedly short.' }
$listedFiles = @{}
foreach ($line in $checksumLines) {
    if ($line -notmatch '^([0-9a-f]{64})\s{2}(.+)$') { throw "Malformed checksum line: $line" }
    $expected = $matches[1]
    $relative = $matches[2].Replace('\', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative -eq 'SHA256SUMS.txt') {
        throw "Invalid checksum target: $relative"
    }
    if ($listedFiles.ContainsKey($relative)) { throw "Duplicate checksum target: $relative" }
    $target = Assert-InsidePackage (Join-Path $PackageRoot $relative.Replace('/', '\')) 'checksum path'
    if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { throw "Checksum target is missing: $relative" }
    $actual = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum mismatch: $relative" }
    $listedFiles[$relative] = $true
}

$actualRelativeFiles = @($allFiles |
    Where-Object { $_.FullName -ne $checksumPath } |
    ForEach-Object { Get-PackageRelativePath $_.FullName })
foreach ($relative in $actualRelativeFiles) {
    if (-not $listedFiles.ContainsKey($relative)) { throw "Package contains an unchecksummed file: $relative" }
}
foreach ($relative in $listedFiles.Keys) {
    if ($relative -notin $actualRelativeFiles) { throw "Checksum list contains a non-package file: $relative" }
}

$manifest = Get-Content -LiteralPath (Join-Path $PackageRoot 'package-manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$theme = Get-Content -LiteralPath (Join-Path $PackageRoot 'client\theme.json') -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $theme.schemaVersion -ne 1) { throw 'Unsupported package or theme schema.' }
if ([string]$manifest.product -ne 'Codex Skin Forge Customer Skin') { throw 'Unexpected package product identifier.' }
if ([string]$manifest.project -ne 'https://github.com/JundongG/codex-skin-forge' -or
    [string]$manifest.engineVersion -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
    throw 'Unexpected project identity or engine version.'
}
$commonSource = Get-Content -LiteralPath (Join-Path $PackageRoot 'engine\common.ps1') -Raw -Encoding UTF8
$expectedVersionAssignment = "`$script:ProductVersion = '$([string]$manifest.engineVersion)'"
if ($commonSource.IndexOf($expectedVersionAssignment, [StringComparison]::Ordinal) -lt 0) {
    throw 'Package engineVersion does not match engine/common.ps1.'
}
if ([string]$manifest.platform -ne 'windows' -or [string]$manifest.architecture -ne 'loopback-cdp-renderer-injection') {
    throw 'Unexpected package platform or architecture.'
}
if ($manifest.security.networkDownloads -ne $false -or
    $manifest.security.loopbackOnly -ne $true -or
    $manifest.security.modifiesCodexFiles -ne $false -or
    $manifest.security.copiesSignedRuntimeFromClientCodex -ne $true) {
    throw 'Package security declarations do not match the supported installation model.'
}
if ($theme.customizationRequired -ne $false) { throw 'The theme is still a template and cannot be installed.' }
if ([string]$theme.id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$' -or ([string]$theme.id).Length -gt 64) {
    throw 'The client theme id is invalid.'
}
foreach ($field in @(
    @{ Name = 'name'; Maximum = 100 },
    @{ Name = 'brandTitle'; Maximum = 100 },
    @{ Name = 'brandSubtitle'; Maximum = 100 },
    @{ Name = 'headline'; Maximum = 100 },
    @{ Name = 'tagline'; Maximum = 100 },
    @{ Name = 'signature'; Maximum = 40 },
    @{ Name = 'badge'; Maximum = 24 }
)) {
    Assert-SafeText $theme.($field.Name) "theme.$($field.Name)" $field.Maximum
}
if ([string]$manifest.client.id -ne [string]$theme.id -or
    [string]$manifest.version -ne [string]$theme.version) {
    throw 'Package manifest and customer theme identity do not match.'
}
Assert-SafeText $manifest.client.name 'manifest.client.name' 60

$serializedTheme = $theme | ConvertTo-Json -Depth 20
if ($serializedTheme -match 'CLIENT_(ID|NAME|TAGLINE|SIGNATURE)') { throw 'Unresolved client template tokens remain in theme.json.' }
if ([string]::IsNullOrWhiteSpace([string]$theme.heroAsset) -or [IO.Path]::IsPathRooted([string]$theme.heroAsset)) {
    throw 'theme.heroAsset must be a relative path.'
}
$hero = Assert-InsidePackage (Join-Path (Join-Path $PackageRoot 'client') ([string]$theme.heroAsset)) 'hero asset'
if (-not (Test-Path -LiteralPath $hero -PathType Leaf)) { throw 'The customer hero image is missing.' }
if ([IO.Path]::GetExtension($hero).ToLowerInvariant() -notin @('.png', '.jpg', '.jpeg')) {
    throw 'The customer hero image must be PNG or JPEG.'
}
if ((Get-Item -LiteralPath $hero).Length -gt 16MB) { throw 'The customer hero image exceeds 16 MiB.' }
$expectedManifestHero = 'client/' + ([string]$theme.heroAsset).Replace('\', '/')
if ([string]$manifest.client.heroAsset -ne $expectedManifestHero) { throw 'Manifest hero path does not match theme.heroAsset.' }

$image = $null
try {
    Add-Type -AssemblyName System.Drawing
    $image = [Drawing.Image]::FromFile($hero)
    $expectedFormat = if ([IO.Path]::GetExtension($hero).ToLowerInvariant() -eq '.png') {
        [Drawing.Imaging.ImageFormat]::Png.Guid
    } else {
        [Drawing.Imaging.ImageFormat]::Jpeg.Guid
    }
    if ($image.RawFormat.Guid -ne $expectedFormat) { throw 'The customer hero content does not match its file extension.' }
    $pixelCount = [long]$image.Width * [long]$image.Height
    if ($image.Width -lt 1200 -or $image.Height -lt 600) { throw 'The customer hero image is below 1200x600.' }
    if ($image.Width -gt 8192 -or $image.Height -gt 8192 -or $pixelCount -gt $maximumHeroPixels) {
        throw 'The customer hero image exceeds the safe dimensions or pixel-count limit.'
    }
    if ([int]$manifest.client.heroWidth -ne $image.Width -or [int]$manifest.client.heroHeight -ne $image.Height) {
        throw 'The customer hero dimensions do not match the package manifest.'
    }
} finally {
    if ($image) { $image.Dispose() }
}
$heroHash = (Get-FileHash -LiteralPath $hero -Algorithm SHA256).Hash.ToLowerInvariant()
if ($heroHash -ne ([string]$manifest.client.heroSha256).ToLowerInvariant()) { throw 'The customer hero hash does not match the manifest.' }
if ($manifest.client.assetRightsConfirmed -ne $true) { throw 'The package does not contain an affirmative customer asset-rights declaration.' }
Assert-SafeText $manifest.client.assetSource 'manifest.client.assetSource' 200

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
    filesVerified = $listedFiles.Count
    expandedBytes = $expandedBytes
    heroSha256 = $heroHash
    codexVersion = $codexVersion
    runtime = $runtimeVersion
    networkRequired = $false
    codexFilesModified = $false
} | ConvertTo-Json -Depth 10
