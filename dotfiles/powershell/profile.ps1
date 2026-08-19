function Set-LocationProjects() {
    $envName = "PROJECTS_ROOT"
    $projectsPath = [Environment]::GetEnvironmentVariable($envName);

    if ($projectsPath -eq $null) {
        Write-Error "Please define the '${envName}' environment variable to set that location."
    }
    elseif (-not (Test-Path $projectsPath)) {
        Write-Error "'${envName}' environment variable does not exist: {$projectsPath}."
    }
    else {
        Set-Location -Path $projectsPath
    }
}

function Stop-ProcessesWithName($name) {
    $processes = Get-Process -Name $name -ErrorAction SilentlyContinue
    foreach ($process in $processes) {
        Stop-Process -Id $process.Id -Force
    }
}

function Stop-MSBuildProcesses {
    Stop-ProcessesWithName "msbuild"
}

function Stop-DotnetProcesses {
    Stop-ProcessesWithName "dotnet"
}

function Stop-VBCSCompilerProcesses {
    Stop-ProcessesWithName "VBCSCompiler"
}

$initializeVsScript = Join-Path $PSScriptRoot "Initialize-VS.ps1"
$stopBuildProcessesScript = Join-Path $PSScriptRoot "Stop-BuildProcesses.ps1"
Set-Alias Initialize-VS $initializeVsScript
Set-Alias init-vs $initializeVsScript
Set-Alias projects Set-LocationProjects
Set-Alias open Explorer
Set-Alias stop-processes Stop-ProcessesWithName
Set-Alias stop-msbuild Stop-MSBuildProcesses
Set-Alias stop-dotnet Stop-DotnetProcesses
Set-Alias stop-vbcscompiler Stop-VBCSCompilerProcesses
Set-Alias Stop-BuildProcesses $stopBuildProcessesScript
Set-Alias stop-buildprocs $stopBuildProcessesScript
Remove-Variable initializeVsScript
Remove-Variable stopBuildProcessesScript

Set-LocationProjects

# Initialize Starship Prompt
$ENV:STARSHIP_CONFIG = Join-Path $HOME ".config\starship.toml"
Invoke-Expression (&starship init powershell)

$localProfile = Join-Path $HOME ".config\powershell\profile.local.ps1"
if (Test-Path -LiteralPath $localProfile) {
    . $localProfile
}
