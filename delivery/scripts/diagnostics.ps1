[CmdletBinding()]
param()

$script = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold\engine\diagnostics.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'No installed Codex Skin Forge engine was found.' }
& $script
