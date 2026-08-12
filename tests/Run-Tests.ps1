[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$testParent = Join-Path $projectRoot '.test-work'
$runRoot = Join-Path $testParent ([Guid]::NewGuid().ToString('N'))
$moveScript = Join-Path $projectRoot 'src\Move-SafeDirectory.ps1'
$restoreScript = Join-Path $projectRoot 'src\Restore-SafeDirectory.ps1'
$passed = 0

function Assert-True {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Write-TestConfig {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$TargetRoot,
        [Parameter(Mandatory)][string]$Source,
        [string]$Target = 'relocated\cache'
    )
    [pscustomobject]@{
        target_root = $TargetRoot
        items = @(
            [pscustomobject]@{
                name = 'test-cache'
                source = $Source
                target = $Target
            }
        )
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Invoke-Test {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    & $Body
    $script:passed++
    Write-Host "PASS $Name"
}

New-Item -ItemType Directory -Path $runRoot -Force | Out-Null
try {
    Invoke-Test -Name 'dangerous filesystem root is rejected' -Body {
        $caseRoot = Join-Path $runRoot 'dangerous-root'
        New-Item -ItemType Directory -Path $caseRoot -Force | Out-Null
        $configPath = Join-Path $caseRoot 'config.json'
        Write-TestConfig -Path $configPath -TargetRoot (Join-Path $caseRoot 'target-root') -Source ([System.IO.Path]::GetPathRoot($caseRoot))

        $threw = $false
        try {
            & $moveScript -ConfigPath $configPath -ValidateOnly | Out-Null
        } catch {
            $threw = $true
            Assert-True -Condition ($_.Exception.Message -match 'filesystem root') -Message 'Expected a clear dangerous-root error.'
        }
        Assert-True -Condition $threw -Message 'A filesystem root must be rejected.'
    }

    Invoke-Test -Name 'ValidateOnly performs no writes' -Body {
        $caseRoot = Join-Path $runRoot 'validate-only'
        $source = Join-Path $caseRoot 'source'
        $targetRoot = Join-Path $caseRoot 'target-root'
        $configPath = Join-Path $caseRoot 'config.json'
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'data.txt') -Value 'validation' -Encoding UTF8
        Write-TestConfig -Path $configPath -TargetRoot $targetRoot -Source $source

        & $moveScript -ConfigPath $configPath -ValidateOnly | Out-Null
        Assert-True -Condition (Test-Path -LiteralPath $source -PathType Container) -Message 'Source should remain.'
        Assert-True -Condition (-not (Test-Path -LiteralPath $targetRoot)) -Message 'ValidateOnly must not create target_root.'
        $sourceItem = Get-Item -LiteralPath $source -Force
        Assert-True -Condition (-not ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -Message 'Source must remain an ordinary directory.'
    }

    Invoke-Test -Name 'overlapping configured sources are rejected' -Body {
        $caseRoot = Join-Path $runRoot 'overlap'
        $source = Join-Path $caseRoot 'source'
        $nestedSource = Join-Path $source 'nested'
        $targetRoot = Join-Path $caseRoot 'target-root'
        $configPath = Join-Path $caseRoot 'config.json'
        New-Item -ItemType Directory -Path $nestedSource -Force | Out-Null
        [pscustomobject]@{
            target_root = $targetRoot
            items = @(
                [pscustomobject]@{ name = 'parent'; source = $source; target = 'parent' },
                [pscustomobject]@{ name = 'child'; source = $nestedSource; target = 'child' }
            )
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $configPath -Encoding UTF8

        $threw = $false
        try {
            & $moveScript -ConfigPath $configPath -ValidateOnly | Out-Null
        } catch {
            $threw = $true
            Assert-True -Condition ($_.Exception.Message -match 'overlap') -Message 'Expected a clear overlap error.'
        }
        Assert-True -Condition $threw -Message 'Nested sources must be rejected.'
    }

    Invoke-Test -Name 'nested reparse points are rejected' -Body {
        $caseRoot = Join-Path $runRoot 'nested-reparse'
        $source = Join-Path $caseRoot 'source'
        $external = Join-Path $caseRoot 'external'
        $targetRoot = Join-Path $caseRoot 'target-root'
        $configPath = Join-Path $caseRoot 'config.json'
        New-Item -ItemType Directory -Path $source,$external -Force | Out-Null
        New-Item -ItemType Junction -Path (Join-Path $source 'linked') -Target $external | Out-Null
        Write-TestConfig -Path $configPath -TargetRoot $targetRoot -Source $source

        $threw = $false
        try {
            & $moveScript -ConfigPath $configPath -ValidateOnly | Out-Null
        } catch {
            $threw = $true
            Assert-True -Condition ($_.Exception.Message -match 'reparse point') -Message 'Expected a clear reparse-point error.'
        }
        Assert-True -Condition $threw -Message 'Nested reparse points must be rejected.'
    }

    Invoke-Test -Name 'migration and restore preserve data' -Body {
        $caseRoot = Join-Path $runRoot 'round-trip'
        $source = Join-Path $caseRoot 'source'
        $nested = Join-Path $source 'nested\empty'
        $targetRoot = Join-Path $caseRoot 'target-root'
        $target = Join-Path $targetRoot 'relocated\cache'
        $configPath = Join-Path $caseRoot 'config.json'
        New-Item -ItemType Directory -Path $nested -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'alpha.txt') -Value 'alpha' -Encoding UTF8
        Set-Content -LiteralPath (Join-Path (Split-Path -Parent $nested) 'beta.txt') -Value 'beta' -Encoding UTF8
        Write-TestConfig -Path $configPath -TargetRoot $targetRoot -Source $source

        & $moveScript -ConfigPath $configPath | Out-Null
        $migratedSource = Get-Item -LiteralPath $source -Force
        Assert-True -Condition ([bool]($migratedSource.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -Message 'Source should become a junction.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $target 'alpha.txt') -PathType Leaf) -Message 'Target should contain copied data.'
        Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $source 'alpha.txt') -Raw).Trim() -eq 'alpha') -Message 'Data should be readable through the junction.'
        Assert-True -Condition (-not (Get-ChildItem -LiteralPath $caseRoot -Force | Where-Object Name -Like 'source.sdr-backup-*')) -Message 'Successful migration backup should be removed.'

        & $restoreScript -ConfigPath $configPath | Out-Null
        $restoredSource = Get-Item -LiteralPath $source -Force
        Assert-True -Condition (-not ($restoredSource.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -Message 'Restored source should be an ordinary directory.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $source 'nested\empty') -PathType Container) -Message 'Empty directories should be restored.'
        Assert-True -Condition ((Get-Content -LiteralPath (Join-Path $source 'alpha.txt') -Raw).Trim() -eq 'alpha') -Message 'Restored source should contain data.'
        Assert-True -Condition (Test-Path -LiteralPath (Join-Path $target 'alpha.txt') -PathType Leaf) -Message 'Restore should retain the target copy.'
    }

    Write-Host "All $passed tests passed."
} finally {
    $resolvedRunRoot = [System.IO.Path]::GetFullPath($runRoot).TrimEnd('\')
    $resolvedTestParent = [System.IO.Path]::GetFullPath($testParent).TrimEnd('\')
    $expectedPrefix = $resolvedTestParent + [System.IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRunRoot.StartsWith($expectedPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clean an unexpected test path: $resolvedRunRoot"
    }
    if (Test-Path -LiteralPath $resolvedRunRoot) {
        Remove-Item -LiteralPath $resolvedRunRoot -Recurse -Force
    }
    if (Test-Path -LiteralPath $resolvedTestParent) {
        $remaining = @(Get-ChildItem -LiteralPath $resolvedTestParent -Force)
        if ($remaining.Count -eq 0) {
            Remove-Item -LiteralPath $resolvedTestParent -Force
        }
    }
}
