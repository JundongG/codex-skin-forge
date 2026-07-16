[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$module = Get-Module -ListAvailable PSScriptAnalyzer |
    Sort-Object Version -Descending |
    Select-Object -First 1
if (-not $module) { throw 'PSScriptAnalyzer is not installed.' }
Import-Module $module.Path
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$files = Get-ChildItem -LiteralPath $workspace -Recurse -File -Filter '*.ps1' |
    Where-Object { $_.FullName -notmatch '\\.git\\|\\build\\|\\release\\' }
$results = @()
foreach ($file in $files) {
    $results += @(Invoke-ScriptAnalyzer -Path $file.FullName -Severity Warning, Error)
}
if ($results.Count -gt 0) {
    $details = $results | ForEach-Object { "$($_.ScriptName):$($_.Line) [$($_.RuleName)] $($_.Message)" }
    throw "PSScriptAnalyzer reported issues:$([Environment]::NewLine)$($details -join [Environment]::NewLine)"
}
Write-Output "PSScriptAnalyzer passed for $($files.Count) PowerShell files."
