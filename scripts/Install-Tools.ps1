[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Yes,

    [switch]$SkipFonts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$packages = @(
    [pscustomobject]@{ Name = "Git for Windows"; Id = "Git.Git" },
    [pscustomobject]@{ Name = "GitHub CLI"; Id = "GitHub.cli" },
    [pscustomobject]@{ Name = "PowerShell 7"; Id = "Microsoft.PowerShell" },
    [pscustomobject]@{ Name = "Starship"; Id = "Starship.Starship" },
    [pscustomobject]@{ Name = "Windows Terminal"; Id = "Microsoft.WindowsTerminal" }
)

$fontFamilies = @(
    [pscustomobject]@{ Name = "FiraCode Nerd Font"; Asset = "FiraCode"; Pattern = "FiraCodeNerdFont*" },
    [pscustomobject]@{ Name = "FiraMono Nerd Font"; Asset = "FiraMono"; Pattern = "FiraMonoNerdFont*" }
)

$winget = Get-Command winget.exe -ErrorAction SilentlyContinue
if ($null -eq $winget) {
    throw "Windows Package Manager is required. Install App Installer from Microsoft before running setup."
}

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

if ($WhatIfPreference) {
    return
}

if (-not $Yes) {
    $response = Read-Host "Continue? [y/N]"
    if ($response -notin "y", "Y", "yes", "YES", "Yes") {
        throw [System.OperationCanceledException]::new("Tool installation was cancelled.")
    }
}

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

New-Item -ItemType Directory -Path $userFontsDirectory -Force | Out-Null
$fontRegistryPath = "HKCU:\Software\Microsoft\Windows NT\CurrentVersion\Fonts"
New-Item -Path $fontRegistryPath -Force | Out-Null

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) "Dustin-DevSetup-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

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
