<#
.SYNOPSIS
Stops build processes selected by repository, process ID, or an explicit machine-wide scope.

.DESCRIPTION
Stops `msbuild`, build-related `dotnet`, and `VBCSCompiler` processes while avoiding the
machine-wide behavior of a name-only process search by default.

Without a scope parameter, the command finds the Git repository containing the current directory.
Repository mode selects processes whose executable path, command line, or chronologically valid
process ancestry references that repository. Generic `dotnet` processes are excluded unless their
command line identifies an MSBuild or compiler-server invocation.

Repository and process-ID modes exclude processes with a current Visual Studio ancestor unless
IncludeVisualStudio is specified. All mode intentionally restores the previous machine-wide
behavior, including Visual Studio builds. Use WhatIf to inspect every candidate before stopping it.

.PARAMETER RepositoryRoot
A file or directory within the repository whose build processes should be stopped. The command
walks up from this path to find the nearest `.git` file or directory. The current directory is used
when this parameter is omitted.

.PARAMETER Id
One or more exact process IDs reported by a build failure or discovered through another trusted
source. Each process must also match Name and the other supplied safety filters.

.PARAMETER All
Selects every running process that matches Name and StartedAfter. This mode includes processes
owned by Visual Studio and should be used only when machine-wide cleanup is intentional.

.PARAMETER Name
The build process kinds to select. Valid values are `msbuild`, `dotnet`, and `VBCSCompiler`. All
three are selected by default.

.PARAMETER StartedAfter
Selects only processes started at or after this time. This can further limit cleanup to processes
created during a known build attempt.

.PARAMETER IncludeVisualStudio
Allows repository or process-ID mode to select processes with a current `devenv` ancestor.

.PARAMETER PassThru
Returns a descriptive object for each process successfully stopped. By default, the command does
not write stopped processes to the pipeline.

.EXAMPLE
Stop-BuildProcesses -WhatIf

Previews build processes associated with the Git repository containing the current directory.

.EXAMPLE
Stop-BuildProcesses -RepositoryRoot D:\src\project -Name msbuild,VBCSCompiler

Stops MSBuild and compiler-server processes associated with the repository containing
`D:\src\project`.

.EXAMPLE
Stop-BuildProcesses -Id 1234 -StartedAfter (Get-Date).AddMinutes(-10) -WhatIf

Previews process 1234 only if it is a selected build process started within the last ten minutes.

.EXAMPLE
Stop-BuildProcesses -All -Name VBCSCompiler -Confirm

Prompts before stopping each VBCSCompiler process on the machine.

.OUTPUTS
System.Management.Automation.PSCustomObject when PassThru is specified. Otherwise, this command
produces no pipeline output.

