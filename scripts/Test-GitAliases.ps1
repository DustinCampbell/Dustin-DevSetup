<#
.SYNOPSIS
Validates the managed Git aliases and related configuration.

.DESCRIPTION
Loads `dotfiles/git/gitconfig` as the global Git configuration and exercises its aliases in an
isolated temporary repository. The test verifies log output, staged-diff behavior, unstaging, and
automatic fetch pruning without reading the current user's global or system Git configuration.

The script uses only PowerShell and Git so the same validation can run locally and on the Linux,
macOS, and Windows GitHub-hosted runners.

.EXAMPLE
pwsh -NoProfile -File .\scripts\Test-GitAliases.ps1

Validates the managed Git configuration from the repository root.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repositoryRoot = Split-Path -Parent $PSScriptRoot
$gitConfigPath = Join-Path $repositoryRoot "dotfiles\git\gitconfig"
$temporaryRepository = Join-Path ([System.IO.Path]::GetTempPath()) "devsetup-git-alias-$([guid]::NewGuid())"
$originalGitConfigGlobal = $env:GIT_CONFIG_GLOBAL
$originalGitConfigNoSystem = $env:GIT_CONFIG_NOSYSTEM
$originalGitEditor = $env:GIT_EDITOR
$locationPushed = $false

function Invoke-Git {
    $output = @(& git @args 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "git $($args -join ' ') failed:`n$($output -join "`n")"
    }

    return ($output -join "`n")
}

function Assert-Matches {
    param([string]$Actual, [string]$Pattern, [string]$Description)

    if ($Actual -notmatch $Pattern) {
        throw "$Description`nOutput:`n$Actual"
    }
}

try {
    # Isolate the test from machine-specific aliases, includes, and other Git settings.
    $env:GIT_CONFIG_GLOBAL = $gitConfigPath
    $env:GIT_CONFIG_NOSYSTEM = "1"

    New-Item -ItemType Directory -Path $temporaryRepository | Out-Null
    Push-Location $temporaryRepository
    $locationPushed = $true

    Invoke-Git init --initial-branch=main . | Out-Null
    Invoke-Git config user.name "Alias Validation"
    Invoke-Git config user.email "alias-validation@example.com"

    # Keep the inventory explicit so every configured alias requires behavioral coverage below.
    $testedAliases = @("aliases", "fixup", "last", "list", "reword", "reword-last", "staged", "unstage") | Sort-Object
    $configuredAliases = (Invoke-Git config --name-only --get-regexp "^alias\.") -split "`n" |
        ForEach-Object { $_ -replace "^alias\.", "" } |
        Sort-Object
    $aliasDifferences = Compare-Object -ReferenceObject $testedAliases -DifferenceObject $configuredAliases

    if ($aliasDifferences) {
        $details = $aliasDifferences | ForEach-Object { "$($_.InputObject) $($_.SideIndicator)" }
        throw "The configured and tested alias inventories differ:`n$($details -join "`n")"
    }

    Set-Content -Path tracked.txt -Value "initial" -NoNewline
    Invoke-Git add tracked.txt
    Invoke-Git commit -m "Initial commit" | Out-Null

    $aliases = Invoke-Git aliases
    Assert-Matches $aliases "(?m)^alias\.aliases " "git aliases did not list itself."
    Assert-Matches $aliases "(?m)^alias\.reword " "git aliases did not list the shell-based alias."

    $last = Invoke-Git --no-pager last
    Assert-Matches $last "Initial commit" "git last did not show the latest commit."
    Assert-Matches $last "tracked\.txt" "git last did not show the commit statistics."

    $list = Invoke-Git --no-pager list
    Assert-Matches $list "^[0-9a-f]+ Initial commit$" "git list did not produce the expected one-line log."

    # Exercise both the index and working tree so staged and unstage are behaviorally validated.
    Set-Content -Path tracked.txt -Value "updated" -NoNewline
    Invoke-Git add tracked.txt

    $staged = Invoke-Git --no-pager staged -- tracked.txt
    Assert-Matches $staged "(?m)^\+updated$" "git staged did not show the staged change."

    Invoke-Git unstage tracked.txt | Out-Null

    & git diff --cached --quiet
    if ($LASTEXITCODE -ne 0) {
        throw "git unstage left a staged change."
    }

    & git diff --quiet
    if ($LASTEXITCODE -ne 1) {
        throw "git unstage did not preserve the working-tree change."
    }

    Invoke-Git restore tracked.txt | Out-Null

    Set-Content -Path tracked.txt -Value "fixed" -NoNewline
    Invoke-Git add tracked.txt
    Invoke-Git fixup HEAD | Out-Null

    $fixupSubject = Invoke-Git log -1 --format=%s
    if ($fixupSubject -ne "fixup! Initial commit") {
        throw "git fixup created an unexpected commit subject: $fixupSubject"
    }

    # Suppress the message editor while verifying that the shell alias constructs reword:<commit>.
    $env:GIT_EDITOR = "sh -c true"
    Invoke-Git reword HEAD~1 | Out-Null

    $rewordSubject = Invoke-Git log -1 --format=%s
    if ($rewordSubject -ne "amend! Initial commit") {
        throw "git reword created an unexpected commit subject: $rewordSubject"
    }

    Set-Content -Path latest.txt -Value "latest" -NoNewline
    Invoke-Git add latest.txt
    Invoke-Git commit -m "Latest commit" | Out-Null
    Invoke-Git reword-last -m "Reworded latest commit" | Out-Null

    $rewordLastSubject = Invoke-Git log -1 --format=%s
    if ($rewordLastSubject -ne "Reworded latest commit") {
        throw "git reword-last did not update the latest commit subject: $rewordLastSubject"
    }

    $prune = Invoke-Git config --get fetch.prune
    if ($prune -ne "true") {
        throw "fetch.prune was not enabled."
    }
}
finally {
    if ($locationPushed) {
        Pop-Location
    }

    # Leave both the caller's environment and the temporary filesystem unchanged.
    if ($null -eq $originalGitConfigGlobal) {
        Remove-Item Env:\GIT_CONFIG_GLOBAL -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_CONFIG_GLOBAL = $originalGitConfigGlobal
    }

    if ($null -eq $originalGitConfigNoSystem) {
        Remove-Item Env:\GIT_CONFIG_NOSYSTEM -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_CONFIG_NOSYSTEM = $originalGitConfigNoSystem
    }

    if ($null -eq $originalGitEditor) {
        Remove-Item Env:\GIT_EDITOR -ErrorAction SilentlyContinue
    }
    else {
        $env:GIT_EDITOR = $originalGitEditor
    }

    if (Test-Path -LiteralPath $temporaryRepository) {
        Remove-Item -LiteralPath $temporaryRepository -Recurse -Force
    }
}
