[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
$package = Get-CodexAppPackage
$node = Get-NodeRuntimeStatus
$state = Get-InstalledState
$handoff = Get-ActiveHandoffWorker
$theme = $null
$themePath = Join-Path $script:ThemeRoot 'theme.json'
if (Test-Path -LiteralPath $themePath -PathType Leaf) {
    try { $theme = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Verbose "Installed theme metadata could not be parsed: $($_.Exception.Message)" }
}
$result = [ordered]@{
    schemaVersion = 2
    productVersion = $script:ProductVersion
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    codex = [ordered]@{
        installed = ($null -ne $package)
        version = if ($package) { [string]$package.Version } else { $null }
        running = @((Get-CodexMainProcess) | ForEach-Object { [ordered]@{ name = $_.Name; pid = $_.ProcessId } })
    }
    runtime = $node
    theme = [ordered]@{
        installed = ($null -ne $theme)
        id = if ($theme) { [string]$theme.id } else { $null }
        name = if ($theme) { [string]$theme.name } else { $null }
        version = if ($theme) { [string]$theme.version } else { $null }
    }
    handoff = [ordered]@{
        active = ($null -ne $handoff)
        pid = if ($handoff) { $handoff.ProcessId } else { $null }
    }
    session = [ordered]@{
        active = (Test-ActiveThemedSession)
        port = Get-OptionalProperty -Object $state -Name 'port'
        codexPid = Get-OptionalProperty -Object $state -Name 'codexPid'
        injectorPid = Get-OptionalProperty -Object $state -Name 'injectorPid'
    }
}
Write-JsonFile -Path (Join-Path $script:StateRoot 'diagnostics.json') -Value $result
$result | ConvertTo-Json -Depth 20
