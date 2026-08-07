# Dustin's Developer Setup

## Programmer Fonts

- Install [Nerd Fonts](https://www.nerdfonts.com/font-downloads)
- For editors, such as VS, VS Code, or Rider, use 'FiraCode Nerd Font'
- For command-line, use 'FiraMono Nerd Font'

## Themes

- I particularly like [Dracula](https://draculatheme.com/), which offers theemes for tons of different applications.

## Dotfiles

The files under `dotfiles` are the canonical copies of personal configuration. The installation scripts create links from the locations used by each tool back to this repository, so edits made through either path are tracked by Git immediately. The PowerShell profile uses a small regular loader because its standard location may be managed by OneDrive.

The scripts never replace an existing file by default. Use the check or dry-run options first, then opt into replacement. Replaced files are backed up beside their original locations with a timestamp.

### Windows

Run the installer from PowerShell 7:

```PowerShell
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Check
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Replace -WhatIf
pwsh -NoProfile -File .\scripts\Install-Dotfiles.ps1 -Replace
```

The default mode creates symbolic links for:

- `~\.copilot\copilot-instructions.md`
- `~\.config\devsetup\profile.ps1`
- `~\.config\starship.toml`

The installer places a regular loader at `$PROFILE.CurrentUserAllHosts` that loads `~\.config\devsetup\profile.ps1`. This avoids placing an unsupported symbolic link in a OneDrive-managed Documents folder while keeping the full profile canonical in this repository.

Creating symbolic links without elevation requires Windows Developer Mode. If symbolic links are unavailable, use `-Mode Copy`; rerun the installer with `-Check` to detect drift and `-Replace` to synchronize changed copies. The PowerShell loader is always copied because it must remain a regular file.

### macOS

Run the installer with Zsh:

```zsh
zsh scripts/install-dotfiles.zsh --check
zsh scripts/install-dotfiles.zsh --replace --dry-run
zsh scripts/install-dotfiles.zsh --replace
```

The default mode creates symbolic links for:

- `~/.copilot/copilot-instructions.md`
- `~/.config/starship.toml`
- `~/.zshrc`

Use `--copy` when symbolic links are unavailable. As on Windows, `--check` detects drift and `--replace` backs up conflicting files before synchronizing them.

### Local configuration

Keep machine-specific or sensitive configuration outside the repository:

- The PowerShell profile loads `~\.config\powershell\profile.local.ps1` when present.
- The Zsh configuration loads `~/.zshrc.local` when present.

Do not store credentials, tokens, Copilot session state, or other secrets under `dotfiles`. After changing `copilot-instructions.md`, resume or start a Copilot session to reload it; `/instructions` shows the files loaded by the current session.

## Terminal

### Windows

I use Windows Terminal as my terminal interface. A better theme can be acquired at [Windows Terminal Themes](https://windowsterminalthemes.dev/). I particularly like "Dark Pastel".

- Install [PowerShell 7](https://github.com/PowerShell/PowerShell/):
  ```PowerShell
  winget install microsoft.powershell
  ```

- Install [Starship](https://starship.rs/)
  ```PowerShell
  winget install --id Starship.Starship
  ```

- Install [GitHub CLI](https://github.com/cli/cli).
  ```PowerShell
  winget install --id GitHub.cli
  ```

- Login to GitHub.
  ```PowerShell
  gh auth login
  ```

- Install [Midnight Commander](https://midnight-commander.org/).
  ```PowerShell
  winget install --id GNU.MidnightCommander
  ```

### macOS

I use [Warp](https://www.warp.dev/) as my terminal interface.

- Open the macOS terminal and install [Homebrew](https://brew.sh/).
  ```zsh
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  ```

- Install [Nerd Fonts](https://www.nerdfonts.com/font-downloads).
  ```zsh
  brew tap homebrew/cask-fonts
  brew install --cask font-fira-code-nerd-font
  brew install --cask font-fira-mono-nerd-font
  ```

- Install [Warp](https://www.warp.dev/).
  ```zsh
  brew install --cask warp
  ```

- Install [Starship](https://starship.rs/).
  ```zsh
  brew install starship
  ```

- Install [GitHub CLI](https://github.com/cli/cli).
  ```zsh
  brew install gh
  ```

- Login to GitHub.
  ```zsh
  gh auth login
  ```

- Install [Midnight Commander](https://midnight-commander.org/).
  ```zsh
  brew install midnight-commander
  ```
  
## Git Aliases
```zsh
git config --global alias.last 'log -1 HEAD --stat'
git config --global alias.list 'log --oneline'
```