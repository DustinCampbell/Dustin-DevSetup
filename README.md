# Dustin's Developer Setup

## Programmer Fonts

- Install [Nerd Fonts](https://www.nerdfonts.com/font-downloads)
- For editors, such as VS, VS Code, or Rider, use 'FiraCode Nerd Font'
- For command-line, use 'FiraMono Nerd Font'

## Themes

- I particularly like [Dracula](https://draculatheme.com/), which offers theemes for tons of different applications.

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

  - Copy `files\starship.toml` to `$HOME\.starship\`
  - Copy contents of `files\profile.ps1` into the PowerShell profile at `$PROFILE`

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

  - Copy `files\starship.toml` to `~/.config/`.
  - Copy `files\.zshrc` to `~`.

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