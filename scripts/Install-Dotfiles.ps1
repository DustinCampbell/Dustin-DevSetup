<#
.SYNOPSIS
Installs or checks the managed Windows dotfiles.

.DESCRIPTION
Maps the canonical files under `dotfiles` to their user-specific destinations. Link mode creates
symbolic links back to the repository so changes remain immediately visible to Git. Copy mode
creates independent copies for environments where symbolic links are unavailable.

Each destination is classified as Current, Missing, or Conflict before any files are changed.
Conflicts stop installation unless Replace is specified. Replaced items are moved to timestamped
backup paths and restored if installing their replacements fails.

The PowerShell profile loader is always copied because its OneDrive-managed destination must remain
a regular file. The installer also ensures that the managed Git configuration and identity files
are included by the global Git configuration. Use Check for a read-only drift report or WhatIf to
preview installation actions.

.PARAMETER Mode
Controls how managed files are installed. Link creates symbolic links to the canonical repository
files and is the default. Copy creates regular files containing the current canonical content.

.PARAMETER Replace
Allows conflicting destinations to be moved to timestamped backup paths before their replacements
are installed. Existing files are never replaced without this switch.

.PARAMETER Check
Reports the state of every file mapping and required global Git include without making changes.
The script exits with code 1 when any item is missing or conflicting.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Check

Checks all managed files and Git includes for drift.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Replace -WhatIf

Previews link installation, including any conflicting destinations that would be backed up.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Mode Copy -Replace

Installs regular copies and backs up conflicting destinations.

.OUTPUTS
None. The script writes status information to the host and uses its exit code to report check
results or failures.

.NOTES
Run this script with PowerShell 7 on Windows. Link mode requires permission to create symbolic
links, such as Windows Developer Mode or an elevated shell.
#>
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

# Most destinations honor Mode; the profile loader is copied to keep its host-managed path regular.
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
        Name = "Build process cleanup command"
        Source = Join-Path $repositoryRoot "dotfiles\powershell\Stop-BuildProcesses.ps1"
        Destination = Join-Path $HOME ".config\devsetup\Stop-BuildProcesses.ps1"
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

# Relative link targets are interpreted from the link's directory before paths are compared.
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

# A mapping is current only when its link target or copied content exactly matches the source.
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

# Validate every canonical source before examining or changing destinations.
$missingSources = @(
    $mappings |
        Where-Object { -not (Test-Path -LiteralPath $_.Source -PathType Leaf) } |
        ForEach-Object { $_.Source }
)

if ($missingSources.Count -gt 0) {
    throw "The following dotfile sources are missing:`n$($missingSources -join "`n")"
}

# Capture all mapping states up front so conflicts are discovered before the first mutation.
$states = @(
    foreach ($mapping in $mappings) {
        [pscustomobject]@{
            Mapping = $mapping
            State = Get-MappingState $mapping
        }
    }
)

# Git include entries are configuration state rather than file mappings and are checked separately.
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

        # Git may persist home-relative include paths even when the requested path is absolute.
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

# Capture Git include state once so checking and installation report the same initial view.
$gitIncludeStates = @(
    foreach ($gitIncludeMapping in $gitIncludeMappings) {
        [pscustomobject]@{
            Mapping = $gitIncludeMapping
            State = if (Test-GitInclude $gitIncludeMapping.Path) { "Current" } else { "Missing" }
        }
    }
)

# Check mode is read-only and uses its exit code to make drift detectable by automation.
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

# Refuse every conflicting mapping before applying any partial installation.
$conflicts = @($states | Where-Object { $_.State -eq "Conflict" })
if ($conflicts.Count -gt 0 -and -not $Replace) {
    $conflictingPaths = @(
        $conflicts |
            ForEach-Object { "$($_.Mapping.Destination) ($($_.Mapping.Mode))" }
    ) -join "`n"
    throw "Existing files differ from the requested installation. Re-run with -Replace to back them up first:`n$conflictingPaths"
}

# One timestamp groups all backup files produced by this installation attempt.
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

# Add Git includes only after their target files have been installed successfully.
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
