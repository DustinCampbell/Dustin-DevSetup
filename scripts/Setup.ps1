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

$toolsScript = Join-Path $PSScriptRoot "Install-Tools.ps1"
$dotfilesScript = Join-Path $PSScriptRoot "Install-Dotfiles.ps1"

$toolsArguments = @{
    Yes = $Yes
    SkipFonts = $SkipFonts
}

if ($WhatIfPreference) {
    $toolsArguments.WhatIf = $true
}

& $toolsScript @toolsArguments

$machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
$env:Path = @($machinePath, $userPath) -join [System.IO.Path]::PathSeparator

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

& $pwshPath @dotfilesArguments
if ($LASTEXITCODE -ne 0) {
    throw "The dotfile installer failed with exit code $LASTEXITCODE."
}
