Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-SdrAbsolutePath {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [string]$Label
    )

    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        throw "$Label must not be empty."
    }
    if (-not [System.IO.Path]::IsPathFullyQualified($expanded)) {
        throw "$Label must be an absolute path: $Path"
    }

    return [System.IO.Path]::GetFullPath($expanded).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}

function Test-SdrSamePath {
    param(
        [Parameter(Mandatory)][string]$Left,
        [Parameter(Mandatory)][string]$Right
    )

    return $Left.Equals($Right, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-SdrPathInside {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Parent
    )

    if (Test-SdrSamePath -Left $Path -Right $Parent) {
        return $false
    }
    $prefix = $Parent.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-SdrNotDangerousRoot {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label
    )

    $root = [System.IO.Path]::GetPathRoot($Path)
    if ([string]::IsNullOrWhiteSpace($root) -or (Test-SdrSamePath -Left $Path -Right $root.TrimEnd('\', '/'))) {
        throw "$Label must not be a filesystem root: $Path"
    }

    $protected = @(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86),
        [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object {
        [System.IO.Path]::GetFullPath($_).TrimEnd('\', '/')
    }

    foreach ($protectedPath in $protected) {
        if (Test-SdrSamePath -Left $Path -Right $protectedPath) {
            throw "$Label must not be a protected system or profile root: $Path"
        }
    }
}

function Assert-SdrNoReparsePoints {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Label,
        [switch]$IncludeChildren
    )

    $current = $Path
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName
    }
    while (Test-Path -LiteralPath $current) {
        $item = Get-Item -LiteralPath $current -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "$Label passes through a reparse point: $current"
        }
        $parent = [System.IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            break
        }
        $current = $parent.FullName
    }

    if ($IncludeChildren -and (Test-Path -LiteralPath $Path -PathType Container)) {
        $nested = Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop |
            Where-Object { $_.Attributes -band [System.IO.FileAttributes]::ReparsePoint } |
            Select-Object -First 1
        if ($null -ne $nested) {
            throw "$Label contains a reparse point: $($nested.FullName)"
        }
    }
}

function Get-SdrDirectoryStats {
    param([Parameter(Mandatory)][string]$Path)

    $files = @(Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction Stop)
    $directories = @(Get-ChildItem -LiteralPath $Path -Directory -Recurse -Force -ErrorAction Stop)
    $measurement = $files | Measure-Object -Property Length -Sum
    $bytes = if ($null -eq $measurement.Sum) { [int64]0 } else { [int64]$measurement.Sum }

    [pscustomobject]@{
        Files = [int64]$files.Count
        Directories = [int64]$directories.Count
        Bytes = $bytes
    }
}

function Assert-SdrStatsEqual {
    param(
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)][string]$Context
    )

    if ($Expected.Files -ne $Actual.Files -or
        $Expected.Directories -ne $Actual.Directories -or
        $Expected.Bytes -ne $Actual.Bytes) {
        throw ("$Context verification failed. Expected files/directories/bytes " +
            "$($Expected.Files)/$($Expected.Directories)/$($Expected.Bytes), got " +
            "$($Actual.Files)/$($Actual.Directories)/$($Actual.Bytes).")
    }
}

function Test-SdrExpectedJunction {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    if (-not (Test-Path -LiteralPath $Source -PathType Container)) {
        return $false
    }
    $item = Get-Item -LiteralPath $Source -Force
    if (-not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        return $false
    }
    $linkTypeProperty = $item.PSObject.Properties['LinkType']
    if ($null -eq $linkTypeProperty -or [string]$linkTypeProperty.Value -ne 'Junction') {
        return $false
    }

    $targetProperty = $item.PSObject.Properties['Target']
    if ($null -eq $targetProperty) {
        throw "Cannot inspect the reparse-point target: $Source"
    }
    $actualTarget = [string]@($targetProperty.Value)[0]
    if ([string]::IsNullOrWhiteSpace($actualTarget)) {
        throw "The reparse-point target is empty: $Source"
    }

    $actualFull = Resolve-SdrAbsolutePath -Path $actualTarget -Label 'Actual junction target'
    return Test-SdrSamePath -Left $actualFull -Right $Target
}

