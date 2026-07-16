[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$workspace = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('codex-skin-common-test-' + [guid]::NewGuid().ToString('N'))
$script:CodexSkinForgeStateRootOverride = $tempRoot
. (Join-Path $workspace 'engine\common.ps1')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
try {
    $escaped = $false
    try { Assert-PathWithin -Path ($tempRoot + '-sibling\file.txt') -Root $tempRoot -Label 'escape test' | Out-Null }
    catch { $escaped = $true }
    Assert-True $escaped 'Assert-PathWithin accepted a sibling-prefix path.'

    $jsonPath = Join-Path $tempRoot 'atomic.json'
    Write-JsonFile -Path $jsonPath -Value ([ordered]@{ status = 'ok'; version = 1 })
    $json = Get-Content -LiteralPath $jsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Assert-True ($json.status -eq 'ok') 'Atomic JSON write failed.'
    Assert-True (@(Get-ChildItem -LiteralPath $tempRoot -Filter '*.staging-*' -Force).Count -eq 0) 'Atomic JSON staging file leaked.'

    $engine = Join-Path $tempRoot 'engine'
    [IO.Directory]::CreateDirectory($engine) | Out-Null
    [IO.File]::WriteAllText((Join-Path $engine 'marker.txt'), 'old')
    [IO.File]::WriteAllText((Join-Path $tempRoot 'install.json'), '{"old":true}')
    $backup = Join-Path $tempRoot 'backups\transaction'
    [IO.Directory]::CreateDirectory($backup) | Out-Null
    Assert-True (Move-ProductPathToBackup -RelativePath 'engine' -BackupRoot $backup) 'Engine backup did not move.'
    Assert-True (Move-ProductPathToBackup -RelativePath 'install.json' -BackupRoot $backup) 'Install record backup did not move.'
    [IO.Directory]::CreateDirectory($engine) | Out-Null
    [IO.File]::WriteAllText((Join-Path $engine 'marker.txt'), 'new')
    [IO.File]::WriteAllText((Join-Path $tempRoot 'install.json'), '{"old":false}')
    Assert-True (Restore-ProductPathFromBackup -RelativePath 'engine' -BackupRoot $backup) 'Engine restore did not move.'
    Assert-True (Restore-ProductPathFromBackup -RelativePath 'install.json' -BackupRoot $backup) 'Install record restore did not move.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $engine 'marker.txt') -Raw) -eq 'old') 'Engine rollback restored the wrong content.'
    Assert-True ((Get-Content -LiteralPath (Join-Path $tempRoot 'install.json') -Raw) -match '"old":true') 'Install record rollback restored the wrong content.'

    Assert-True (Test-CommandLineMatch -CommandLine 'node.exe injector.mjs --watch --session-id abc' -RequiredValues @('injector.mjs', '--watch', 'abc')) 'Command-line verification rejected required values.'
    Assert-True (-not (Test-CommandLineMatch -CommandLine 'node.exe other.mjs --watch' -RequiredValues @('injector.mjs'))) 'Command-line verification accepted the wrong injector.'

    $mutex = Enter-ProductMutex -Purpose 'test-lock' -TimeoutMilliseconds 0
    try {
        $commonPath = Join-Path $workspace 'engine\common.ps1'
        $overridePath = $tempRoot
        $job = Start-Job -ScriptBlock {
            $script:CodexSkinForgeStateRootOverride = $using:overridePath
            . $using:commonPath
            try {
                $other = Enter-ProductMutex -Purpose 'test-lock' -TimeoutMilliseconds 200
                Exit-ProductMutex -Mutex $other
                'acquired'
            } catch {
                'blocked'
            }
        }
        [void](Wait-Job -Job $job -Timeout 15)
        $result = Receive-Job -Job $job
        Remove-Job -Job $job -Force
        Assert-True ($result -contains 'blocked') 'Lifecycle mutex allowed a concurrent process.'
    } finally {
        Exit-ProductMutex -Mutex $mutex
    }

    Write-Output 'Common lifecycle tests passed.'
} finally {
    Remove-Variable -Name CodexSkinForgeStateRootOverride -Scope Script -ErrorAction SilentlyContinue
    $full = [IO.Path]::GetFullPath($tempRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full)) {
        Remove-Item -LiteralPath $full -Recurse -Force
    }
}
