Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProductId = 'codex-skin-forge'
$script:ProductVersion = '0.3.1'
$stateRootOverride = Get-Variable -Name CodexSkinForgeStateRootOverride -Scope Script -ErrorAction SilentlyContinue
$script:StateRoot = if ($stateRootOverride -and -not [string]::IsNullOrWhiteSpace([string]$stateRootOverride.Value)) {
    [IO.Path]::GetFullPath([string]$stateRootOverride.Value)
} else {
    Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold'
}
$script:EngineRoot = Join-Path $script:StateRoot 'engine'
$script:ThemeRoot = Join-Path $script:StateRoot 'theme'
$script:RuntimeRoot = Join-Path $script:StateRoot 'runtime'
$script:NodePath = Join-Path $script:RuntimeRoot 'node.exe'
$script:StatePath = Join-Path $script:StateRoot 'state.json'
$script:HandoffPath = Join-Path $script:StateRoot 'handoff.json'
$script:ResultPath = Join-Path $script:StateRoot 'latest-result.json'

function Get-Utf8NoBom {
    return New-Object Text.UTF8Encoding($false)
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

function Get-ProductPath {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [string]$Label = 'product path'
    )
    if ([IO.Path]::IsPathRooted($RelativePath) -or $RelativePath -match '(^|[\\/])\.\.([\\/]|$)') {
        throw "$Label must be a relative path without parent traversal."
    }
    return Assert-PathWithin -Path (Join-Path $script:StateRoot $RelativePath) -Root $script:StateRoot -Label $Label
}

function Write-Utf8TextFileAtomic {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not $parent) { throw "Cannot determine the parent directory for '$fullPath'." }
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $staging = Join-Path $parent ('.' + [IO.Path]::GetFileName($fullPath) + '.staging-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($staging, $Content, (Get-Utf8NoBom))
        Move-Item -LiteralPath $staging -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Force }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value
    )
    Write-Utf8TextFileAtomic -Path $Path -Content (($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine)
}

function Enter-ProductMutex {
    param(
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-z0-9-]+$')][string]$Purpose,
        [ValidateRange(0, 600000)][int]$TimeoutMilliseconds = 0
    )
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -replace '[^A-Za-z0-9-]', '-'
    $name = "Global\CodexSkinForge-$sid-$Purpose"
    $mutex = New-Object Threading.Mutex($false, $name)
    $acquired = $false
    try {
        try {
            $acquired = $mutex.WaitOne($TimeoutMilliseconds)
        } catch [Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) {
            throw "Another Codex Skin Forge $Purpose operation is already running."
        }
        return ,$mutex
    } catch {
        $mutex.Dispose()
        throw
    }
}

function Exit-ProductMutex {
    param([object]$Mutex)
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { Write-Verbose "Mutex release was not required: $($_.Exception.Message)" }
    $Mutex.Dispose()
}

function Move-ProductPathToBackup {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )
    $source = Get-ProductPath -RelativePath $RelativePath -Label 'managed source'
    if (-not (Test-Path -LiteralPath $source)) { return $false }
    $backupFull = Assert-PathWithin -Path $BackupRoot -Root $script:StateRoot -Label 'backup root'
    $destination = Join-Path $backupFull $RelativePath
    Assert-PathWithin -Path $destination -Root $backupFull -Label 'backup destination' | Out-Null
    $parent = Split-Path -Parent $destination
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Move-Item -LiteralPath $source -Destination $destination
    return $true
}

function Restore-ProductPathFromBackup {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$BackupRoot
    )
    $backupFull = Assert-PathWithin -Path $BackupRoot -Root $script:StateRoot -Label 'backup root'
    $source = Join-Path $backupFull $RelativePath
    Assert-PathWithin -Path $source -Root $backupFull -Label 'backup source' | Out-Null
    if (-not (Test-Path -LiteralPath $source)) { return $false }
    $destination = Get-ProductPath -RelativePath $RelativePath -Label 'restore destination'
    if (Test-Path -LiteralPath $destination) { Remove-Item -LiteralPath $destination -Recurse -Force }
    $parent = Split-Path -Parent $destination
    if ($parent) { [IO.Directory]::CreateDirectory($parent) | Out-Null }
    Move-Item -LiteralPath $source -Destination $destination
    return $true
}

