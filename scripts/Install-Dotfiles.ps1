[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidateSet("Link", "Copy")]
    [string]$Mode = "Link",

    [switch]$Replace,

    [switch]$Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$mappings = @(
    [pscustomobject]@{
        Name = "Copilot instructions"
        Source = Join-Path $repositoryRoot "dotfiles\copilot\copilot-instructions.md"
        Destination = Join-Path $HOME ".copilot\copilot-instructions.md"
        Mode = $Mode
    },
    [pscustomobject]@{
        Name = "Git configuration"
        Source = Join-Path $repositoryRoot "dotfiles\git\gitconfig"
        Destination = Join-Path $HOME ".config\devsetup\gitconfig"
        Mode = $Mode
    },
    [pscustomobject]@{
        Name = "Git identity"
        Source = Join-Path $repositoryRoot "dotfiles\git\identity.gitconfig"
        Destination = Join-Path $HOME ".config\devsetup\identity.gitconfig"
        Mode = $Mode
    },
    [pscustomobject]@{
        Name = "PowerShell profile source"
        Source = Join-Path $repositoryRoot "dotfiles\powershell\profile.ps1"
        Destination = Join-Path $HOME ".config\devsetup\profile.ps1"
        Mode = $Mode
    },
    [pscustomobject]@{
        Name = "PowerShell profile loader"
        Source = Join-Path $repositoryRoot "dotfiles\powershell\profile-loader.ps1"
        Destination = [string]$PROFILE.CurrentUserAllHosts
        Mode = "Copy"
    },
    [pscustomobject]@{
        Name = "Starship configuration"
        Source = Join-Path $repositoryRoot "dotfiles\starship\starship.toml"
        Destination = Join-Path $HOME ".config\starship.toml"
        Mode = $Mode
    }
)

function Get-ExistingItem {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-NormalizedPath {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    [System.IO.Path]::GetFullPath($Path)
}

function Get-SymbolicLinkTarget {
    param(
        [Parameter(Mandatory)]
        [System.IO.FileSystemInfo]$Item
    )

    $target = [string]@($Item.Target)[0]
    if ([string]::IsNullOrEmpty($target)) {
        return $null
    }

    if (-not [System.IO.Path]::IsPathRooted($target)) {
        $target = Join-Path $Item.DirectoryName $target
    }

    Get-NormalizedPath $target
}

function Get-MappingState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Mapping
    )

    $existingItem = Get-ExistingItem $Mapping.Destination
    if ($null -eq $existingItem) {
        return "Missing"
    }

    if ($Mapping.Mode -eq "Link") {
        if ($existingItem.LinkType -eq "SymbolicLink") {
            $actualTarget = Get-SymbolicLinkTarget $existingItem
            $expectedTarget = Get-NormalizedPath $Mapping.Source
            if ([System.StringComparer]::OrdinalIgnoreCase.Equals($actualTarget, $expectedTarget)) {
                return "Current"
            }
        }
    }
    elseif (
        -not $existingItem.PSIsContainer -and
        [string]::IsNullOrEmpty([string]$existingItem.LinkType) -and
        (Get-FileHash -LiteralPath $Mapping.Source -Algorithm SHA256).Hash -eq
            (Get-FileHash -LiteralPath $Mapping.Destination -Algorithm SHA256).Hash
    ) {
        return "Current"
    }

    "Conflict"
}

$missingSources = @(
    $mappings |
        Where-Object { -not (Test-Path -LiteralPath $_.Source -PathType Leaf) } |
        ForEach-Object { $_.Source }
)

