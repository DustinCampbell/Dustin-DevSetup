# Dustin's Developer Setup

## Setup

The setup commands install missing tools first, ask for confirmation once, and then install the
managed dotfiles. Package versions are not pinned; package managers and official release endpoints
provide the current stable releases.

### Windows

Windows setup requires
[Windows Package Manager](https://learn.microsoft.com/windows/package-manager/winget/)
and can run from Windows PowerShell before PowerShell 7 is installed:

```PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup.ps1 -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Setup.ps1
```

It installs:

- Git for Windows
- GitHub CLI
- PowerShell 7
- Starship
- Windows Terminal
- FiraCode and FiraMono Nerd Fonts for the current user

Use `-SkipFonts` to omit fonts, `-Mode Copy` when symbolic links are unavailable, or `-Replace` to
back up and replace conflicting dotfiles.

### macOS

macOS setup installs Homebrew when necessary, then uses `Brewfile` to install GitHub CLI, Starship,
and the two Nerd Font families:

```zsh
bash scripts/setup.sh --dry-run
bash scripts/setup.sh
```

Use `--skip-fonts`, `--copy`, or `--replace` for the corresponding setup options.

### Linux

Linux setup currently supports Ubuntu and Debian. It installs Git when missing, GitHub CLI from its
official package repository, Starship under `~/.local/bin`, and the two Nerd Font families for the
current user:

```bash
bash scripts/setup.sh --dry-run
bash scripts/setup.sh
```

Use `--skip-fonts` for servers and other machines that do not render a desktop.

### Tools only

Run tool provisioning without changing dotfiles:

```PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\Install-Tools.ps1
```

```bash
bash scripts/install-tools.sh
```

Use `-WhatIf` or `--dry-run` to inspect the plan, and `-Yes` or `--yes` for unattended installation.

### GitHub Codespaces

In [Codespaces settings](https://github.com/settings/codespaces), enable automatic dotfile
installation and select this repository. Codespaces runs the root `install.sh`, which installs only
missing user-local Starship and the managed dotfiles. Git, GitHub CLI, and authentication are
already supplied by Codespaces; desktop fonts are rendered by the client and are not installed in
the container. The installer preserves the Codespaces-provided Git identity and signing
configuration while adding the managed aliases.

Changes apply automatically only to newly created codespaces. In an existing codespace, clone this
repository and run:

```bash
bash install.sh
```

### After setup

Authenticate GitHub CLI on local machines:

```text
gh auth login
```

For editors such as Visual Studio, Visual Studio Code, or Rider, use **FiraCode Nerd Font**. For
terminals, use **FiraMono Nerd Font**. Application themes remain manual;
[Dracula](https://draculatheme.com/) is the preferred theme where available.

## Dotfiles

The files under `dotfiles` are the canonical copies of personal configuration. The installation
scripts create links from the locations used by each tool back to this repository, so edits made
through either path are tracked by Git immediately. Small loaders preserve host-managed PowerShell
and Bash startup files rather than replacing them.

The scripts never replace an existing file by default. Use the check or dry-run options first, then
opt into replacement. Replaced files are backed up beside their original locations with a
timestamp.

### Dotfiles only on Windows

Run the installer from PowerShell 7:

```PowerShell
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Check
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Replace -WhatIf
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Replace
```

The default mode creates symbolic links for:

- `~\.copilot\copilot-instructions.md`
- `~\.config\devsetup\Initialize-VS.ps1`
- `~\.config\devsetup\Stop-BuildProcesses.ps1`
- `~\.config\devsetup\gitconfig`
- `~\.config\devsetup\identity.gitconfig`
- `~\.config\devsetup\profile.ps1`
- `~\.config\starship.toml`

The installer places a regular loader at `$PROFILE.CurrentUserAllHosts` that loads
`~\.config\devsetup\profile.ps1`. This avoids placing an unsupported symbolic link in a
OneDrive-managed Documents folder while keeping the full profile canonical in this repository.

Creating symbolic links without elevation requires Windows Developer Mode. If symbolic links are
unavailable, use `-Mode Copy`; rerun the installer with `-Check` to detect drift and `-Replace` to
synchronize changed copies. The PowerShell loader is always copied because it must remain a regular
file.

### Dotfiles only on macOS

Run the shared Unix installer with Bash:

```zsh
bash scripts/install-dotfiles.sh --check
bash scripts/install-dotfiles.sh --replace --dry-run
bash scripts/install-dotfiles.sh --replace
```

The default mode creates symbolic links for:

- `~/.copilot/copilot-instructions.md`
- `~/.config/devsetup/gitconfig`
- `~/.config/devsetup/identity.gitconfig`
- `~/.config/starship.toml`
- `~/.zshrc`

Use `--copy` when symbolic links are unavailable. As on Windows, `--check` detects drift and
`--replace` backs up conflicting files before synchronizing them.

### Dotfiles only on Linux

Run the shared Unix installer with Bash:

```bash
bash scripts/install-dotfiles.sh --check
bash scripts/install-dotfiles.sh --replace --dry-run
bash scripts/install-dotfiles.sh --replace
```

The default mode creates symbolic links for:

- `~/.copilot/copilot-instructions.md`
- `~/.config/devsetup/bashrc`
- `~/.config/devsetup/gitconfig`
- `~/.config/devsetup/identity.gitconfig`
- `~/.config/starship.toml`

The installer preserves an existing `~/.bashrc` and appends one idempotent loader for the managed
Bash configuration. It initializes Starship only when the executable is installed, so the shell
remains usable without it.

### Local configuration

Keep machine-specific or sensitive configuration outside the repository:

- The PowerShell profile loads `~\.config\powershell\profile.local.ps1` when present.
- The Bash configuration loads `~/.bashrc.local` when present.
- The Zsh configuration loads `~/.zshrc.local` when present.

Do not store credentials, tokens, Copilot session state, or other secrets under `dotfiles`. After
changing `copilot-instructions.md`, resume or start a Copilot session to reload it; `/instructions`
shows the files loaded by the current session.

## PowerShell functions

The managed PowerShell profile provides development-specific helper functions.

### `Initialize-VS`

The installed `Initialize-VS.ps1` command uses Visual Studio Installer's `vswhere.exe` to initialize
the current PowerShell session as an x64 developer shell. It selects the newest Visual Studio
instance by default, including prerelease channels. Pass `-ChooseVS` to select interactively from
all installed instances. Initialization preserves the current directory and creates a global `VS`
alias for `devenv.exe`.

```PowerShell
Initialize-VS
Initialize-VS -ChooseVS
init-vs -ChooseVS
```

### `Stop-BuildProcesses`

The installed `Stop-BuildProcesses.ps1` command finds the Git repository containing the current
directory and stops only `msbuild`, build-related `dotnet`, and `VBCSCompiler` processes whose
executable path, command line, or process ancestry references that repository. Processes with a
current Visual Studio ancestor are excluded in repository and process-ID modes unless
`-IncludeVisualStudio` is specified. Use `-Id` when a build failure identifies the locking process,
or `-All` to opt into the previous machine-wide behavior, including Visual Studio builds. `-Name`
narrows the process kinds, `-StartedAfter` excludes older processes, and `-PassThru` returns details
about each stopped process.

Preview candidates before stopping them:

```PowerShell
& "$HOME\.config\devsetup\Stop-BuildProcesses.ps1" -WhatIf
& "$HOME\.config\devsetup\Stop-BuildProcesses.ps1" -RepositoryRoot . -Name msbuild,VBCSCompiler
& "$HOME\.config\devsetup\Stop-BuildProcesses.ps1" -Id 1234 -WhatIf
& "$HOME\.config\devsetup\Stop-BuildProcesses.ps1" -All -Confirm
```

## Terminal

### Windows

Use Windows Terminal. Themes from
[Windows Terminal Themes](https://windowsterminalthemes.dev/) can be applied manually;
**Dark Pastel** is the preferred option.

### macOS

Use the built-in Terminal with Zsh. No third-party terminal application is provisioned.

## Git Configuration

Aliases are stored in `dotfiles/git/gitconfig`, while personal identity is stored separately in
`dotfiles/git/identity.gitconfig`. Local-machine installers include both files. Codespaces includes
only the aliases so its system-managed identity and signing configuration remain authoritative.