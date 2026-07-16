[CmdletBinding()]
param([string]$ScreenshotPath = '')

$script = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'CodexNoirGold\engine\verify.ps1'
if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw 'No installed Codex Skin Forge engine was found.' }
& $script -ScreenshotPath $ScreenshotPath
exit $LASTEXITCODE
