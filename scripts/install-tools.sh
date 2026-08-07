#!/usr/bin/env bash

# macOS Bash 3.2 treats declared empty arrays as unset under nounset.
set -eo pipefail

yes=false
skip_fonts=false
codespaces=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: install-tools.sh [--yes] [--skip-fonts] [--codespaces] [--dry-run]

  --yes         Skip the single installation confirmation.
  --skip-fonts  Do not install desktop Nerd Fonts.
  --codespaces  Install only tools appropriate for GitHub Codespaces.
  --dry-run     Show the installation plan without changing the machine.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --yes)
            yes=true
            ;;
        --skip-fonts)
            skip_fonts=true
            ;;
        --codespaces)
            codespaces=true
            skip_fonts=true
            ;;
        --dry-run)
            dry_run=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            printf "Unknown option: %s\n" "$1" >&2
            usage >&2
            exit 2
            ;;
    esac

    shift
done

case "$(uname -s)" in
    Darwin)
        platform="macos"
        ;;
    Linux)
        platform="linux"
        ;;
    *)
        printf "Unsupported operating system: %s\n" "$(uname -s)" >&2
        exit 1
        ;;
esac

if [[ "$codespaces" == true && "$platform" != "linux" ]]; then
    printf "Codespaces mode is supported only on Linux.\n" >&2
    exit 1
fi

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"

confirm_plan() {
    if [[ "$dry_run" == true ]]; then
        exit 0
    fi

    if [[ "$yes" == true ]]; then
        return
    fi

    printf "Continue? [y/N] "
    read -r response
    case "$response" in
        y|Y|yes|Yes|YES)
            ;;
        *)
            printf "Tool installation was cancelled.\n" >&2
            exit 1
            ;;
    esac
}

