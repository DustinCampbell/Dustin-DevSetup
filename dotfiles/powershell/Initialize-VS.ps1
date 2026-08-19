<#
.SYNOPSIS
Initializes the current PowerShell session as an x64 Visual Studio developer shell.

.DESCRIPTION
Uses Visual Studio Installer's `vswhere.exe` to locate installed Visual Studio instances, imports
the selected installation's developer-shell module, and configures the current PowerShell process
with the x64 build environment.

By default, the newest installed instance is selected, including prerelease channels. Use ChooseVS
to display all discovered instances and select one interactively. The current directory is
preserved, and a global `VS` alias for `devenv.exe` is created after initialization.

.PARAMETER ChooseVS
Displays an interactive menu of installed Visual Studio instances instead of automatically
selecting the newest instance.

.EXAMPLE
Initialize-VS

Initializes the developer shell for the newest installed Visual Studio instance.

.EXAMPLE
Initialize-VS -ChooseVS

Prompts for the Visual Studio instance whose developer shell should be initialized.

.OUTPUTS
None. The command writes selection and initialization status to the host.

.NOTES
Visual Studio Installer and its `vswhere.exe` utility must be installed. The selected Visual Studio
instance must include `Microsoft.VisualStudio.DevShell.dll`.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [switch]$ChooseVS
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-VSInstallLabel {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Install
    )

    $channelId = [string]$Install.installedChannelId
    $lastDotIndex = $channelId.LastIndexOf(".")
    $channelName = if ($lastDotIndex -ge 0) {
        $channelId.Substring($lastDotIndex + 1)
    }
    elseif ([string]::IsNullOrWhiteSpace($channelId)) {
        "unknown channel"
    }
    else {
        $channelId
    }

    return "$($Install.displayName) ($($Install.installationVersion) - $channelName)"
}

function Get-VSInstalls {
    param(
        [Parameter(Mandatory)]
        [string]$VSWherePath,

        [switch]$Latest
    )

    # Include preview channels in both automatic selection and the interactive menu.
    $arguments = @("-prerelease")
    if ($Latest) {
        $arguments += "-latest"
    }
    $arguments += @("-format", "json")

    $installJson = & $VSWherePath @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "vswhere.exe failed with exit code $LASTEXITCODE."
    }

    $jsonText = $installJson -join [Environment]::NewLine
    if ([string]::IsNullOrWhiteSpace($jsonText)) {
        return
    }

    $jsonText | ConvertFrom-Json
}

$vsWherePath = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vsWherePath -PathType Leaf)) {
    throw "Visual Studio Installer's vswhere.exe was not found at '$vsWherePath'."
}

if ($ChooseVS) {
    $vsInstalls = @(Get-VSInstalls -VSWherePath $vsWherePath)
    if ($vsInstalls.Count -eq 0) {
        throw "No Visual Studio installations were found."
    }

    Write-Host ""
    for ($index = 0; $index -lt $vsInstalls.Count; $index++) {
        $label = Get-VSInstallLabel -Install $vsInstalls[$index]
        Write-Host ("    {0} - {1}" -f ($index + 1), $label)
    }

    Write-Host ""
    $choiceText = Read-Host "Choose a Visual Studio version to initialize"
    $choice = 0
    if (
        -not [int]::TryParse($choiceText, [ref]$choice) -or
        $choice -lt 1 -or
        $choice -gt $vsInstalls.Count
    ) {
        throw "Choose a number from 1 through $($vsInstalls.Count)."
    }

    $vsInstall = $vsInstalls[$choice - 1]
}
else {
    $vsInstalls = @(Get-VSInstalls -VSWherePath $vsWherePath -Latest)
    if ($vsInstalls.Count -eq 0) {
        throw "No Visual Studio installations were found."
    }

    $vsInstall = $vsInstalls[0]
}

$vsPath = [string]$vsInstall.installationPath
$devShellModulePath = Join-Path $vsPath "Common7\Tools\Microsoft.VisualStudio.DevShell.dll"
if (-not (Test-Path -LiteralPath $devShellModulePath -PathType Leaf)) {
    throw "The Visual Studio developer-shell module was not found at '$devShellModulePath'."
}

Write-Host ""
Write-Host "Initializing dev prompt for $(Get-VSInstallLabel -Install $vsInstall)..."
Write-Host ""

# SkipAutomaticLocation keeps the caller in the directory from which initialization was requested.
Import-Module $devShellModulePath
Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments "-arch=x64"

Write-Host ""
Set-Alias -Name VS -Value devenv.exe -Scope Global