function Read-SdrConfiguration {
    param([Parameter(Mandatory)][string]$ConfigPath)

    $fullConfigPath = Resolve-SdrAbsolutePath -Path $ConfigPath -Label 'ConfigPath'
    if (-not (Test-Path -LiteralPath $fullConfigPath -PathType Leaf)) {
        throw "Configuration file does not exist: $fullConfigPath"
    }

    $config = Get-Content -LiteralPath $fullConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($null -eq $config.PSObject.Properties['target_root']) {
        throw 'Configuration must define target_root.'
    }
    if ($null -eq $config.PSObject.Properties['items']) {
        throw 'Configuration must define items.'
    }

    $targetRoot = Resolve-SdrAbsolutePath -Path ([string]$config.target_root) -Label 'target_root'
    Assert-SdrNotDangerousRoot -Path $targetRoot -Label 'target_root'
    Assert-SdrNoReparsePoints -Path $targetRoot -Label 'target_root'

    $rawItems = @($config.items)
    if ($rawItems.Count -eq 0) {
        throw 'Configuration items must not be empty.'
    }

    $names = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $sources = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $targets = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $resolvedItems = @(foreach ($rawItem in $rawItems) {
        foreach ($property in @('name', 'source', 'target')) {
            if ($null -eq $rawItem.PSObject.Properties[$property] -or
                [string]::IsNullOrWhiteSpace([string]$rawItem.$property)) {
                throw "Each item must define a non-empty $property."
            }
        }

        $name = [string]$rawItem.name
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Item name may contain only letters, numbers, dot, underscore, and hyphen: $name"
        }
        if (-not $names.Add($name)) {
            throw "Duplicate item name: $name"
        }

        $source = Resolve-SdrAbsolutePath -Path ([string]$rawItem.source) -Label "source for $name"
        Assert-SdrNotDangerousRoot -Path $source -Label "source for $name"

        $relativeTarget = [Environment]::ExpandEnvironmentVariables([string]$rawItem.target)
        if ([System.IO.Path]::IsPathFullyQualified($relativeTarget)) {
            throw "Target for $name must be relative to target_root: $relativeTarget"
        }
        $segments = $relativeTarget -split '[\\/]'
        if ($segments -contains '..') {
            throw "Target for $name must not contain '..': $relativeTarget"
        }

        $target = [System.IO.Path]::GetFullPath((Join-Path $targetRoot $relativeTarget)).TrimEnd('\', '/')
        if (-not (Test-SdrPathInside -Path $target -Parent $targetRoot)) {
            throw "Target for $name escaped target_root: $target"
        }
        Assert-SdrNotDangerousRoot -Path $target -Label "target for $name"

        if ((Test-SdrSamePath -Left $source -Right $target) -or
            (Test-SdrPathInside -Path $target -Parent $source) -or
            (Test-SdrPathInside -Path $source -Parent $target)) {
            throw "Source and target for $name must not overlap. Source=$source Target=$target"
        }
        if (-not $sources.Add($source)) {
            throw "Duplicate source path: $source"
        }
        if (-not $targets.Add($target)) {
            throw "Duplicate target path: $target"
        }

        [pscustomobject]@{
            Name = $name
            Source = $source
            Target = $target
        }
    })

    for ($leftIndex = 0; $leftIndex -lt $resolvedItems.Count; $leftIndex++) {
        for ($rightIndex = $leftIndex + 1; $rightIndex -lt $resolvedItems.Count; $rightIndex++) {
            $left = $resolvedItems[$leftIndex]
            $right = $resolvedItems[$rightIndex]
            $pairs = @(
                @($left.Source, $right.Source, 'source paths'),
                @($left.Target, $right.Target, 'target paths'),
                @($left.Source, $right.Target, 'a source and another target'),
                @($left.Target, $right.Source, 'a target and another source')
            )
            foreach ($pair in $pairs) {
                if ((Test-SdrSamePath -Left $pair[0] -Right $pair[1]) -or
                    (Test-SdrPathInside -Path $pair[0] -Parent $pair[1]) -or
                    (Test-SdrPathInside -Path $pair[1] -Parent $pair[0])) {
                    throw "Configured $($pair[2]) overlap between $($left.Name) and $($right.Name): $($pair[0]) <> $($pair[1])"
                }
            }
        }
    }

    [pscustomobject]@{
        ConfigPath = $fullConfigPath
        TargetRoot = $targetRoot
        Items = $resolvedItems
    }
}