function Get-CodexAppPackage {
    $packages = @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue | Sort-Object Version -Descending)
    if ($packages.Count -eq 0) { return $null }
    return $packages[0]
}

function Get-SystemPowerShellPath {
    $path = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Windows PowerShell was not found: $path" }
    return $path
}

function Get-DesktopDirectory {
    $override = Get-Variable -Name CodexSkinForgeDesktopOverride -Scope Script -ErrorAction SilentlyContinue
    if ($override -and -not [string]::IsNullOrWhiteSpace([string]$override.Value)) {
        return [IO.Path]::GetFullPath([string]$override.Value)
    }
    return [Environment]::GetFolderPath('Desktop')
}

function Get-StartMenuProgramsDirectory {
    $override = Get-Variable -Name CodexSkinForgeStartMenuOverride -Scope Script -ErrorAction SilentlyContinue
    if ($override -and -not [string]::IsNullOrWhiteSpace([string]$override.Value)) {
        return [IO.Path]::GetFullPath([string]$override.Value)
    }
    return Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs'
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
        return [ordered]@{ ok = $false; path = $script:NodePath; version = $null; signer = $null; sha256 = $null }
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
            sha256 = (Get-FileHash -LiteralPath $script:NodePath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {
        return [ordered]@{ ok = $false; path = $script:NodePath; version = $null; signer = $null; sha256 = $null; error = $_.Exception.Message }
    }
}

function Get-CodexProcess {
    return @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -in @('ChatGPT.exe', 'Codex.exe') -and (
                [string]$_.ExecutablePath -match '\\WindowsApps\\OpenAI\.Codex_' -or
                [string]$_.CommandLine -match '\\WindowsApps\\OpenAI\.Codex_'
            )
        })
}

function Get-CodexMainProcess {
    return @(Get-CodexProcess | Where-Object {
        $_.Name -eq 'ChatGPT.exe' -and [string]$_.CommandLine -notmatch '(^|\s)--type='
    })
}

function Wait-CodexExit {
    param([ValidateRange(30, 3600)][int]$TimeoutSeconds = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (@(Get-CodexMainProcess).Count -gt 0) {
        if ((Get-Date) -ge $deadline) {
            throw 'Timed out waiting for Codex to close. No themed launch was attempted.'
        }
        Start-Sleep -Seconds 2
    }
    Start-Sleep -Milliseconds 800
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
    param([Parameter(Mandatory = $true)][ValidateRange(1024, 65535)][int]$Port)
    try {
        $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/json/list" -TimeoutSec 1
        return [bool]($targets | Where-Object { $_.type -eq 'page' -and $_.url -like 'app://*' })
    } catch {
        return $false
    }
}

function Read-JsonFile {
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return $null }
}

function Get-OptionalProperty {
    param(
        [object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if (-not $property) { return $null }
    return $property.Value
}

function Get-InstalledState {
    return Read-JsonFile -Path $script:StatePath
}

function Test-CommandLineMatch {
    param(
        [string]$CommandLine,
        [Parameter(Mandatory = $true)][string[]]$RequiredValues
    )
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $false }
    foreach ($value in $RequiredValues) {
        if ($CommandLine.IndexOf($value, [StringComparison]::OrdinalIgnoreCase) -lt 0) { return $false }
    }
    return $true
}

function Get-RecordedInjectorProcess {
    param([object]$State = (Get-InstalledState))
    $injectorPid = Get-OptionalProperty -Object $State -Name 'injectorPid'
    $sessionId = Get-OptionalProperty -Object $State -Name 'sessionId'
    if (-not $injectorPid -or -not $sessionId) { return $null }
    $pidValue = [int]$injectorPid
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if (-not $process) { return $null }
    if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath)) { return $null }
    $actualPath = [IO.Path]::GetFullPath([string]$process.ExecutablePath)
    $expectedPath = [IO.Path]::GetFullPath($script:NodePath)
    $injectorPath = Join-Path $script:EngineRoot 'injector.mjs'
    $required = @($injectorPath, '--watch', '--theme-root', $script:ThemeRoot)
    $stateSchemaVersion = if ($State.PSObject.Properties['schemaVersion']) { [int]$State.schemaVersion } else { 1 }
    if ($stateSchemaVersion -ge 2) {
        $required += @('--session-id', [string]$sessionId)
    }
    if (-not $actualPath.Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    if (-not (Test-CommandLineMatch -CommandLine ([string]$process.CommandLine) -RequiredValues $required)) { return $null }
    return $process
}

