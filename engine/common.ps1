Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProductId = 'codex-noir-gold'
$script:ProductVersion = '0.3.0'
$script:StateRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold'
$script:EngineRoot = Join-Path $script:StateRoot 'engine'
$script:ThemeRoot = Join-Path $script:StateRoot 'theme'
$script:RuntimeRoot = Join-Path $script:StateRoot 'runtime'
$script:NodePath = Join-Path $script:RuntimeRoot 'node.exe'
$script:StatePath = Join-Path $script:StateRoot 'state.json'
$script:ResultPath = Join-Path $script:StateRoot 'latest-result.json'

function Get-Utf8NoBom {
    return New-Object Text.UTF8Encoding($false)
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    $parent = Split-Path -Parent $Path
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($Path),
        ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine,
        (Get-Utf8NoBom)
    )
}

function Assert-PathWithin {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Root,
        [string]$Label = 'path'
    )
    $fullPath = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/')
    $fullRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $prefix = $fullRoot + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Label must stay inside '$fullRoot'; resolved '$fullPath'."
    }
    return $fullPath
}

function Get-CodexAppPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    if ($packages.Count -eq 0) { return $null }
    return $packages[0]
}

function Get-CodexExecutable {
    $package = Get-CodexAppPackage
    if (-not $package) { throw 'The Microsoft Store OpenAI.Codex package is not installed.' }
    $path = Join-Path $package.InstallLocation 'app\ChatGPT.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Codex executable not found: $path"
    }
    return $path
}

function Get-BundledNodeSource {
    $package = Get-CodexAppPackage
    if (-not $package) { throw 'The Microsoft Store OpenAI.Codex package is not installed.' }
    $path = Join-Path $package.InstallLocation 'app\resources\cua_node\bin\node.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "The Codex-bundled Node.js runtime was not found: $path"
    }
    return $path
}

function Install-BundledNodeRuntime {
    [IO.Directory]::CreateDirectory($script:RuntimeRoot) | Out-Null
    $source = Get-BundledNodeSource
    $staging = Join-Path $script:RuntimeRoot ('node.staging-' + [guid]::NewGuid().ToString('N') + '.exe')
    Assert-PathWithin -Path $staging -Root $script:RuntimeRoot -Label 'Node staging path' | Out-Null
    try {
        Copy-Item -LiteralPath $source -Destination $staging -Force
        $signature = Get-AuthenticodeSignature -LiteralPath $staging
        $signer = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        if ($signature.Status -ne 'Valid' -or $signer -notmatch 'OpenJS Foundation') {
            throw "Copied Node.js runtime failed signature validation: $($signature.Status) $signer"
        }
        $version = (& $staging --version).Trim()
        $major = 0
        if (-not [int]::TryParse(($version.TrimStart('v') -split '\.')[0], [ref]$major) -or $major -lt 22) {
            throw "Node.js 22+ is required; Codex bundled $version."
        }
        Move-Item -LiteralPath $staging -Destination $script:NodePath -Force
        return [ordered]@{
            path = $script:NodePath
            version = $version
            signer = $signer
            sha256 = (Get-FileHash -LiteralPath $script:NodePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } finally {
        if (Test-Path -LiteralPath $staging) {
            Assert-PathWithin -Path $staging -Root $script:RuntimeRoot -Label 'Node staging cleanup' | Out-Null
            Remove-Item -LiteralPath $staging -Force
        }
    }
}

function Get-NodeRuntimeStatus {
    if (-not (Test-Path -LiteralPath $script:NodePath -PathType Leaf)) {
        return [ordered]@{ ok = $false; path = $script:NodePath; version = $null; signer = $null }
    }
    try {
        $signature = Get-AuthenticodeSignature -LiteralPath $script:NodePath
        $version = (& $script:NodePath --version).Trim()
        $major = 0
        [void][int]::TryParse(($version.TrimStart('v') -split '\.')[0], [ref]$major)
        $signer = if ($signature.SignerCertificate) { [string]$signature.SignerCertificate.Subject } else { '' }
        return [ordered]@{
            ok = ($signature.Status -eq 'Valid' -and $signer -match 'OpenJS Foundation' -and $major -ge 22)
            path = $script:NodePath
            version = $version
            signer = $signer
        }
    } catch {
        return [ordered]@{ ok = $false; path = $script:NodePath; version = $null; signer = $null; error = $_.Exception.Message }
    }
}

function Get-CodexProcesses {
    $candidates = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -in @('ChatGPT.exe', 'Codex.exe') })
    $matched = @($candidates | Where-Object {
        $path = [string]$_.ExecutablePath
        $command = [string]$_.CommandLine
        $path -match '\\WindowsApps\\OpenAI\.Codex_' -or
        $command -match '\\WindowsApps\\OpenAI\.Codex_'
    })
    if ($matched.Count -gt 0) { return $matched }
    return @($candidates | Where-Object {
        [string]::IsNullOrWhiteSpace([string]$_.ExecutablePath) -and
        [string]::IsNullOrWhiteSpace([string]$_.CommandLine)
    })
}

function Wait-CodexExit {
    param([ValidateRange(30, 3600)][int]$TimeoutSeconds = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (@(Get-CodexProcesses).Count -gt 0) {
        if ((Get-Date) -ge $deadline) {
            throw 'Timed out waiting for Codex to close. No themed launch was attempted.'
        }
        Start-Sleep -Seconds 2
    }
}

function Get-FreeLoopbackPort {
    $listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return ([Net.IPEndPoint]$listener.LocalEndpoint).Port
    } finally {
        $listener.Stop()
    }
}

function Test-CodexDebugPort {
    param([Parameter(Mandatory = $true)][int]$Port)
    try {
        $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 1
        return [bool]($targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' })
    } catch {
        return $false
    }
}

function Get-InstalledState {
    if (-not (Test-Path -LiteralPath $script:StatePath -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Stop-RecordedInjector {
    $state = Get-InstalledState
    if (-not $state -or -not $state.injectorPid) { return $false }
    $pidValue = [int]$state.injectorPid
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if (-not $process) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) {
        throw "Refusing to stop PID $pidValue because its executable path could not be verified."
    }
    $actualPath = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
    $expectedPath = [IO.Path]::GetFullPath($script:NodePath)
    if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to stop PID $pidValue because it is not the installed Noir Gold Node runtime."
    }
    Stop-Process -Id $pidValue -Force
    return $true
}

function Start-NormalCodex {
    $package = Get-CodexAppPackage
    if (-not $package) { throw 'The Microsoft Store OpenAI.Codex package is not installed.' }
    Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($package.PackageFamilyName)!App" | Out-Null
}
