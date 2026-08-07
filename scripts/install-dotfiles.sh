#!/usr/bin/env bash

set -euo pipefail

mode="link"
replace=false
check=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: install-dotfiles.sh [--copy] [--replace] [--check] [--dry-run]

  --copy      Copy files instead of creating symbolic links.
  --replace   Back up and replace conflicting destinations.
  --check     Report whether every destination is current.
  --dry-run   Report the installation actions without changing files.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --copy)
            mode="copy"
            ;;
        --replace)
            replace=true
            ;;
        --check)
            check=true
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

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
repository_root="$(cd "$script_directory/.." && pwd -P)"

names=("Copilot instructions")
sources=("$repository_root/dotfiles/copilot/copilot-instructions.md")
destinations=("$HOME/.copilot/copilot-instructions.md")

names+=("Git configuration")
sources+=("$repository_root/dotfiles/git/gitconfig")
destinations+=("$HOME/.config/devsetup/gitconfig")

if [[ "$platform" == "macos" ]]; then
    names+=("Zsh configuration")
    sources+=("$repository_root/dotfiles/zsh/.zshrc")
    destinations+=("$HOME/.zshrc")
else
    names+=("Bash configuration")
    sources+=("$repository_root/dotfiles/bash/bashrc")
    destinations+=("$HOME/.config/devsetup/bashrc")
fi

names+=("Starship configuration")
sources+=("$repository_root/dotfiles/starship/starship.toml")
destinations+=("$HOME/.config/starship.toml")

for source in "${sources[@]}"; do
    if [[ ! -f "$source" ]]; then
        printf "Dotfile source is missing: %s\n" "$source" >&2
        exit 1
    fi
done

mapping_state() {
    local source=$1
    local destination=$2

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        printf "missing"
    elif [[ "$mode" == "link" && -L "$destination" && "$destination" -ef "$source" ]]; then
        printf "current"
    elif [[ "$mode" == "copy" && ! -L "$destination" && -f "$destination" ]] &&
        cmp -s "$source" "$destination"; then
        printf "current"
    else
        printf "conflict"
    fi
}

states=()
has_drift=false
has_conflicts=false