.NOTES
Repository matching deliberately fails closed. A process that cannot be tied to the repository is
not selected; prefer Id when a lock diagnostic identifies the responsible process.
#>
[CmdletBinding(
    SupportsShouldProcess,
    ConfirmImpact = "Medium",
    DefaultParameterSetName = "Repository"
)]
param(
    [Parameter(Position = 0, ParameterSetName = "Repository")]
    [string]$RepositoryRoot,

    [Parameter(Mandatory, ParameterSetName = "ProcessId")]
    [ValidateCount(1, 64)]
    [ValidateRange(1, 2147483647)]
    [int[]]$Id,

    [Parameter(Mandatory, ParameterSetName = "All")]
    [switch]$All,

    [ValidateCount(1, 3)]
    [ValidateSet("msbuild", "dotnet", "VBCSCompiler")]
    [string[]]$Name = @("msbuild", "dotnet", "VBCSCompiler"),

    [datetime]$StartedAfter,

    [Parameter(ParameterSetName = "Repository")]
    [Parameter(ParameterSetName = "ProcessId")]
    [switch]$IncludeVisualStudio,

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Accept any path inside a worktree so callers do not need to locate the repository root
# themselves.
function Resolve-GitRepositoryRoot {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = (Get-Location).Path
    }

    $item = Get-Item -LiteralPath $Path
    $directory = if ($item.PSIsContainer) { $item } else { $item.Directory }

    while ($null -ne $directory) {
        if (Test-Path -LiteralPath (Join-Path $directory.FullName ".git")) {
            $fullName = [System.IO.Path]::GetFullPath($directory.FullName)
            $pathRoot = [System.IO.Path]::GetPathRoot($fullName)
            if (-not $fullName.Equals($pathRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                $fullName = $fullName.TrimEnd("\/".ToCharArray())
            }

            return $fullName
        }

        $directory = $directory.Parent
    }

    throw "'$Path' is not inside a Git repository. Specify -RepositoryRoot or use -All."
}

# Path boundaries prevent a root such as D:\src\repo from matching a sibling such as D:\src\repo2.
function Test-IsPathBoundary {
    param(
        [char]$Character
    )

    if ([char]::IsWhiteSpace($Character)) {
        return $true
    }

    switch ($Character) {
        '"' { return $true }
        "'" { return $true }
        "=" { return $true }
        ":" { return $true }
        ";" { return $true }
        "," { return $true }
        "(" { return $true }
        ")" { return $true }
        "[" { return $true }
        "]" { return $true }
        "{" { return $true }
        "}" { return $true }
    }

    return $false
}

function Test-TextReferencesPath {
    param(
        [AllowNull()]
        [string]$Text,

        [Parameter(Mandatory)]
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $false
    }

    $separator = [System.IO.Path]::DirectorySeparatorChar
    $normalizedText = $Text.Replace([System.IO.Path]::AltDirectorySeparatorChar, $separator)
    $normalizedPath = $Path.Replace([System.IO.Path]::AltDirectorySeparatorChar, $separator)
    $pathEndsInSeparator = $normalizedPath[$normalizedPath.Length - 1] -eq $separator
    $searchIndex = 0

    while ($searchIndex -lt $normalizedText.Length) {
        $matchIndex = $normalizedText.IndexOf(
            $normalizedPath,
            $searchIndex,
            [System.StringComparison]::OrdinalIgnoreCase
        )

        if ($matchIndex -lt 0) {
            return $false
        }

        $beforeMatches = (
            $matchIndex -eq 0 -or
            (Test-IsPathBoundary -Character $normalizedText[$matchIndex - 1])
        )
        $afterIndex = $matchIndex + $normalizedPath.Length
        $afterMatches = (
            $afterIndex -eq $normalizedText.Length -or
            $pathEndsInSeparator -or
            $normalizedText[$afterIndex] -eq $separator -or
            (Test-IsPathBoundary -Character $normalizedText[$afterIndex])
        )

        if ($beforeMatches -and $afterMatches) {
            return $true
        }

        $searchIndex = $matchIndex + 1
    }

    return $false
}

# Build workers may omit project paths, so repository evidence can come from a valid ancestor.
function Get-RepositoryMatchReason {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$Process,

        [Parameter(Mandatory)]
        [hashtable]$ProcessesById,

        [Parameter(Mandatory)]
        [string]$Root
    )

    $currentProcess = $Process
    $currentStartTime = ConvertTo-ProcessStartTime -CreationDate $currentProcess.CreationDate
    $isCandidate = $true
    $visitedProcessIds = [System.Collections.Generic.HashSet[int]]::new()

    while (
        $null -ne $currentProcess -and
        $visitedProcessIds.Add([int]$currentProcess.ProcessId)
    ) {
        $processDescription = if ($isCandidate) {
            "process"
        }
        else {
            "ancestor PID $($currentProcess.ProcessId)"
        }

        if (Test-TextReferencesPath -Text $currentProcess.ExecutablePath -Path $Root) {
            return "$processDescription executable path"
        }

        if (Test-TextReferencesPath -Text $currentProcess.CommandLine -Path $Root) {
            return "$processDescription command line"
        }

        $parentProcessId = [int]$currentProcess.ParentProcessId
        if ($parentProcessId -le 0 -or -not $ProcessesById.ContainsKey($parentProcessId)) {
            break
        }

        $parentProcess = $ProcessesById[$parentProcessId]
        $parentStartTime = ConvertTo-ProcessStartTime -CreationDate $parentProcess.CreationDate

        # A parent PID can be reused after it exits; a newer process cannot be this
        # process's parent.
        if (
            $null -eq $currentStartTime -or
            $null -eq $parentStartTime -or
            $parentStartTime -gt $currentStartTime
        ) {
            break
        }

        $currentProcess = $parentProcess
        $currentStartTime = $parentStartTime
        $isCandidate = $false
    }

    return $null
}

