[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9]+(?:-[a-z0-9]+)*$')][string]$ClientId,
    [Parameter(Mandatory = $true)][ValidateNotNullOrEmpty()][string]$ClientName,
    [Parameter(Mandatory = $true)][ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })][string]$HeroImage,
    [string]$Tagline = '与你一起，用代码完成下一件作品',
    [string]$Signature = '',
    [string]$Badge = 'EXCLUSIVE',
    [string]$Version = '0.3.0',
    [string]$AssetSource = '客户提供或经客户确认的定制设计稿',
    [switch]$ConfirmAssetRights,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\release')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$buildRoot = Join-Path $workspace 'build'
$releaseRoot = [IO.Path]::GetFullPath($OutputDirectory)
$safeVersion = $Version -replace '[^0-9A-Za-z._-]', '-'
$packageName = "Codex-Noir-Gold-$ClientId-$safeVersion"
$staging = Join-Path $buildRoot $packageName
$zipPath = Join-Path $releaseRoot ($packageName + '.zip')
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Assert-Inside([string]$Path, [string]$Root, [string]$Label) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label escaped its intended root: $full"
    }
    return $full
}

function Assert-SingleLineText([string]$Value, [string]$Label, [int]$MaximumLength) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw "$Label cannot be blank." }
    if ($Value -match '[\r\n\x00-\x08\x0B\x0C\x0E-\x1F]') { throw "$Label must be a single printable line." }
    if ($Value.Length -gt $MaximumLength) { throw "$Label exceeds $MaximumLength characters." }
}

