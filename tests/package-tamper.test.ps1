[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ZipPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ZipPath = (Resolve-Path -LiteralPath $ZipPath).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-skin-tamper-test-' + [guid]::NewGuid().ToString('N'))
$utf8NoBom = New-Object Text.UTF8Encoding($false)

function Expand-Case([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $root -Force
    return $root
}

function Assert-PreflightRejected([string]$Root, [string]$Label) {
    $rejected = $false
    try {
        & (Join-Path $Root 'scripts\preflight.ps1') -PackageRoot $Root -SkipCodexCheck | Out-Null
    } catch {
        $rejected = $true
    }
    if (-not $rejected) { throw "Preflight accepted tampered package case: $Label" }
}

function Set-TestChecksum {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param([string]$Root, [string]$RelativePath)
    $checksumPath = Join-Path $Root 'SHA256SUMS.txt'
    $normalized = $RelativePath.Replace('\', '/')
    $target = Join-Path $Root $RelativePath
    $hash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant()
    $lines = @(Get-Content -LiteralPath $checksumPath -Encoding UTF8 | ForEach-Object {
        if ($_ -match '^[0-9a-f]{64}\s{2}(.+)$' -and $matches[1] -eq $normalized) {
            "$hash  $normalized"
        } else {
            $_
        }
    })
    if ($PSCmdlet.ShouldProcess($checksumPath, 'Update tamper-test checksum')) {
        [IO.File]::WriteAllLines($checksumPath, $lines, $utf8NoBom)
    }
}

[IO.Directory]::CreateDirectory($testRoot) | Out-Null
try {
    $extra = Expand-Case 'extra-file'
    [IO.File]::WriteAllText((Join-Path $extra 'UNTRACKED.txt'), 'not checksummed', $utf8NoBom)
    Assert-PreflightRejected $extra 'unchecksummed extra file'

    $duplicate = Expand-Case 'duplicate-checksum'
    $checksumPath = Join-Path $duplicate 'SHA256SUMS.txt'
    $first = Get-Content -LiteralPath $checksumPath -Encoding UTF8 | Select-Object -First 1
    [IO.File]::AppendAllText($checksumPath, $first + [Environment]::NewLine, $utf8NoBom)
    Assert-PreflightRejected $duplicate 'duplicate checksum target'

    $security = Expand-Case 'security-declaration'
    $manifestPath = Join-Path $security 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.security.loopbackOnly = $false
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8NoBom)
    Set-TestChecksum $security 'package-manifest.json'
    Assert-PreflightRejected $security 'weakened security declaration'

    $engineVersion = Expand-Case 'engine-version'
    $manifestPath = Join-Path $engineVersion 'package-manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest.engineVersion = '9.9.9'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, $utf8NoBom)
    Set-TestChecksum $engineVersion 'package-manifest.json'
    Assert-PreflightRejected $engineVersion 'engine version mismatch'

    $missing = Expand-Case 'missing-required'
    Remove-Item -LiteralPath (Join-Path $missing 'NOTICE.md') -Force
    $lines = @(Get-Content -LiteralPath (Join-Path $missing 'SHA256SUMS.txt') -Encoding UTF8 | Where-Object { $_ -notmatch '\s{2}NOTICE\.md$' })
    [IO.File]::WriteAllLines((Join-Path $missing 'SHA256SUMS.txt'), $lines, $utf8NoBom)
    Assert-PreflightRejected $missing 'missing required notice'

    Write-Output 'Package tamper tests passed.'
} finally {
    $full = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