for (( index = 0; index < ${#sources[@]}; index++ )); do
    state=$(mapping_state "${sources[$index]}" "${destinations[$index]}")
    states+=("$state")

    if [[ "$state" != "current" ]]; then
        has_drift=true
    fi

    if [[ "$state" == "conflict" ]]; then
        has_conflicts=true
    fi
done

if ! command -v git >/dev/null 2>&1; then
    printf "Git is required to install the managed configuration.\n" >&2
    exit 1
fi

git_include_path="$HOME/.config/devsetup/gitconfig"
portable_git_include_path='~/.config/devsetup/gitconfig'
set +e
git_includes=$(git config --global --get-all include.path 2>&1)
git_config_status=$?
set -e

if (( git_config_status != 0 && git_config_status != 1 )); then
    printf "Unable to read the global Git configuration:\n%s\n" "$git_includes" >&2
    exit "$git_config_status"
fi

if printf "%s\n" "$git_includes" |
    grep -Fqx -e "$git_include_path" -e "$portable_git_include_path"; then
    git_include_state="current"
else
    git_include_state="missing"
    has_drift=true
fi

bashrc_path="$HOME/.bashrc"
bashrc_loader='[ -r "$HOME/.config/devsetup/bashrc" ] && . "$HOME/.config/devsetup/bashrc" # Dustin-DevSetup'
bashrc_state=""

if [[ "$platform" == "linux" ]]; then
    if [[ -f "$bashrc_path" ]] && grep -Fqx "$bashrc_loader" "$bashrc_path"; then
        bashrc_state="current"
    elif [[ ( -e "$bashrc_path" || -L "$bashrc_path" ) && ! -f "$bashrc_path" ]]; then
        bashrc_state="conflict"
        has_conflicts=true
        has_drift=true
    else
        bashrc_state="missing"
        has_drift=true
    fi
fi

print_state() {
    local state=$1
    local destination=$2
    local label

    label=$(printf "%s" "$state" | tr "[:lower:]" "[:upper:]")
    printf "%-8s %s\n" "$label" "$destination"
}

if [[ "$check" == true ]]; then
    for (( index = 0; index < ${#states[@]}; index++ )); do
        print_state "${states[$index]}" "${destinations[$index]}"
    done

    if [[ "$platform" == "linux" ]]; then
        print_state "$bashrc_state" "$bashrc_path"
    fi

    print_state "$git_include_state" "Global Git include: $git_include_path"

    if [[ "$has_drift" == true ]]; then
        exit 1
    fi

    exit 0
fi

if [[ "$has_conflicts" == true && "$replace" == false ]]; then
    printf "Existing files differ from the requested %s installation.\n" "$mode" >&2
    printf "Re-run with --replace to back them up first:\n" >&2

    for (( index = 0; index < ${#states[@]}; index++ )); do
        if [[ "${states[$index]}" == "conflict" ]]; then
            printf "  %s\n" "${destinations[$index]}" >&2
        fi
    done

    if [[ "$bashrc_state" == "conflict" ]]; then
        printf "  %s\n" "$bashrc_path" >&2
    fi

    exit 1
fi

if [[ "$bashrc_state" == "conflict" ]]; then
    printf "The Bash profile path is not a regular file: %s\n" "$bashrc_path" >&2
    exit 1
fi

timestamp=$(date "+%Y%m%d%H%M%S")

for (( index = 0; index < ${#sources[@]}; index++ )); do
    source=${sources[$index]}
    destination=${destinations[$index]}
    state=${states[$index]}

    if [[ "$state" == "current" ]]; then
        printf "Current: %s\n" "${names[$index]}"
        continue
    fi

    if [[ "$dry_run" == true ]]; then
        printf "Would install: %s (%s)\n" "${names[$index]}" "$mode"
        if [[ "$state" == "conflict" ]]; then
            printf "Would back up: %s\n" "$destination"
        fi
        continue
    fi

    mkdir -p "$(dirname "$destination")"

    backup=""
    if [[ "$state" == "conflict" ]]; then
        backup="$destination.backup.$timestamp"
        if [[ -e "$backup" || -L "$backup" ]]; then
            printf "Backup path already exists: %s\n" "$backup" >&2
            exit 1
        fi

        mv "$destination" "$backup"
    fi

    if [[ "$mode" == "link" ]]; then
        if ! ln -s "$source" "$destination"; then
            [[ -e "$destination" || -L "$destination" ]] && rm -f "$destination"
            [[ -n "$backup" ]] && mv "$backup" "$destination"
            exit 1
        fi
    elif ! cp "$source" "$destination"; then
        [[ -e "$destination" || -L "$destination" ]] && rm -f "$destination"
        [[ -n "$backup" ]] && mv "$backup" "$destination"
        exit 1
    fi

    printf "Installed: %s\n" "${names[$index]}"
    if [[ -n "$backup" ]]; then
        printf "Backup: %s\n" "$backup"
    fi
done

if [[ "$git_include_state" == "current" ]]; then
    printf "Current: Global Git include\n"
elif [[ "$dry_run" == true ]]; then
    printf "Would install: Global Git include (%s)\n" "$git_include_path"
elif ! git config --global --add include.path "$git_include_path"; then
    printf "Unable to add the managed Git configuration include.\n" >&2
    exit 1
else
    printf "Installed: Global Git include\n"
fi

if [[ "$platform" == "linux" && "$bashrc_state" != "current" ]]; then
    if [[ "$dry_run" == true ]]; then
        printf "Would add managed loader to: %s\n" "$bashrc_path"
        exit 0
    fi

    bashrc_backup=""
    if [[ -f "$bashrc_path" ]]; then
        bashrc_backup="$bashrc_path.backup.$timestamp"
        if [[ -e "$bashrc_backup" || -L "$bashrc_backup" ]]; then
            printf "Backup path already exists: %s\n" "$bashrc_backup" >&2
            exit 1
        fi

        cp -p "$bashrc_path" "$bashrc_backup"
    fi

    if ! printf "\n%s\n" "$bashrc_loader" >> "$bashrc_path"; then
        if [[ -n "$bashrc_backup" ]]; then
            cp -p "$bashrc_backup" "$bashrc_path"
        else
            rm -f "$bashrc_path"
        fi
        exit 1
    fi

    printf "Installed: Bash loader\n"
    if [[ -n "$bashrc_backup" ]]; then
        printf "Backup: %s\n" "$bashrc_backup"
    fi
fi
