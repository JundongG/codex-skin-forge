[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot 'common.ps1')
$package = Get-CodexAppPackage
$node = Get-NodeRuntimeStatus
$state = Get-InstalledState
$theme = $null
$themePath = Join-Path $script:ThemeRoot 'theme.json'
if (Test-Path -LiteralPath $themePath -PathType Leaf) {
    try { $theme = Get-Content -LiteralPath $themePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
}
$result = [ordered]@{
    schemaVersion = 1
    checkedAt = (Get-Date).ToUniversalTime().ToString('o')
    codex = [ordered]@{
        installed = ($null -ne $package)
        version = if ($package) { [string]$package.Version } else { $null }
        running = @((Get-CodexProcesses) | ForEach-Object { [ordered]@{ name = $_.Name; pid = $_.ProcessId } })
    }
    runtime = $node
    theme = [ordered]@{
        installed = ($null -ne $theme)
        id = if ($theme) { [string]$theme.id } else { $null }
        name = if ($theme) { [string]$theme.name } else { $null }
        version = if ($theme) { [string]$theme.version } else { $null }
    }
    session = [ordered]@{
        active = ($null -ne $state -and $state.port -and (Test-CodexDebugPort -Port ([int]$state.port)))
        port = if ($state) { $state.port } else { $null }
        injectorPid = if ($state) { $state.injectorPid } else { $null }
    }
}
Write-JsonFile -Path (Join-Path $script:StateRoot 'diagnostics.json') -Value $result
$result | ConvertTo-Json -Depth 20
