function Initialize-VS {
    param(
        [Parameter(Position=0, Mandatory=$false)]
        [Switch]$chooseVS
    )

    function Get-VS-Install-Label($vsInstall) {
        $channelId = $vsInstall.installedChannelId
        $lastDotIndex = $channelId.LastIndexOf(".")
        $channelName = $channelId.Substring($lastDotIndex + 1);

        return "$($vsInstall.displayName) ($($vsInstall.installationVersion) - $($channelName))"
    }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"

    if ($chooseVS) {
        # Launch vswhere.exe to retrieve a list of installed Visual Studio instances
        $vsInstallsJson = &$vswhere -prerelease -format json
        $vsInstalls = $vsInstallsJson | ConvertFrom-Json

        # Display a menu of Visual Studio instances to the user
        Write-Host ""

        $vsInstallLabels = @()
        $index = 1

        foreach ($vsInstall in $vsInstalls) {
            $vsInstallLabel = Get-VS-Install-Label $vsInstall
            $vsInstallLabels += $vsInstallLabel
            Write-Host "    $($index) - $($vsInstallLabel)"
            $index += 1
        }

        Write-Host ""
        $choice = [int](Read-Host "Choose a Visual Studio version to launch")

        $vsInstall = $vsInstalls[$choice - 1]
    }
    else {
        # Launch vswhere.exe to retrieve the newest, last installed Visual Studio instance
        $vsInstallJson = &$vswhere -prerelease -latest -format json
        $vsInstalls = $vsInstallJson | ConvertFrom-Json
        $vsInstall = $vsInstalls[0]
    }

    Write-Host ""
    Write-Host "Initializing dev prompt for $(Get-VS-Install-Label $vsInstall)..."
    Write-Host ""

    $vsPath = $vsInstall.installationPath

    Import-Module (Get-ChildItem $vsPath -Recurse -File -Filter Microsoft.VisualStudio.DevShell.dll).FullName
    Enter-VsDevShell -VsInstallPath $vsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64'

    Write-Host ""

    Set-Alias VS devenv.exe -Scope Global
}

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

Set-Alias init-vs Initialize-VS
Set-Alias projects Set-LocationProjects
Set-Alias open Explorer
Set-Alias stop-processes Stop-ProcessesWithName
Set-Alias stop-msbuild Stop-MSBuildProcesses
Set-Alias stop-dotnet Stop-DotnetProcesses

Set-LocationProjects

# Use new MSBuild terminal logger
$ENV:MSBUILDTERMINALLOGGER = "auto"

# Initialize Starship Prompt
$ENV:STARSHIP_CONFIG = "$HOME\.starship\starship.toml"
Invoke-Expression (&starship init powershell)