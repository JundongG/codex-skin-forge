[CmdletBinding()]
param(
    [switch]$Handoff,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)

. (Join-Path $PSScriptRoot 'common.ps1')

if (-not (Test-Path -LiteralPath $script:ThemeRoot -PathType Container)) {
    throw 'No installed client theme was found. Run the customer package installer first.'
}
$node = Get-NodeRuntimeStatus
if (-not $node.ok) {
    throw 'The installed signed Node.js runtime is missing or invalid. Rerun the customer package installer.'
}
$injector = Join-Path $script:EngineRoot 'injector.mjs'
& $script:NodePath $injector --validate-theme --theme-root $script:ThemeRoot *> $null
if ($LASTEXITCODE -ne 0) {
    throw 'The installed customer theme failed validation. Rerun the customer package installer.'
}

$pending = Get-ActiveHandoffWorker
if ($pending) {
    throw "A Codex Skin Forge handoff is already waiting (PID $($pending.ProcessId))."
}

$running = @(Get-CodexMainProcess)
if ($running.Count -gt 0 -and -not $Handoff) {
    throw 'Codex is already running. Close it first, or rerun this launcher with -Handoff so it can wait safely.'
}

$worker = Join-Path $PSScriptRoot 'start-worker.ps1'
$sessionId = [guid]::NewGuid().ToString('N')
if ($Handoff) {
    $launchMutex = $null
    try {
        $launchMutex = Enter-ProductMutex -Purpose 'handoff-launch' -TimeoutMilliseconds 0
        $pending = Get-ActiveHandoffWorker
        if ($pending) { throw "A Codex Skin Forge handoff is already waiting (PID $($pending.ProcessId))." }
        $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" -SessionId $sessionId -TimeoutSeconds $TimeoutSeconds"
        $helper = Start-Process -FilePath (Get-SystemPowerShellPath) -ArgumentList $arguments -WindowStyle Hidden -PassThru
        Start-Sleep -Milliseconds 450
        $helper.Refresh()
        if ($helper.HasExited) {
            $result = Read-JsonFile -Path $script:ResultPath
            $resultError = Get-OptionalProperty -Object $result -Name 'error'
            $detail = if ($resultError) { [string]$resultError } else { 'The hidden handoff helper exited before it was ready.' }
            throw $detail
        }
    } finally {
        Exit-ProductMutex -Mutex $launchMutex
    }
    Write-Output 'HANDOFF_STARTED'
    Write-Output "Helper PID: $($helper.Id)"
    if ($running.Count -gt 0) {
        Write-Output 'Please close Codex completely now. The helper will launch the themed session after it exits.'
    }
    exit 0
}

& $worker -SessionId $sessionId -TimeoutSeconds $TimeoutSeconds
exit $LASTEXITCODE
