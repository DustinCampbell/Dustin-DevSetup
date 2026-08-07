$managedProfile = Join-Path $HOME ".config\devsetup\profile.ps1"
if (-not (Test-Path -LiteralPath $managedProfile -PathType Leaf)) {
    throw "The managed PowerShell profile is missing: $managedProfile"
}

. $managedProfile
Remove-Variable managedProfile
