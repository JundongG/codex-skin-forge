[CmdletBinding()]
param(
    [switch]$RestartNormal,
    [switch]$ForceClose
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-InstalledState
if ($state -and $state.port -and (Test-Path -LiteralPath $script:NodePath)) {
    [void](Stop-RecordedInjector)
    $injector = Join-Path $script:EngineRoot 'injector.mjs'
    try {
        & $script:NodePath $injector --remove --port ([int]$state.port) --theme-root $script:ThemeRoot --timeout-ms 3000 *> $null
    } catch {}
}
if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }

if ($RestartNormal) {
    $processes = @(Get-CodexProcesses)
    foreach ($item in $processes) {
        try { [void](Get-Process -Id ([int]$item.ProcessId) -ErrorAction Stop).CloseMainWindow() } catch {}
    }
    $deadline = (Get-Date).AddSeconds(12)
    while (@(Get-CodexProcesses).Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
    }
    $remaining = @(Get-CodexProcesses)
    if ($remaining.Count -gt 0) {
        if (-not $ForceClose) {
            throw 'The skin was removed, but Codex did not close. Close it manually to end the debugging port, then open normal Codex.'
        }
        foreach ($item in $remaining) { Stop-Process -Id ([int]$item.ProcessId) -Force }
    }
    Start-NormalCodex
    Write-Output 'Noir Gold was removed and normal Codex was reopened.'
} else {
    Write-Output 'Noir Gold was removed. Close this Codex window to end its local debugging port before reopening normal Codex.'
}
