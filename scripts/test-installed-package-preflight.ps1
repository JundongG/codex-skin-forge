[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-skin-installed-preflight-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    Add-Type -AssemblyName System.Drawing
    $imagePath = Join-Path $tempRoot 'hero.png'
    $bitmap = New-Object Drawing.Bitmap 1600, 760
    try { $bitmap.Save($imagePath, [Drawing.Imaging.ImageFormat]::Png) } finally { $bitmap.Dispose() }

    & (Join-Path $workspace 'scripts\create-client-package.ps1') `
        -ClientId 'installed-preflight' `
        -ClientName 'Installed Preflight' `
        -HeroImage $imagePath `
        -Tagline 'Local compatibility test' `
        -Signature 'TEST' `
        -ConfirmAssetRights `
        -OutputDirectory $tempRoot | Out-Null
    $zip = Get-ChildItem -LiteralPath $tempRoot -Filter '*.zip' -File | Select-Object -First 1
    if (-not $zip) { throw 'Installed preflight test did not produce a ZIP.' }
    $expanded = Join-Path $tempRoot 'expanded'
    Expand-Archive -LiteralPath $zip.FullName -DestinationPath $expanded
    & (Join-Path $expanded 'scripts\preflight.ps1') -PackageRoot $expanded
    Write-Output 'Installed Codex package preflight passed.'
} finally {
    $full = [IO.Path]::GetFullPath($tempRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
