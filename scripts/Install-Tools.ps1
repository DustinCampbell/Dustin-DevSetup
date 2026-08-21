<#
.SYNOPSIS
Installs the managed Windows development tools and Nerd Fonts.

.DESCRIPTION
Checks for a fixed set of Windows development tools with Windows Package Manager and installs only
the packages that are missing. Existing packages are left unchanged rather than upgraded.

Unless SkipFonts is specified, the script also checks the current user's Windows Fonts directory
for the managed FiraCode and FiraMono Nerd Font families. Missing families are downloaded from the
latest Nerd Fonts GitHub release and registered for the current user.

The complete installation plan is displayed before any changes are made. By default, the script
prompts for confirmation. Use Yes for unattended installation or WhatIf to print the plan without
installing anything.

.PARAMETER Yes
Skips the interactive confirmation prompt. Package and font installation failures are still
reported as terminating errors.

.PARAMETER SkipFonts
Excludes Nerd Fonts from discovery and installation. Managed Windows packages are still checked and
installed when missing.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Tools.ps1

Displays missing tools and fonts, then prompts before installing them.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Tools.ps1 -WhatIf

Displays the tools and fonts that would be installed without making changes.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Install-Tools.ps1 -Yes -SkipFonts

Installs missing Windows packages without prompting and does not inspect or install Nerd Fonts.

.OUTPUTS
None. The script writes installation plans and progress to the host.

.NOTES
This script requires Windows Package Manager (`winget.exe`) and network access to the configured
winget source. Font installation also requires access to GitHub releases. Fonts are installed only
for the current user and may require applications to be restarted before they appear.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Yes,

    [switch]$SkipFonts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Keep package metadata declarative so discovery, planning, and installation use the same IDs.
$packages = @(
    [pscustomobject]@{ Name = "Git for Windows"; Id = "Git.Git" },
    [pscustomobject]@{ Name = "GitHub Copilot CLI"; Id = "GitHub.Copilot" },
    [pscustomobject]@{ Name = "GitHub CLI"; Id = "GitHub.cli" },
    [pscustomobject]@{ Name = "PowerShell 7"; Id = "Microsoft.PowerShell" },
    [pscustomobject]@{ Name = "ripgrep"; Id = "BurntSushi.ripgrep.MSVC" },
    [pscustomobject]@{ Name = "Starship"; Id = "Starship.Starship" },
    [pscustomobject]@{ Name = "Windows Terminal"; Id = "Microsoft.WindowsTerminal" }
)

# Asset names address release archives; patterns detect extracted files in the user font directory.
$fontFamilies = @(
    [pscustomobject]@{ Name = "FiraCode Nerd Font"; Asset = "FiraCode"; Pattern = "FiraCodeNerdFont*" },
    [pscustomobject]@{ Name = "FiraMono Nerd Font"; Asset = "FiraMono"; Pattern = "FiraMonoNerdFont*" }
)

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    throw "Windows Package Manager is required. Install App Installer from Microsoft before running setup."
}

# winget list returns zero only when an exact installed-package match is found.
function Test-WingetPackage {
    param(
        [Parameter(Mandatory)]
        [string]$Id
    )

    & $winget.Source list `
        --id $Id `
        --exact `
        --accept-source-agreements `
        --disable-interactivity 2>$null | Out-Null

    $LASTEXITCODE -eq 0
}

$userFontsDirectory = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Fonts"

# Fonts are detected by filename because per-user font registry display names are not standardized.
function Test-FontFamily {
    param(
        [Parameter(Mandatory)]
        [string]$Pattern
    )

    if (-not (Test-Path -LiteralPath $userFontsDirectory -PathType Container)) {
        return $false
    }

    $null -ne (
        Get-ChildItem -LiteralPath $userFontsDirectory -File -Filter $Pattern -ErrorAction SilentlyContinue |
            Select-Object -First 1
    )
}

# Materialize both lists before displaying the plan or requesting confirmation.
$missingPackages = @($packages | Where-Object { -not (Test-WingetPackage $_.Id) })
$missingFonts = @(
    if (-not $SkipFonts) {
        $fontFamilies | Where-Object { -not (Test-FontFamily $_.Pattern) }
    }
)

if ($missingPackages.Count -eq 0 -and $missingFonts.Count -eq 0) {
    Write-Host "All managed Windows tools are installed."
    return
}

Write-Host "The following tools will be installed:"
foreach ($package in $missingPackages) {
    Write-Host "  - $($package.Name) ($($package.Id))"
}
foreach ($font in $missingFonts) {
    Write-Host "  - $($font.Name) (per-user)"
}

# SupportsShouldProcess supplies WhatIfPreference even though installation is performed in batches.
if ($WhatIfPreference) {
    return
}

if (-not $Yes) {
    $response = Read-Host "Continue? [y/N]"
    if ($response -notin "y", "Y", "yes", "YES", "Yes") {
        throw [System.OperationCanceledException]::new("Tool installation was cancelled.")
    }
}

# Install packages first so a winget failure stops before any font files are changed.
foreach ($package in $missingPackages) {
    Write-Host "Installing $($package.Name)..."
    & $winget.Source install `
        --id $package.Id `
        --exact `
        --source winget `
        --accept-source-agreements `
        --accept-package-agreements `
        --disable-interactivity

    if ($LASTEXITCODE -ne 0) {
        throw "winget failed to install $($package.Name) ($($package.Id))."
    }
}

if ($missingFonts.Count -eq 0) {
    return
}

# Per-user fonts require both the font file and a matching HKCU registration.
New-Item -ItemType Directory -Path $userFontsDirectory -Force | Out-Null
$fontRegistryPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
New-Item -Path $fontRegistryPath -Force | Out-Null

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "Dustin-DevSetup-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

# Use a unique staging directory and remove it even when download, extraction, or
# registration fails.
try {
    foreach ($fontFamily in $missingFonts) {
        Write-Host "Installing $($fontFamily.Name)..."
        $archivePath = Join-Path $temporaryDirectory "$($fontFamily.Asset).zip"
        $extractionPath = Join-Path $temporaryDirectory $fontFamily.Asset
        $downloadUri = "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$($fontFamily.Asset).zip"

        Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $archivePath
        Expand-Archive -LiteralPath $archivePath -DestinationPath $extractionPath -Force

        $fontFiles = @(
            Get-ChildItem -LiteralPath $extractionPath -Recurse -File |
                Where-Object { $_.Extension -in ".ttf", ".otf" }
        )

        if ($fontFiles.Count -eq 0) {
            throw "No font files were found in $($fontFamily.Asset).zip."
        }

        foreach ($fontFile in $fontFiles) {
            $destination = Join-Path $userFontsDirectory $fontFile.Name
            Copy-Item -LiteralPath $fontFile.FullName -Destination $destination -Force

            $fontType = if ($fontFile.Extension -eq ".otf") { "OpenType" } else { "TrueType" }
            $registryName = "$($fontFile.BaseName) ($fontType)"
            New-ItemProperty `
                -Path $fontRegistryPath `
                -Name $registryName `
                -Value $destination `
                -PropertyType String `
                -Force | Out-Null
        }
    }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory) {
        Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
    }
}

Write-Host "Nerd Fonts installed. Restart applications that enumerate fonts."