function Invoke-SdrRobocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Target
    )

    $arguments = @(
        $Source,
        $Target,
        '/E',
        '/COPY:DAT',
        '/DCOPY:DAT',
        '/R:2',
        '/W:1',
        '/XJ',
        '/NP',
        '/NFL',
        '/NDL',
        '/NJH',
        '/NJS'
    )
    & robocopy.exe @arguments | Out-Host
    $exitCode = $LASTEXITCODE
    if ($exitCode -gt 7) {
        throw "robocopy failed with exit code $exitCode. Source=$Source Target=$Target"
    }
    return $exitCode
}

function Get-SdrMovePlan {
    param([Parameter(Mandatory)]$Configuration)

    $plans = foreach ($item in $Configuration.Items) {
        if (Test-SdrExpectedJunction -Source $item.Source -Target $item.Target) {
            if (-not (Test-Path -LiteralPath $item.Target -PathType Container)) {
                throw "Configured target is missing for migrated item $($item.Name): $($item.Target)"
            }
            [pscustomobject]@{
                Name = $item.Name
                Source = $item.Source
                Target = $item.Target
                State = 'already-migrated'
                Stats = Get-SdrDirectoryStats -Path $item.Source
            }
            continue
        }

        if (-not (Test-Path -LiteralPath $item.Source -PathType Container)) {
            throw "Source directory does not exist for $($item.Name): $($item.Source)"
        }
        $sourceItem = Get-Item -LiteralPath $item.Source -Force
        if ($sourceItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Source is an unexpected reparse point for $($item.Name): $($item.Source)"
        }
        Assert-SdrNoReparsePoints -Path $item.Source -Label "source for $($item.Name)" -IncludeChildren
        Assert-SdrNoReparsePoints -Path $item.Target -Label "target for $($item.Name)"
        if (Test-Path -LiteralPath $item.Target) {
            $targetItem = Get-Item -LiteralPath $item.Target -Force
            if (-not $targetItem.PSIsContainer) {
                throw "Target exists and is not a directory for $($item.Name): $($item.Target)"
            }
            if ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                throw "Target must not be a reparse point for $($item.Name): $($item.Target)"
            }
        }

        [pscustomobject]@{
            Name = $item.Name
            Source = $item.Source
            Target = $item.Target
            State = 'ready'
            Stats = Get-SdrDirectoryStats -Path $item.Source
        }
    }
    return @($plans)
}

function Invoke-SdrMove {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [switch]$ValidateOnly
    )

    $configuration = Read-SdrConfiguration -ConfigPath $ConfigPath
    $plans = Get-SdrMovePlan -Configuration $configuration

    $plans | Select-Object Name, State, Source, Target,
        @{Name = 'Files'; Expression = { $_.Stats.Files }},
        @{Name = 'Directories'; Expression = { $_.Stats.Directories }},
        @{Name = 'Bytes'; Expression = { $_.Stats.Bytes }} |
        Format-Table -AutoSize | Out-Host

    if ($ValidateOnly) {
        Write-Host 'Validation completed; no files were changed.'
        return $plans
    }

    New-Item -ItemType Directory -Path $configuration.TargetRoot -Force | Out-Null
    $results = foreach ($plan in $plans) {
        if ($plan.State -eq 'already-migrated') {
            [pscustomobject]@{
                Name = $plan.Name
                State = 'already-migrated'
                Source = $plan.Source
                Target = $plan.Target
                Files = $plan.Stats.Files
                Directories = $plan.Stats.Directories
                Bytes = $plan.Stats.Bytes
            }
            continue
        }

        $targetParent = Split-Path -Parent $plan.Target
        New-Item -ItemType Directory -Path $targetParent -Force | Out-Null
        New-Item -ItemType Directory -Path $plan.Target -Force | Out-Null

        $before = Get-SdrDirectoryStats -Path $plan.Source
        $robocopyExitCode = Invoke-SdrRobocopy -Source $plan.Source -Target $plan.Target
        $copied = Get-SdrDirectoryStats -Path $plan.Target
        Assert-SdrStatsEqual -Expected $before -Actual $copied -Context "Copy for $($plan.Name)"
        $stableSource = Get-SdrDirectoryStats -Path $plan.Source
        Assert-SdrStatsEqual -Expected $before -Actual $stableSource -Context "Source stability for $($plan.Name)"

        $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
        $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
        $backup = "$($plan.Source).sdr-backup-$stamp-$suffix"
        if (Test-Path -LiteralPath $backup) {
            throw "Generated backup path already exists: $backup"
        }

        Move-Item -LiteralPath $plan.Source -Destination $backup
        try {
            New-Item -ItemType Junction -Path $plan.Source -Target $plan.Target | Out-Null
            if (-not (Test-SdrExpectedJunction -Source $plan.Source -Target $plan.Target)) {
                throw "Junction verification failed for $($plan.Name): $($plan.Source)"
            }
            $throughJunction = Get-SdrDirectoryStats -Path $plan.Source
            Assert-SdrStatsEqual -Expected $copied -Actual $throughJunction -Context "Junction for $($plan.Name)"
        } catch {
            if (Test-Path -LiteralPath $plan.Source) {
                $failedSource = Get-Item -LiteralPath $plan.Source -Force
                if ($failedSource.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    Remove-Item -LiteralPath $plan.Source -Force
                } else {
                    throw "Rollback stopped because an unexpected ordinary path appeared at $($plan.Source). Original retained at $backup. Cause: $($_.Exception.Message)"
                }
            }
            if (-not (Test-Path -LiteralPath $plan.Source) -and (Test-Path -LiteralPath $backup -PathType Container)) {
                Move-Item -LiteralPath $backup -Destination $plan.Source
            }
            throw
        }

        $expectedBackupPrefix = $plan.Source + '.sdr-backup-'
        if (-not $backup.StartsWith($expectedBackupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove unexpected backup path: $backup"
        }
        Remove-Item -LiteralPath $backup -Recurse -Force

        [pscustomobject]@{
            Name = $plan.Name
            State = 'migrated'
            Source = $plan.Source
            Target = $plan.Target
            Files = $copied.Files
            Directories = $copied.Directories
            Bytes = $copied.Bytes
            RobocopyExitCode = $robocopyExitCode
        }
    }

    return @($results)
}