install_macos_tools() {
    if [[ "$codespaces" == true ]]; then
        printf "Codespaces mode is not available on macOS.\n" >&2
        exit 1
    fi

    brew_path=$(command -v brew || true)
    missing_homebrew=false
    missing_formulae=()
    missing_casks=()

    if [[ -z "$brew_path" ]]; then
        missing_homebrew=true
        missing_formulae=("gh" "starship")
        if [[ "$skip_fonts" == false ]]; then
            missing_casks=("font-fira-code-nerd-font" "font-fira-mono-nerd-font")
        fi
    else
        for formula in gh starship; do
            if ! "$brew_path" list --formula "$formula" >/dev/null 2>&1; then
                missing_formulae+=("$formula")
            fi
        done

        if [[ "$skip_fonts" == false ]]; then
            for cask in font-fira-code-nerd-font font-fira-mono-nerd-font; do
                if ! "$brew_path" list --cask "$cask" >/dev/null 2>&1; then
                    missing_casks+=("$cask")
                fi
            done
        fi
    fi

    if [[ "$missing_homebrew" == false &&
          ${#missing_formulae[@]} -eq 0 &&
          ${#missing_casks[@]} -eq 0 ]]; then
        printf "All managed macOS tools are installed.\n"
        return
    fi

    printf "The following tools will be installed:\n"
    if [[ "$missing_homebrew" == true ]]; then
        printf "  - Homebrew\n"
    fi
    for formula in "${missing_formulae[@]}"; do
        printf "  - %s\n" "$formula"
    done
    for cask in "${missing_casks[@]}"; do
        printf "  - %s (per-user)\n" "$cask"
    done

    confirm_plan

    if [[ "$missing_homebrew" == true ]]; then
        homebrew_installer=$(mktemp)
        if ! curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
            -o "$homebrew_installer"; then
            rm -f "$homebrew_installer"
            return 1
        fi

        if ! NONINTERACTIVE=1 /bin/bash "$homebrew_installer"; then
            rm -f "$homebrew_installer"
            return 1
        fi

        rm -f "$homebrew_installer"

        for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
            if [[ -x "$candidate" ]]; then
                brew_path=$candidate
                break
            fi
        done

        if [[ -z "$brew_path" ]]; then
            printf "Homebrew was installed but the brew executable could not be located.\n" >&2
            exit 1
        fi
    fi

    if [[ "$skip_fonts" == false ]]; then
        "$brew_path" bundle --file="$repository_root/Brewfile"
    elif (( ${#missing_formulae[@]} > 0 )); then
        "$brew_path" install "${missing_formulae[@]}"
    fi
}

run_as_root() {
    if (( EUID == 0 )); then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        printf "Administrator access is required to install Linux packages.\n" >&2
        exit 1
    fi
}

install_starship_user_local() {
    mkdir -p "$HOME/.local/bin"

    local installer
    installer=$(mktemp)
    if ! curl -fsSL https://starship.rs/install.sh -o "$installer"; then
        rm -f "$installer"
        return 1
    fi

    if ! sh "$installer" --yes --bin-dir "$HOME/.local/bin"; then
        rm -f "$installer"
        return 1
    fi

    rm -f "$installer"
}

install_linux_fonts() {
    local font_root="$HOME/.local/share/fonts/NerdFonts"
    local temporary_directory
    temporary_directory=$(mktemp -d)

    for family in FiraCode FiraMono; do
        local archive="$temporary_directory/$family.zip"
        local destination="$font_root/$family"

        if ! curl -fsSL \
            "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/$family.zip" \
            -o "$archive"; then
            rm -rf "$temporary_directory"
            return 1
        fi

        rm -rf "$destination"
        mkdir -p "$destination"
        if ! unzip -q "$archive" -d "$destination"; then
            rm -rf "$temporary_directory"
            return 1
        fi
    done

    rm -rf "$temporary_directory"
    fc-cache -f
}

install_linux_tools() {
    if [[ ! -r /etc/os-release ]]; then
        printf "Unable to identify the Linux distribution.\n" >&2
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    distribution="${ID:-} ${ID_LIKE:-}"
    if [[ "$distribution" != *ubuntu* && "$distribution" != *debian* ]]; then
        printf "Only Ubuntu and Debian are currently supported.\n" >&2
        exit 1
    fi

    missing_git=false
    missing_gh=false
    missing_starship=false
    missing_fonts=false

    if [[ "$codespaces" == false ]]; then
        command -v git >/dev/null 2>&1 || missing_git=true
        command -v gh >/dev/null 2>&1 || missing_gh=true
    fi

    command -v starship >/dev/null 2>&1 ||
        [[ -x "$HOME/.local/bin/starship" ]] ||
        missing_starship=true

    font_root="$HOME/.local/share/fonts/NerdFonts"
    if [[ "$codespaces" == false && "$skip_fonts" == false ]] &&
        { [[ ! -d "$font_root/FiraCode" ]] || [[ ! -d "$font_root/FiraMono" ]]; }; then
        missing_fonts=true
    fi

    if [[ "$missing_git" == false &&
          "$missing_gh" == false &&
          "$missing_starship" == false &&
          "$missing_fonts" == false ]]; then
        printf "All managed Linux tools are installed.\n"
        return
    fi

    printf "The following tools will be installed:\n"
    [[ "$missing_git" == true ]] && printf "  - Git\n"
    [[ "$missing_gh" == true ]] && printf "  - GitHub CLI\n"
    [[ "$missing_starship" == true ]] && printf "  - Starship (user-local)\n"
    if [[ "$missing_fonts" == true ]]; then
        printf "  - FiraCode Nerd Font (per-user)\n"
        printf "  - FiraMono Nerd Font (per-user)\n"
    fi

    confirm_plan

    apt_packages=()
    [[ "$missing_git" == true ]] && apt_packages+=("git")
    if [[ "$missing_starship" == true || "$missing_fonts" == true || "$missing_gh" == true ]]; then
        command -v curl >/dev/null 2>&1 || apt_packages+=("curl")
        dpkg-query -W -f='${db:Status-Abbrev}' ca-certificates 2>/dev/null |
            grep -q '^ii ' || apt_packages+=("ca-certificates")
    fi
    if [[ "$missing_fonts" == true ]]; then
        command -v unzip >/dev/null 2>&1 || apt_packages+=("unzip")
        command -v fc-cache >/dev/null 2>&1 || apt_packages+=("fontconfig")
    fi

    if (( ${#apt_packages[@]} > 0 )); then
        run_as_root apt-get update
        run_as_root apt-get install -y "${apt_packages[@]}"
    fi

    if [[ "$missing_gh" == true ]]; then
        keyring=$(mktemp)
        if ! curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
            -o "$keyring"; then
            rm -f "$keyring"
            return 1
        fi

        run_as_root install -d -m 0755 /etc/apt/keyrings
        run_as_root install -m 0644 "$keyring" /etc/apt/keyrings/githubcli-archive-keyring.gpg
        rm -f "$keyring"

        repository_entry="deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main"
        printf "%s\n" "$repository_entry" |
            run_as_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null

        run_as_root apt-get update
        run_as_root apt-get install -y gh
    fi

    if [[ "$missing_starship" == true ]]; then
        install_starship_user_local
    fi

    if [[ "$missing_fonts" == true ]]; then
        install_linux_fonts
    fi
}

if [[ "$platform" == "macos" ]]; then
    install_macos_tools
else
    install_linux_tools
fi
