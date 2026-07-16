[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{32}$')][string]$SessionId,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)

. (Join-Path $PSScriptRoot 'common.ps1')

[IO.Directory]::CreateDirectory($script:StateRoot) | Out-Null
$logPath = Join-Path $script:StateRoot ('injector-' + $SessionId + '.log')
$errorPath = Join-Path $script:StateRoot ('injector-' + $SessionId + '-error.log')
$startedAt = (Get-Date).ToUniversalTime()
$port = $null
$codexPid = $null
$injectorPid = $null
$lifecycleMutex = $null

try {
    $lifecycleMutex = Enter-ProductMutex -Purpose 'lifecycle' -TimeoutMilliseconds 0
    Write-JsonFile -Path $script:HandoffPath -Value ([ordered]@{
        schemaVersion = 1
        sessionId = $SessionId
        pid = $PID
        startedAt = $startedAt.ToString('o')
    })

    Wait-CodexExit -TimeoutSeconds $TimeoutSeconds
    try { [void](Stop-RecordedInjector) } catch { Write-Warning $_.Exception.Message }

    $node = Get-NodeRuntimeStatus
    if (-not $node.ok) { throw 'Installed Node.js runtime validation failed.' }
    $injector = Join-Path $script:EngineRoot 'injector.mjs'
    & $script:NodePath $injector --validate-theme --theme-root $script:ThemeRoot *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Installed customer theme validation failed.' }

    $port = Get-FreeLoopbackPort
    $codex = Get-CodexExecutable
    $arguments = @(
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=$port"
    )
    $codexProcess = Start-Process -FilePath $codex -ArgumentList $arguments -PassThru
    $codexPid = $codexProcess.Id

    $deadline = (Get-Date).AddSeconds(35)
    while (-not (Test-CodexDebugPort -Port $port)) {
        if ((Get-Date) -ge $deadline) { throw "Codex did not expose loopback CDP on port $port within 35 seconds." }
        Start-Sleep -Milliseconds 400
    }

    $injectorArgs = @(
        "`"$injector`"",
        '--watch',
        '--session-id', $SessionId,
        '--port', "$port",
        '--theme-root', "`"$script:ThemeRoot`"",
        '--idle-exit-ms', '30000'
    )
    $daemon = Start-Process -FilePath $script:NodePath -ArgumentList $injectorArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $errorPath
    $injectorPid = $daemon.Id

    $state = [ordered]@{
        schemaVersion = 2
        productVersion = $script:ProductVersion
        sessionId = $SessionId
        port = $port
        codexPid = $codexPid
        injectorPid = $injectorPid
        startedAt = $startedAt.ToString('o')
        themeRoot = $script:ThemeRoot
        nodePath = $script:NodePath
        log = $logPath
        errorLog = $errorPath
    }
    Write-JsonFile -Path $script:StatePath -Value $state

    $verified = $false
    for ($attempt = 0; $attempt -lt 50; $attempt++) {
        Start-Sleep -Milliseconds 650
        & $script:NodePath $injector --verify --port $port --theme-root $script:ThemeRoot *> $null
        if ($LASTEXITCODE -eq 0) { $verified = $true; break }
    }
    if (-not $verified) { throw 'The themed Codex session launched, but visual verification failed.' }

    Write-JsonFile -Path $script:ResultPath -Value ([ordered]@{
        schemaVersion = 1
        status = 'success'
        sessionId = $SessionId
        port = $port
        codexPid = $codexPid
        injectorPid = $injectorPid
        startedAt = $startedAt.ToString('o')
        finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        nextStep = 'Run verify.ps1 with a screenshot path and complete visual acceptance.'
    })
} catch {
    if ($injectorPid) {
        try { Stop-Process -Id $injectorPid -Force -ErrorAction SilentlyContinue }
        catch { Write-Verbose "Injector cleanup failed: $($_.Exception.Message)" }
    }
    Write-JsonFile -Path $script:ResultPath -Value ([ordered]@{
        schemaVersion = 1
        status = 'failed'
        sessionId = $SessionId
        port = $port
        codexPid = $codexPid
        startedAt = $startedAt.ToString('o')
        finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        recovery = 'Close the themed Codex window and open the normal Microsoft Store Codex shortcut.'
    })
    throw
} finally {
    $handoff = Read-JsonFile -Path $script:HandoffPath
    $handoffSessionId = Get-OptionalProperty -Object $handoff -Name 'sessionId'
    if ([string]$handoffSessionId -eq $SessionId -and (Test-Path -LiteralPath $script:HandoffPath)) {
        Remove-Item -LiteralPath $script:HandoffPath -Force
    }
    Exit-ProductMutex -Mutex $lifecycleMutex
}
