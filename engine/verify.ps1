[CmdletBinding()]
param(
    [string]$ScreenshotPath = ''
)

. (Join-Path $PSScriptRoot 'common.ps1')
$state = Get-InstalledState
if (-not $state -or -not $state.port) { throw 'No active Noir Gold session state was found.' }
$injector = Join-Path $script:EngineRoot 'injector.mjs'
$arguments = @($injector, '--verify', '--port', [string]$state.port, '--theme-root', $script:ThemeRoot)
if (-not [string]::IsNullOrWhiteSpace($ScreenshotPath)) {
    $arguments += @('--screenshot', [IO.Path]::GetFullPath($ScreenshotPath))
}
& $script:NodePath @arguments
exit $LASTEXITCODE