if ($missingSources.Count -gt 0) {
    throw "The following dotfile sources are missing:`n$($missingSources -join "`n")"
}

$states = @(
    foreach ($mapping in $mappings) {
        [pscustomobject]@{
            Mapping = $mapping
            State = Get-MappingState $mapping
        }
    }
)

$gitIncludeMappings = @(
    [pscustomobject]@{
        Name = "Global Git configuration include"
        Path = Join-Path $HOME ".config\devsetup\gitconfig"
    },
    [pscustomobject]@{
        Name = "Global Git identity include"
        Path = Join-Path $HOME ".config\devsetup\identity.gitconfig"
    }
)

$gitConfigEntries = @(& git config --global --list)
if ($LASTEXITCODE -ne 0) {
    throw "Unable to read the global Git configuration."
}

$gitIncludePrefix = "include.path="
$gitIncludes = @(
    $gitConfigEntries |
        Where-Object { $_.StartsWith($gitIncludePrefix, [System.StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { $_.Substring($gitIncludePrefix.Length) }
)

function Test-GitInclude {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $normalizedPath = Get-NormalizedPath $Path
    foreach ($gitInclude in $gitIncludes) {
        if ([string]::IsNullOrWhiteSpace($gitInclude)) {
            continue
        }

        if ($gitInclude.StartsWith("~/") -or $gitInclude.StartsWith("~\")) {
            $gitInclude = Join-Path $HOME $gitInclude.Substring(2)
        }

        if (
            [System.StringComparer]::OrdinalIgnoreCase.Equals(
                (Get-NormalizedPath $gitInclude),
                $normalizedPath
            )
        ) {
            return $true
        }
    }

    $false
}

$gitIncludeStates = @(
    foreach ($gitIncludeMapping in $gitIncludeMappings) {
        [pscustomobject]@{
            Mapping = $gitIncludeMapping
            State = if (Test-GitInclude $gitIncludeMapping.Path) { "Current" } else { "Missing" }
        }
    }
)

if ($Check) {
    $hasDrift = $false
    foreach ($state in $states) {
        Write-Host ("{0,-8} {1}" -f $state.State.ToUpperInvariant(), $state.Mapping.Destination)
        if ($state.State -ne "Current") {
            $hasDrift = $true
        }
    }

    foreach ($gitIncludeState in $gitIncludeStates) {
        Write-Host (
            "{0,-8} {1}: {2}" -f
                $gitIncludeState.State.ToUpperInvariant(),
                $gitIncludeState.Mapping.Name,
                $gitIncludeState.Mapping.Path
        )
        if ($gitIncludeState.State -ne "Current") {
            $hasDrift = $true
        }
    }

    if ($hasDrift) {
        exit 1
    }

    return
}

$conflicts = @($states | Where-Object { $_.State -eq "Conflict" })
if ($conflicts.Count -gt 0 -and -not $Replace) {
    $conflictingPaths = @(
        $conflicts |
            ForEach-Object { "$($_.Mapping.Destination) ($($_.Mapping.Mode))" }
    ) -join "`n"
    throw "Existing files differ from the requested installation. Re-run with -Replace to back them up first:`n$conflictingPaths"
}

$timestamp = Get-Date -Format "yyyyMMddHHmmssfff"

foreach ($state in $states) {
    if ($state.State -eq "Current") {
        Write-Host "Current: $($state.Mapping.Name)"
        continue
    }

    $mapping = $state.Mapping
    $action = "Install $($mapping.Name) using $($mapping.Mode) mode"
    if (-not $PSCmdlet.ShouldProcess($mapping.Destination, $action)) {
        continue
    }

    $parentDirectory = Split-Path -Parent $mapping.Destination
    if (-not (Test-Path -LiteralPath $parentDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null
    }

    $backupPath = $null
    if ($state.State -eq "Conflict") {
        $backupPath = "$($mapping.Destination).backup.$timestamp"
        if ($null -ne (Get-ExistingItem $backupPath)) {
            throw "Backup path already exists: $backupPath"
        }

        Move-Item -LiteralPath $mapping.Destination -Destination $backupPath
    }

    try {
        if ($mapping.Mode -eq "Link") {
            New-Item -ItemType SymbolicLink -Path $mapping.Destination -Target $mapping.Source | Out-Null
        }
        else {
            Copy-Item -LiteralPath $mapping.Source -Destination $mapping.Destination
        }
    }
    catch {
        # Restore the original target if installing its replacement fails.
        $createdItem = Get-ExistingItem $mapping.Destination
        if ($null -ne $createdItem) {
            Remove-Item -LiteralPath $mapping.Destination -Force
        }

        if ($null -ne $backupPath) {
            Move-Item -LiteralPath $backupPath -Destination $mapping.Destination
        }

        throw
    }

    Write-Host "Installed: $($mapping.Name)"
    if ($null -ne $backupPath) {
        Write-Host "Backup: $backupPath"
    }
}

foreach ($gitIncludeState in $gitIncludeStates) {
    $gitIncludeMapping = $gitIncludeState.Mapping
    if ($gitIncludeState.State -eq "Current") {
        Write-Host "Current: $($gitIncludeMapping.Name)"
    }
    elseif (
        $PSCmdlet.ShouldProcess(
            "Global Git configuration",
            "Include $($gitIncludeMapping.Path)"
        )
    ) {
        & git config --global --add include.path $gitIncludeMapping.Path
        if ($LASTEXITCODE -ne 0) {
            throw "Unable to add $($gitIncludeMapping.Name)."
        }

        Write-Host "Installed: $($gitIncludeMapping.Name)"
    }
}