# Scoped modes protect builds launched by Visual Studio unless the caller explicitly opts in.
function Test-HasVisualStudioAncestor {
    param(
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$Process,

        [Parameter(Mandatory)]
        [hashtable]$ProcessesById
    )

    $parentProcessId = [int]$Process.ParentProcessId
    $visitedProcessIds = [System.Collections.Generic.HashSet[int]]::new()

    while (
        $parentProcessId -gt 0 -and
        $visitedProcessIds.Add($parentProcessId) -and
        $ProcessesById.ContainsKey($parentProcessId)
    ) {
        $parentProcess = $ProcessesById[$parentProcessId]
        $parentProcessName = [System.IO.Path]::GetFileNameWithoutExtension($parentProcess.Name)
        if ($parentProcessName -ieq "devenv") {
            return $true
        }

        $parentProcessId = [int]$parentProcess.ParentProcessId
    }

    return $false
}

# dotnet hosts arbitrary applications, so repository mode accepts only recognizable build commands.
function Test-IsDotNetBuildProcess {
    param(
        [AllowNull()]
        [string]$CommandLine
    )

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $false
    }

    if (
        $CommandLine.Contains("MSBuild.dll", [System.StringComparison]::OrdinalIgnoreCase) -or
        $CommandLine.Contains("VBCSCompiler.dll", [System.StringComparison]::OrdinalIgnoreCase)
    ) {
        return $true
    }

    return [regex]::IsMatch(
        $CommandLine,
        "(?i)(?:^|\s)(?:build|msbuild)(?=\s|$)"
    )
}

function ConvertTo-ProcessStartTime {
    param(
        [AllowNull()]
        [object]$CreationDate
    )

    if ($null -eq $CreationDate -or [string]::IsNullOrWhiteSpace([string]$CreationDate)) {
        return $null
    }

    return ([datetime]$CreationDate).ToUniversalTime()
}

# Capture one process snapshot so name, ancestry, and repository checks use a consistent view.
$requestedNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
foreach ($processName in $Name) {
    [void]$requestedNames.Add([System.IO.Path]::GetFileNameWithoutExtension($processName))
}

$allProcesses = @(Get-CimInstance -ClassName Win32_Process)
$processesById = @{}
foreach ($process in $allProcesses) {
    $processesById[[int]$process.ProcessId] = $process
}

$requestedProcessIds = [System.Collections.Generic.HashSet[int]]::new()
if ($PSCmdlet.ParameterSetName -eq "ProcessId") {
    foreach ($processId in $Id) {
        [void]$requestedProcessIds.Add($processId)

        if (-not $processesById.ContainsKey($processId)) {
            Write-Warning "Process $processId is no longer running."
            continue
        }

        $runningProcessName = [System.IO.Path]::GetFileNameWithoutExtension(
            $processesById[$processId].Name
        )
        if (-not $requestedNames.Contains($runningProcessName)) {
            Write-Warning (
                "Process $processId is '$runningProcessName', which is not selected by -Name."
            )
        }
    }
}

$resolvedRepositoryRoot = if ($PSCmdlet.ParameterSetName -eq "Repository") {
    Resolve-GitRepositoryRoot -Path $RepositoryRoot
}
else {
    $null
}

$startedAfterUtc = if ($PSBoundParameters.ContainsKey("StartedAfter")) {
    $StartedAfter.ToUniversalTime()
}
else {
    $null
}

