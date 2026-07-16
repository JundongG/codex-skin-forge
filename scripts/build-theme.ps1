[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ThemePath,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$validCodeThemeIds = @(
    'absolutely', 'ayu', 'catppuccin', 'codex', 'dracula', 'everforest',
    'github', 'gruvbox', 'linear', 'lobster', 'material', 'matrix',
    'monokai', 'night-owl', 'nord', 'notion', 'oscurange', 'one',
    'proof', 'raycast', 'rose-pine', 'sentry', 'solarized', 'temple',
    'tokyo-night', 'vercel', 'vscode-plus', 'xcode'
)

function Get-RequiredProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Context
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        throw "$Context 缺少必需字段 '$Name'。"
    }

    return $property.Value
}

function Assert-HexColor {
    param([object]$Value, [string]$Context)

    if ($Value -isnot [string] -or $Value -notmatch '^#[0-9A-Fa-f]{6}$') {
        throw "$Context 必须是 #RRGGBB 颜色。"
    }
}

function Assert-NullableFont {
    param([object]$Value, [string]$Context)

    if ($null -ne $Value -and ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value))) {
        throw "$Context 必须是非空字符串或 null。"
    }
}

$resolvedThemePath = (Resolve-Path -LiteralPath $ThemePath).Path
$manifest = Get-Content -LiteralPath $resolvedThemePath -Raw -Encoding UTF8 | ConvertFrom-Json

$schemaVersion = Get-RequiredProperty $manifest 'schemaVersion' '主题清单'
$id = [string](Get-RequiredProperty $manifest 'id' '主题清单')
$name = [string](Get-RequiredProperty $manifest 'name' '主题清单')
$version = [string](Get-RequiredProperty $manifest 'version' '主题清单')
$variants = Get-RequiredProperty $manifest 'variants' '主题清单'

if ($schemaVersion -ne 1) {
    throw "不支持 schemaVersion '$schemaVersion'。"
}
if ($id -notmatch '^[a-z0-9]+(?:-[a-z0-9]+)*$') {
    throw "主题 id '$id' 必须使用 kebab-case。"
}
if ([string]::IsNullOrWhiteSpace($name) -or [string]::IsNullOrWhiteSpace($version)) {
    throw '主题 name 和 version 不能为空。'
}

$variantProperties = @($variants.PSObject.Properties)
if ($variantProperties.Count -eq 0) {
    throw '主题至少要包含 light 或 dark 变体。'
}

$resolvedOutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
[IO.Directory]::CreateDirectory($resolvedOutputDirectory) | Out-Null
$utf8NoBom = New-Object Text.UTF8Encoding($false)
$records = @()

foreach ($variantProperty in $variantProperties) {
    $variantName = $variantProperty.Name.ToLowerInvariant()
    if ($variantName -notin @('light', 'dark')) {
        throw "不支持主题变体 '$variantName'。"
    }

    $variant = $variantProperty.Value
    $codeThemeId = [string](Get-RequiredProperty $variant 'codeThemeId' "$variantName 变体")
    $theme = Get-RequiredProperty $variant 'theme' "$variantName 变体"

    if ($codeThemeId -notin $validCodeThemeIds) {
        throw "$variantName.codeThemeId '$codeThemeId' 不是当前已知的 Codex 代码主题。"
    }

    $accent = Get-RequiredProperty $theme 'accent' "$variantName.theme"
    $contrast = Get-RequiredProperty $theme 'contrast' "$variantName.theme"
    $fonts = Get-RequiredProperty $theme 'fonts' "$variantName.theme"
    $ink = Get-RequiredProperty $theme 'ink' "$variantName.theme"
    $opaqueWindows = Get-RequiredProperty $theme 'opaqueWindows' "$variantName.theme"
    $semanticColors = Get-RequiredProperty $theme 'semanticColors' "$variantName.theme"
    $surface = Get-RequiredProperty $theme 'surface' "$variantName.theme"

    $codeFont = Get-RequiredProperty $fonts 'code' "$variantName.theme.fonts"
    $uiFont = Get-RequiredProperty $fonts 'ui' "$variantName.theme.fonts"
    $diffAdded = Get-RequiredProperty $semanticColors 'diffAdded' "$variantName.theme.semanticColors"
    $diffRemoved = Get-RequiredProperty $semanticColors 'diffRemoved' "$variantName.theme.semanticColors"
    $skill = Get-RequiredProperty $semanticColors 'skill' "$variantName.theme.semanticColors"

    foreach ($color in @(
        @{ Value = $accent; Context = "$variantName.theme.accent" },
        @{ Value = $ink; Context = "$variantName.theme.ink" },
        @{ Value = $surface; Context = "$variantName.theme.surface" },
        @{ Value = $diffAdded; Context = "$variantName.theme.semanticColors.diffAdded" },
        @{ Value = $diffRemoved; Context = "$variantName.theme.semanticColors.diffRemoved" },
        @{ Value = $skill; Context = "$variantName.theme.semanticColors.skill" }
    )) {
        Assert-HexColor $color.Value $color.Context
    }

    $contrastValue = 0
    if (-not [int]::TryParse([string]$contrast, [ref]$contrastValue) -or $contrastValue -lt 0 -or $contrastValue -gt 100) {
        throw "$variantName.theme.contrast 必须是 0 到 100 的整数。"
    }
    if ($opaqueWindows -isnot [bool]) {
        throw "$variantName.theme.opaqueWindows 必须是布尔值。"
    }
    Assert-NullableFont $codeFont "$variantName.theme.fonts.code"
    Assert-NullableFont $uiFont "$variantName.theme.fonts.ui"

    $payload = [ordered]@{
        codeThemeId = $codeThemeId
        theme = [ordered]@{
            accent = ([string]$accent).ToUpperInvariant()
            contrast = $contrastValue
            fonts = [ordered]@{
                code = $codeFont
                ui = $uiFont
            }
            ink = ([string]$ink).ToUpperInvariant()
            opaqueWindows = [bool]$opaqueWindows
            semanticColors = [ordered]@{
                diffAdded = ([string]$diffAdded).ToUpperInvariant()
                diffRemoved = ([string]$diffRemoved).ToUpperInvariant()
                skill = ([string]$skill).ToUpperInvariant()
            }
            surface = ([string]$surface).ToUpperInvariant()
        }
        variant = $variantName
    }

    $shareString = 'codex-theme-v1:' + ($payload | ConvertTo-Json -Compress -Depth 10)
    $outputFile = Join-Path $resolvedOutputDirectory "$id-$variantName.codex-theme.txt"
    [IO.File]::WriteAllText($outputFile, $shareString + [Environment]::NewLine, $utf8NoBom)

    $records += [ordered]@{
        file = [IO.Path]::GetFileName($outputFile)
        sha256 = (Get-FileHash -LiteralPath $outputFile -Algorithm SHA256).Hash.ToLowerInvariant()
        variant = $variantName
    }

    Write-Output "Built $outputFile"
}

$buildManifest = [ordered]@{
    id = $id
    name = $name
    version = $version
    source = [IO.Path]::GetFileName($resolvedThemePath)
    format = 'codex-theme-v1'
    files = $records
}

$buildManifestPath = Join-Path $resolvedOutputDirectory "$id.build.json"
[IO.File]::WriteAllText(
    $buildManifestPath,
    ($buildManifest | ConvertTo-Json -Depth 10) + [Environment]::NewLine,
    $utf8NoBom
)
Write-Output "Built $buildManifestPath"