function Get-SdrRestorePlan {
    param([Parameter(Mandatory)]$Configuration)

    $plans = foreach ($item in $Configuration.Items) {
        if (-not (Test-SdrExpectedJunction -Source $item.Source -Target $item.Target)) {
            throw "Source is not a junction to the configured target for $($item.Name): $($item.Source)"
        }
        if (-not (Test-Path -LiteralPath $item.Target -PathType Container)) {
            throw "Target directory does not exist for $($item.Name): $($item.Target)"
        }
        $targetItem = Get-Item -LiteralPath $item.Target -Force
        if ($targetItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Target must not be a reparse point for $($item.Name): $($item.Target)"
        }

        [pscustomobject]@{
            Name = $item.Name
            Source = $item.Source
            Target = $item.Target
            Stats = Get-SdrDirectoryStats -Path $item.Target
        }
    }
    return @($plans)
}

function Invoke-SdrRestore {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ConfigPath)

    $configuration = Read-SdrConfiguration -ConfigPath $ConfigPath
    $plans = Get-SdrRestorePlan -Configuration $configuration
    $results = foreach ($plan in $plans) {
        Remove-Item -LiteralPath $plan.Source -Force
        New-Item -ItemType Directory -Path $plan.Source -Force | Out-Null
        try {
            $robocopyExitCode = Invoke-SdrRobocopy -Source $plan.Target -Target $plan.Source
            $restored = Get-SdrDirectoryStats -Path $plan.Source
            Assert-SdrStatsEqual -Expected $plan.Stats -Actual $restored -Context "Restore for $($plan.Name)"
        } catch {
            if (Test-Path -LiteralPath $plan.Source) {
                $partialSource = Get-Item -LiteralPath $plan.Source -Force
                if ($partialSource.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                    throw "Rollback stopped because source unexpectedly became a reparse point: $($plan.Source). Target remains at $($plan.Target). Cause: $($_.Exception.Message)"
                }
                Remove-Item -LiteralPath $plan.Source -Recurse -Force
            }
            New-Item -ItemType Junction -Path $plan.Source -Target $plan.Target | Out-Null
            if (-not (Test-SdrExpectedJunction -Source $plan.Source -Target $plan.Target)) {
                throw "Restore failed and junction rollback could not be verified. Target remains at $($plan.Target). Cause: $($_.Exception.Message)"
            }
            throw
        }

        [pscustomobject]@{
            Name = $plan.Name
            State = 'restored'
            Source = $plan.Source
            RetainedTarget = $plan.Target
            Files = $restored.Files
            Directories = $restored.Directories
            Bytes = $restored.Bytes
            RobocopyExitCode = $robocopyExitCode
        }
    }
    return @($results)
}

Export-ModuleMember -Function Invoke-SdrMove, Invoke-SdrRestore
