# Dustin's Developer Setup

## Programmer Fonts

- Install [Nerd Fonts](https://www.nerdfonts.com/font-downloads)
- For editors, such as VS, VS Code, or Rider, use 'FiraMono Nerd Font'
- For command-line, use 'FiraCode Nerd Font'

## Command Prompt

I use Windows Terminal as my terminal interface. A better theme can be acquired at [Windows Terminal Themes](https://windowsterminalthemes.dev/). I particularly like "Dark Pastel".

- Install the latest official release version of [PowerShell 7](https://github.com/PowerShell/PowerShell/releases/)
- Install [Starship](https://starship.rs/)
  - From the Windows command-line, use `winget` to install: `winget install -id Starship.Starship`
- Copy `files\starship.toml` to `$HOME\.starship\`
- Copy contents of `files\profile.ps1` into the PowerShell profile at `$PROFILE`