if (-not $ConfirmAssetRights) { throw 'Use -ConfirmAssetRights only after the customer confirms rights to the supplied or designed image.' }
if ([string]::IsNullOrWhiteSpace($Signature)) { $Signature = $ClientName }
Assert-SingleLineText $ClientName 'ClientName' 60
Assert-SingleLineText $Tagline 'Tagline' 100
Assert-SingleLineText $Signature 'Signature' 40
Assert-SingleLineText $Badge 'Badge' 24
Assert-SingleLineText $AssetSource 'AssetSource' 200
if ($Version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') { throw 'Version must use semantic version form such as 0.3.0.' }
$heroSource = (Resolve-Path -LiteralPath $HeroImage).Path
$extension = [IO.Path]::GetExtension($heroSource).ToLowerInvariant()
if ($extension -notin @('.png', '.jpg', '.jpeg')) { throw 'HeroImage must be a PNG or JPEG design.' }
$heroInfo = Get-Item -LiteralPath $heroSource
if ($heroInfo.Length -gt 16MB) { throw 'HeroImage exceeds the 16 MiB delivery limit.' }

Add-Type -AssemblyName System.Drawing
$image = [Drawing.Image]::FromFile($heroSource)
try {
    $width = $image.Width
    $height = $image.Height
} finally {
    $image.Dispose()
}
if ($width -lt 1200 -or $height -lt 600) {
    throw "HeroImage is ${width}x${height}; prepare a customer visual of at least 1200x600 (1600x760 recommended)."
}

[IO.Directory]::CreateDirectory($buildRoot) | Out-Null
[IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
Assert-Inside $staging $buildRoot 'staging path' | Out-Null
Assert-Inside $zipPath $releaseRoot 'release path' | Out-Null
if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
[IO.Directory]::CreateDirectory($staging) | Out-Null

try {
    foreach ($item in Get-ChildItem -LiteralPath (Join-Path $workspace 'delivery') -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination $staging -Recurse -Force
    }
    Copy-Item -LiteralPath (Join-Path $workspace 'engine') -Destination $staging -Recurse -Force
    $clientRoot = Join-Path $staging 'client'
    $assetRoot = Join-Path $clientRoot 'assets'
    [IO.Directory]::CreateDirectory($assetRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $workspace 'advanced\noir-gold\noir-gold.css') -Destination $clientRoot -Force
    Copy-Item -LiteralPath (Join-Path $workspace 'advanced\noir-gold\renderer-inject.js') -Destination $clientRoot -Force
    $heroFilename = 'customer-hero' + $extension
    $heroTarget = Join-Path $assetRoot $heroFilename
    Copy-Item -LiteralPath $heroSource -Destination $heroTarget -Force

    $theme = Get-Content -LiteralPath (Join-Path $workspace 'advanced\noir-gold\theme.template.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $theme.id = $ClientId
    $theme.name = "$ClientName 专属 Codex 皮肤"
    $theme.version = $Version
    $theme.customizationRequired = $false
    $theme.brandTitle = "$ClientName 专属定制皮肤"
    $theme.tagline = $Tagline
    $theme.signature = $Signature
    $theme.badge = $Badge
    $theme.heroAsset = "assets/$heroFilename"
    [IO.File]::WriteAllText((Join-Path $clientRoot 'theme.json'), ($theme | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8NoBom)

    $heroHash = (Get-FileHash -LiteralPath $heroTarget -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        schemaVersion = 1
        name = $theme.name
        version = $Version
        product = 'Codex Noir Gold Customer Skin'
        platform = 'windows'
        architecture = 'loopback-cdp-renderer-injection'
        client = [ordered]@{
            id = $ClientId
            name = $ClientName
            heroAsset = "client/assets/$heroFilename"
            heroSha256 = $heroHash
            heroWidth = $width
            heroHeight = $height
            assetSource = $AssetSource
            assetRightsConfirmed = $true
        }
        security = [ordered]@{
            networkDownloads = $false
            loopbackOnly = $true
            modifiesCodexFiles = $false
            copiesSignedRuntimeFromClientCodex = $true
        }
        builtAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    [IO.File]::WriteAllText((Join-Path $staging 'package-manifest.json'), ($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8NoBom)

    $declaration = @"
# 客户视觉素材声明

- 客户：$ClientName
- 主题 ID：$ClientId
- 素材来源：$AssetSource
- 主视觉尺寸：${width} × ${height}
- 主视觉 SHA-256：$heroHash
- 打包时已确认：客户对该图片拥有使用权，或已授权将定制设计稿用于本地 Codex 皮肤。

本包不包含通用占位人物图。更换主视觉后必须重新生成完整客户包，不能直接替换 ZIP 内文件。
"@
    [IO.File]::WriteAllText((Join-Path $staging 'ASSET_DECLARATION.md'), $declaration.Trim() + [Environment]::NewLine, $utf8NoBom)

    $unresolved = @(Get-ChildItem -LiteralPath $staging -Recurse -File | Where-Object { $_.Extension -in @('.json', '.js', '.css', '.md', '.txt', '.ps1', '.mjs') } | Select-String -Pattern 'CLIENT_(ID|NAME|TAGLINE|SIGNATURE)' -ErrorAction SilentlyContinue)
    if ($unresolved.Count -gt 0) { throw "Unresolved customer template token found in $($unresolved[0].Path)." }
    if (Test-Path -LiteralPath (Join-Path $staging 'client\assets\PLACE_CUSTOMER_HERO_HERE.txt')) {
        throw 'Placeholder instructions leaked into the customer package.'
    }

    $checksumLines = @(Get-ChildItem -LiteralPath $staging -Recurse -File |
        Where-Object { $_.Name -ne 'SHA256SUMS.txt' } |
        Sort-Object FullName |
        ForEach-Object {
            $relative = $_.FullName.Substring($staging.Length).TrimStart('\', '/').Replace('\', '/')
            $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            "$hash  $relative"
        })
    [IO.File]::WriteAllLines((Join-Path $staging 'SHA256SUMS.txt'), $checksumLines, $utf8NoBom)

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($zipPath + '.sha256', "$zipHash  $([IO.Path]::GetFileName($zipPath))$([Environment]::NewLine)", $utf8NoBom)
    Write-Output "BUILT: $zipPath"
    Write-Output "SHA256: $zipHash"
    Write-Output "CUSTOMER HERO: ${width}x${height} $heroHash"
} finally {
    if (Test-Path -LiteralPath $staging) {
        Assert-Inside $staging $buildRoot 'staging cleanup' | Out-Null
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