$candidates = [System.Collections.Generic.List[object]]::new()
foreach ($process in $allProcesses) {
    $processName = [System.IO.Path]::GetFileNameWithoutExtension($process.Name)
    if (-not $requestedNames.Contains($processName)) {
        continue
    }

    $processId = [int]$process.ProcessId
    if (
        $PSCmdlet.ParameterSetName -eq "ProcessId" -and
        -not $requestedProcessIds.Contains($processId)
    ) {
        continue
    }

    $startTime = ConvertTo-ProcessStartTime -CreationDate $process.CreationDate
    if ($null -eq $startTime) {
        Write-Verbose "Skipping $processName (PID $processId): its start time is unavailable."
        continue
    }

    if ($null -ne $startedAfterUtc -and $startTime -lt $startedAfterUtc) {
        Write-Verbose "Skipping $processName (PID $processId): it predates -StartedAfter."
        continue
    }

    # All mode deliberately preserves the legacy behavior, including Visual Studio-owned processes.
    if (
        $PSCmdlet.ParameterSetName -ne "All" -and
        -not $IncludeVisualStudio -and
        (Test-HasVisualStudioAncestor -Process $process -ProcessesById $processesById)
    ) {
        Write-Verbose "Skipping $processName (PID $processId): it belongs to Visual Studio."
        continue
    }

    $matchReason = switch ($PSCmdlet.ParameterSetName) {
        "Repository" {
            Get-RepositoryMatchReason `
                -Process $process `
                -ProcessesById $processesById `
                -Root $resolvedRepositoryRoot
        }
        "ProcessId" { "explicit process ID" }
        "All" { "explicit -All" }
    }

    if ([string]::IsNullOrWhiteSpace($matchReason)) {
        continue
    }

    if (
        $PSCmdlet.ParameterSetName -eq "Repository" -and
        $processName -ieq "dotnet" -and
        -not (Test-IsDotNetBuildProcess -CommandLine $process.CommandLine)
    ) {
        Write-Verbose "Skipping dotnet (PID $processId): its command line is not build-related."
        continue
    }

    $candidates.Add(
        [pscustomobject]@{
            Name = $processName
            Id = $processId
            StartTime = $startTime
            ParentProcessId = [int]$process.ParentProcessId
            ExecutablePath = [string]$process.ExecutablePath
            CommandLine = [string]$process.CommandLine
            MatchReason = $matchReason
        }
    )
}

$candidates = @($candidates | Sort-Object StartTime, Id)
if ($candidates.Count -eq 0) {
    $scopeDescription = switch ($PSCmdlet.ParameterSetName) {
        "Repository" { "repository '$resolvedRepositoryRoot'" }
        "ProcessId" { "the requested process IDs" }
        "All" { "the selected process names" }
    }

    Write-Warning "No matching build processes were found for $scopeDescription."
    return
}

foreach ($candidate in $candidates) {
    $commandDescription = $candidate.CommandLine
    if ([string]::IsNullOrWhiteSpace($commandDescription)) {
        $commandDescription = $candidate.ExecutablePath
    }
    if ([string]::IsNullOrWhiteSpace($commandDescription)) {
        $commandDescription = "<command line unavailable>"
    }

    $commandDescription = $commandDescription.Trim()
    if ($commandDescription.Length -gt 180) {
        $commandDescription = $commandDescription.Substring(0, 177) + "..."
    }

    $target = (
        "{0} (PID {1}, started {2:u}, matched by {3}): {4}" -f
            $candidate.Name,
            $candidate.Id,
            $candidate.StartTime,
            $candidate.MatchReason,
            $commandDescription
    )

    if (-not $PSCmdlet.ShouldProcess($target, "Stop build process")) {
        continue
    }

    # Re-read process metadata immediately before stopping to guard against PID reuse.
    $currentProcess = @(
        Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($candidate.Id)"
    )
    if ($currentProcess.Count -eq 0) {
        Write-Warning (
            "$($candidate.Name) (PID $($candidate.Id)) exited before it could be stopped."
        )
        continue
    }

    $currentProcessName = [System.IO.Path]::GetFileNameWithoutExtension($currentProcess[0].Name)
    $currentStartTime = ConvertTo-ProcessStartTime -CreationDate $currentProcess[0].CreationDate
    if (
        $currentProcessName -ine $candidate.Name -or
        $currentStartTime -ne $candidate.StartTime
    ) {
        Write-Warning "PID $($candidate.Id) was reused; the replacement process was not stopped."
        continue
    }

    Stop-Process -Id $candidate.Id -Force -Confirm:$false
    if ($PassThru) {
        $candidate
    }
}
