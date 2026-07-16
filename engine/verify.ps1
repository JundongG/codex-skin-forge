[CmdletBinding()]
param(
    [string]$ScreenshotPath = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-InstalledState
$statePort = Get-OptionalProperty -Object $state -Name 'port'
if (-not $statePort) { throw 'No active Codex Skin Forge session state was found.' }
if (-not (Test-CodexDebugPort -Port ([int]$statePort))) { throw 'The recorded Codex debugging session is no longer active.' }
$node = Get-NodeRuntimeStatus
if (-not $node.ok) { throw 'The installed Node.js runtime is missing or invalid.' }
$injector = Join-Path $script:EngineRoot 'injector.mjs'
$arguments = @($injector, '--verify', '--port', [string]$statePort, '--theme-root', $script:ThemeRoot)
if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    $arguments += @('--screenshot', [IO.Path]::GetFullPath($ScreenshotPath))
}
& $script:NodePath @arguments
exit $LASTEXITCODE