function Stop-RecordedInjector {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()
    $state = Get-InstalledState
    $injectorPid = Get-OptionalProperty -Object $state -Name 'injectorPid'
    if (-not $injectorPid) { return $false }
    $pidValue = [int]$injectorPid
    $existing = Get-CimInstance Win32_Process -Filter "ProcessId=$pidValue" -ErrorAction SilentlyContinue
    if (-not $existing) { return $false }
    $verified = Get-RecordedInjectorProcess -State $state
    if (-not $verified) {
        throw "Refusing to stop PID $pidValue because its executable path and injector command line could not both be verified."
    }
    if ($PSCmdlet.ShouldProcess("PID $pidValue", 'Stop verified Codex Skin Forge injector')) {
        Stop-Process -Id $pidValue -Force
    }
    return $true
}

function Get-RecordedCodexMainProcess {
    param([object]$State = (Get-InstalledState))
    $codexPid = Get-OptionalProperty -Object $State -Name 'codexPid'
    $port = Get-OptionalProperty -Object $State -Name 'port'
    if (-not $codexPid -or -not $port) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$codexPid)" -ErrorAction SilentlyContinue
    if (-not $process -or $process.Name -ne 'ChatGPT.exe') { return $null }
    if ([string]$process.ExecutablePath -notmatch '\\WindowsApps\\OpenAI\.Codex_') { return $null }
    if ([string]$process.CommandLine -match '(^|\s)--type=') { return $null }
    if (-not (Test-CommandLineMatch -CommandLine ([string]$process.CommandLine) -RequiredValues @("--remote-debugging-port=$([int]$port)"))) {
        return $null
    }
    return $process
}

function Get-ActiveHandoffWorker {
    $handoff = Read-JsonFile -Path $script:HandoffPath
    $handoffPid = Get-OptionalProperty -Object $handoff -Name 'pid'
    $sessionId = Get-OptionalProperty -Object $handoff -Name 'sessionId'
    if (-not $handoffPid -or -not $sessionId) { return $null }
    $process = Get-CimInstance Win32_Process -Filter "ProcessId=$([int]$handoffPid)" -ErrorAction SilentlyContinue
    if (-not $process -or $process.Name -notin @('powershell.exe', 'pwsh.exe')) { return $null }
    $worker = Join-Path $script:EngineRoot 'start-worker.ps1'
    if (-not (Test-CommandLineMatch -CommandLine ([string]$process.CommandLine) -RequiredValues @($worker, [string]$sessionId))) {
        return $null
    }
    return $process
}

function Test-ActiveThemedSession {
    $state = Get-InstalledState
    if (-not $state) { return $false }
    $port = Get-OptionalProperty -Object $state -Name 'port'
    if ($port -and (Test-CodexDebugPort -Port ([int]$port))) { return $true }
    if (Get-RecordedInjectorProcess -State $state) { return $true }
    if (Get-RecordedCodexMainProcess -State $state) { return $true }
    return $false
}

function Start-NormalCodex {
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param()
    $package = Get-CodexAppPackage
    if (-not $package) { throw 'The Microsoft Store OpenAI.Codex package is not installed.' }
    if ($PSCmdlet.ShouldProcess('Microsoft Store Codex', 'Start normal application session')) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList "shell:AppsFolder\$($package.PackageFamilyName)!App" | Out-Null
    }
}
