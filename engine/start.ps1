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

$running = @(Get-CodexProcesses)
if ($running.Count -gt 0 -and -not $Handoff) {
    throw 'Codex is already running. Close it first, or rerun this launcher with -Handoff so it can wait safely.'
}

$worker = Join-Path $PSScriptRoot 'start-worker.ps1'
$sessionId = [guid]::NewGuid().ToString('N')
if ($Handoff) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$worker`" -SessionId $sessionId -TimeoutSeconds $TimeoutSeconds"
    $helper = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Write-Output 'HANDOFF_STARTED'
    Write-Output "Helper PID: $($helper.Id)"
    if ($running.Count -gt 0) {
        Write-Output 'Please close Codex completely now. The helper will launch the themed session after it exits.'
    }
    exit 0
}

& $worker -SessionId $sessionId -TimeoutSeconds $TimeoutSeconds
exit $LASTEXITCODE
