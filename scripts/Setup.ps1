<#
.SYNOPSIS
Sets up the managed Windows development tools and dotfiles.

.DESCRIPTION
Coordinates the Windows setup scripts in the required order. It first invokes Install-Tools.ps1 to
install missing development tools and optional Nerd Fonts. It then refreshes the current process's
PATH so a newly installed PowerShell 7 executable can be discovered without restarting the shell.
Finally, it launches Install-Dotfiles.ps1 under PowerShell 7 because Windows PowerShell and
PowerShell 7 use different profile locations.

Tool-installation parameters are forwarded to Install-Tools.ps1, while dotfile parameters are
forwarded to Install-Dotfiles.ps1. WhatIf is forwarded to both stages. During a dry run where
PowerShell 7 is not yet installed, the dotfile stage is skipped because its destination profile
cannot be determined correctly from Windows PowerShell.

.PARAMETER Yes
Skips the interactive tool-installation confirmation. This parameter is forwarded to
Install-Tools.ps1 and does not alter dotfile conflict handling.

.PARAMETER Replace
Allows Install-Dotfiles.ps1 to back up and replace conflicting dotfile destinations. Existing
dotfiles are never replaced when this switch is omitted.

.PARAMETER SkipFonts
Excludes Nerd Fonts from tool discovery and installation. This parameter is forwarded to
Install-Tools.ps1.

.PARAMETER Mode
Controls how dotfiles are installed. Link creates symbolic links to the canonical repository files
and is the default. Copy installs regular file copies.

.EXAMPLE
.\scripts\Setup.ps1

Displays missing tools, prompts before installation, and installs nonconflicting dotfile links.

.EXAMPLE
.\scripts\Setup.ps1 -WhatIf

Previews tool and dotfile installation without making changes. The dotfile preview is skipped if
PowerShell 7 is not currently available.

.EXAMPLE
.\scripts\Setup.ps1 -Yes -Replace -Mode Copy -SkipFonts

Installs missing packages without prompting, skips fonts, and installs copied dotfiles while backing
up conflicts.

.OUTPUTS
None. The script writes progress from each setup stage to the host.

.NOTES
This script can begin under Windows PowerShell, but dotfile installation always runs under
PowerShell 7. See Install-Tools.ps1 and Install-Dotfiles.ps1 for stage-specific requirements and
behavior.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Yes,

    [switch]$Replace,

    [switch]$SkipFonts,

    [ValidateSet("Link", "Copy")]
    [string]$Mode = "Link"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve companion scripts relative to this file so setup does not depend on the current
# directory.
$toolsScript = Join-Path $PSScriptRoot "Install-Tools.ps1"
$dotfilesScript = Join-Path $PSScriptRoot "Install-Dotfiles.ps1"

# Forward only parameters owned by the tool-installation stage.
$toolsArguments = @{
    Yes = $Yes
    SkipFonts = $SkipFonts
}

if ($WhatIfPreference) {
    $toolsArguments.WhatIf = $true
}

& $toolsScript @toolsArguments

# Refresh PATH after tool installation so this process can discover a newly installed pwsh.exe.
$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = @($machinePath, $userPath) -join [System.IO.Path]::PathSeparator

# Prefer PATH discovery, then check PowerShell 7's standard installation location.
$pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if ($null -eq $pwsh) {
    $candidatePath = Join-Path $env:ProgramFiles "PowerShell\7\pwsh.exe"
    if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
        $pwshPath = $candidatePath
    }
    elseif ($WhatIfPreference) {
        Write-Warning (
            "The dotfile dry run was skipped because PowerShell 7 is not installed. " +
            "Windows PowerShell uses a different profile path."
        )
        return
    }
    else {
        throw "PowerShell 7 was installed but pwsh.exe could not be located."
    }
}
else {
    $pwshPath = $pwsh.Source
}

# Start a fresh PowerShell 7 process so its platform-specific profile path is authoritative.
$dotfilesArguments = @(
    "-NoProfile",
    "-File",
    $dotfilesScript,
    "-Mode",
    $Mode
)

if ($Replace) {
    $dotfilesArguments += "-Replace"
}

if ($WhatIfPreference) {
    Write-Host "PowerShell 7 is available; running Install-Dotfiles.ps1 with -WhatIf."
    $dotfilesArguments += "-WhatIf"
}
else {
    Write-Host "PowerShell 7 is available; running Install-Dotfiles.ps1."
}

# Invoke by argument array so paths and values are passed without command-string quoting.
& $pwshPath @dotfilesArguments
if ($LASTEXITCODE -ne 0) {
    throw "The dotfile installer failed with exit code $LASTEXITCODE."
}
