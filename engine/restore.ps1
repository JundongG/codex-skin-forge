[CmdletBinding()]
param(
    [switch]$RestartNormal,
    [switch]$ForceClose
)

. (Join-Path $PSScriptRoot 'common.ps1')
$lifecycleMutex = $null
try {
    $lifecycleMutex = Enter-ProductMutex -Purpose 'lifecycle' -TimeoutMilliseconds 3000
    $state = Get-InstalledState
    $liveRemovalRequired = $false
    $liveRemovalSucceeded = $true
    $statePort = Get-OptionalProperty -Object $state -Name 'port'

    if ($statePort) {
        $liveRemovalRequired = Test-CodexDebugPort -Port ([int]$statePort)
        try { [void](Stop-RecordedInjector) } catch { Write-Warning $_.Exception.Message }
        if ($liveRemovalRequired -and (Test-Path -LiteralPath $script:NodePath -PathType Leaf)) {
            $injector = Join-Path $script:EngineRoot 'injector.mjs'
            & $script:NodePath $injector --remove --port ([int]$statePort) --theme-root $script:ThemeRoot --timeout-ms 5000 *> $null
            $liveRemovalSucceeded = ($LASTEXITCODE -eq 0)
        }
    }

    if ($liveRemovalRequired -and -not $liveRemovalSucceeded -and -not $RestartNormal) {
        throw 'The live visual layer could not be removed safely. Close Codex completely, then run restore again.'
    }

    if ($RestartNormal) {
        $recordedMain = Get-RecordedCodexMainProcess -State $state
        $targets = if ($recordedMain) { @($recordedMain) } else { @(Get-CodexMainProcess) }
        foreach ($item in $targets) {
            try { [void](Get-Process -Id ([int]$item.ProcessId) -ErrorAction Stop).CloseMainWindow() }
            catch { Write-Verbose "Could not request a graceful Codex close: $($_.Exception.Message)" }
        }
        $deadline = (Get-Date).AddSeconds(12)
        while (@(Get-CodexMainProcess).Count -gt 0 -and (Get-Date) -lt $deadline) {
            Start-Sleep -Milliseconds 500
        }
        $remaining = @(Get-CodexMainProcess)
        if ($remaining.Count -gt 0) {
            if (-not $ForceClose) {
                throw 'The visual layer was disabled, but Codex did not close. Close it manually to end the debugging port, then open normal Codex.'
            }
            foreach ($item in @(Get-CodexProcess)) {
                Stop-Process -Id ([int]$item.ProcessId) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
    if (Test-Path -LiteralPath $script:HandoffPath) {
        $handoff = Get-ActiveHandoffWorker
        if (-not $handoff) { Remove-Item -LiteralPath $script:HandoffPath -Force }
    }

    if ($RestartNormal) {
        Start-NormalCodex
        Write-Output 'The customer skin was removed and normal Codex was reopened.'
    } else {
        Write-Output 'The customer skin was removed. Close this Codex window to end its local debugging port before reopening normal Codex.'
    }
} finally {
    Exit-ProductMutex -Mutex $lifecycleMutex
}
