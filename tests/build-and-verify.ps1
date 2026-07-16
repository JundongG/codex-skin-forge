[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-noir-gold-build-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Add-Type -AssemblyName System.Drawing
    $imagePath = Join-Path $tempRoot 'fixture.png'
    $bitmap = New-Object Drawing.Bitmap 1600, 760
    try {
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        try {
            $graphics.Clear([Drawing.Color]::FromArgb(11, 13, 14))
            $brush = New-Object Drawing.SolidBrush ([Drawing.Color]::FromArgb(200, 155, 91))
            try { $graphics.FillEllipse($brush, 980, 80, 480, 600) } finally { $brush.Dispose() }
        } finally { $graphics.Dispose() }
        $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png)
    } finally { $bitmap.Dispose() }

    & (Join-Path $workspace 'scripts\test-advanced.ps1')
    if (Get-Module -ListAvailable PSScriptAnalyzer) {
        & (Join-Path $workspace 'scripts\test-powershell-analysis.ps1')
    } else {
        Write-Warning 'PSScriptAnalyzer is not installed; CI installs the pinned analyzer before this test.'
    }
    & (Join-Path $workspace 'tests\common-lifecycle.test.ps1')

    $rightsRejected = $false
    try {
        & (Join-Path $workspace 'scripts\create-client-package.ps1') `
            -ClientId 'must-fail-rights' `
            -ClientName '未确认授权' `
            -HeroImage $imagePath `
            -OutputDirectory $tempRoot | Out-Null
    } catch { $rightsRejected = $true }
    if (-not $rightsRejected) { throw 'Packager accepted a customer image without asset-rights confirmation.' }

    $smallImagePath = Join-Path $tempRoot 'too-small.png'
    $smallBitmap = New-Object Drawing.Bitmap 800, 400
    try { $smallBitmap.Save($smallImagePath, [Drawing.Imaging.ImageFormat]::Png) } finally { $smallBitmap.Dispose() }
    $smallRejected = $false
    try {
        & (Join-Path $workspace 'scripts\create-client-package.ps1') `
            -ClientId 'must-fail-size' `
            -ClientName '低分辨率测试' `
            -HeroImage $smallImagePath `
            -ConfirmAssetRights `
            -OutputDirectory $tempRoot | Out-Null
    } catch { $smallRejected = $true }
    if (-not $smallRejected) { throw 'Packager accepted a customer image below 1200x600.' }

    $fakeJpeg = Join-Path $tempRoot 'fake.jpg'
    Copy-Item -LiteralPath $imagePath -Destination $fakeJpeg
    $formatRejected = $false
    try {
        & (Join-Path $workspace 'scripts\create-client-package.ps1') `
            -ClientId 'must-fail-format' `
            -ClientName '格式伪装测试' `
            -HeroImage $fakeJpeg `
            -ConfirmAssetRights `
            -OutputDirectory $tempRoot | Out-Null
    } catch { $formatRejected = $true }
    if (-not $formatRejected) { throw 'Packager accepted PNG content with a JPEG extension.' }

    & (Join-Path $workspace 'scripts\create-client-package.ps1') `
        -ClientId 'automated-test' `
        -ClientName '自动化测试客户' `
        -HeroImage $imagePath `
        -Tagline '这是测试视觉，不进入正式客户交付' `
        -Signature 'TEST' `
        -ConfirmAssetRights `
        -OutputDirectory $tempRoot | Out-Null
    $zip = Get-ChildItem -LiteralPath $tempRoot -Filter '*.zip' -File | Select-Object -First 1
    if (-not $zip) { throw 'Build test did not produce a ZIP.' }
    & (Join-Path $workspace 'scripts\test-release.ps1') -ZipPath $zip.FullName
    & (Join-Path $workspace 'tests\package-tamper.test.ps1') -ZipPath $zip.FullName
    Write-Output 'End-to-end build and package verification passed.'
} finally {
    $full = [IO.Path]::GetFullPath($tempRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
