[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SessionId,
    [ValidateRange(30, 3600)][int]$TimeoutSeconds = 900
)

. (Join-Path $PSScriptRoot 'common.ps1')

[IO.Directory]::CreateDirectory($script:StateRoot) | Out-Null
$logPath = Join-Path $script:StateRoot ('injector-' + $SessionId + '.log')
$errorPath = Join-Path $script:StateRoot ('injector-' + $SessionId + '-error.log')
$startedAt = (Get-Date).ToUniversalTime()
$port = $null
$injectorPid = $null

try {
    Wait-CodexExit -TimeoutSeconds $TimeoutSeconds
    [void](Stop-RecordedInjector)

    $node = Get-NodeRuntimeStatus
    if (-not $node.ok) { throw 'Installed Node.js runtime validation failed.' }
    $port = Get-FreeLoopbackPort
    $codex = Get-CodexExecutable
    $arguments = @(
        "--remote-debugging-address=127.0.0.1",
        "--remote-debugging-port=$port"
    )
    Start-Process -FilePath $codex -ArgumentList $arguments | Out-Null

    $deadline = (Get-Date).AddSeconds(35)
    while (-not (Test-CodexDebugPort -Port $port)) {
        if ((Get-Date) -ge $deadline) { throw "Codex did not expose loopback CDP on port $port within 35 seconds." }
        Start-Sleep -Milliseconds 400
    }

    $injector = Join-Path $script:EngineRoot 'injector.mjs'
    $injectorArgs = @(
        "`"$injector`"",
        '--watch',
        '--port', "$port",
        '--theme-root', "`"$script:ThemeRoot`"",
        '--idle-exit-ms', '30000'
    )
    $daemon = Start-Process -FilePath $script:NodePath -ArgumentList $injectorArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError $errorPath
    $injectorPid = $daemon.Id

    $state = [ordered]@{
        schemaVersion = 1
        productVersion = $script:ProductVersion
        sessionId = $SessionId
        port = $port
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
        injectorPid = $injectorPid
        startedAt = $startedAt.ToString('o')
        finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        nextStep = 'Run verify.ps1 with a screenshot path and complete visual acceptance.'
    })
} catch {
    if ($injectorPid) {
        try { Stop-Process -Id $injectorPid -Force -ErrorAction SilentlyContinue } catch {}
    }
    Write-JsonFile -Path $script:ResultPath -Value ([ordered]@{
        schemaVersion = 1
        status = 'failed'
        sessionId = $SessionId
        port = $port
        startedAt = $startedAt.ToString('o')
        finishedAt = (Get-Date).ToUniversalTime().ToString('o')
        error = $_.Exception.Message
        recovery = 'Close the themed Codex window and open the normal Microsoft Store Codex shortcut.'
    })
    throw
}
