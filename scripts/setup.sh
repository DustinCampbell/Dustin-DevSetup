#!/usr/bin/env bash

# macOS Bash 3.2 treats declared empty arrays as unset under nounset.
set -eo pipefail

yes=false
replace=false
copy=false
skip_fonts=false
codespaces=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: setup.sh [--yes] [--replace] [--copy] [--skip-fonts] [--codespaces] [--dry-run]

  --yes         Skip the single tool-installation confirmation.
  --replace     Back up and replace conflicting dotfiles.
  --copy        Copy dotfiles instead of creating symbolic links.
  --skip-fonts  Do not install desktop Nerd Fonts.
  --codespaces  Install only tools appropriate for GitHub Codespaces.
  --dry-run     Show tool and dotfile installation actions without changing files.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --yes)
            yes=true
            ;;
        --replace)
            replace=true
            ;;
        --copy)
            copy=true
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

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

tool_arguments=()
[[ "$yes" == true ]] && tool_arguments+=("--yes")
[[ "$skip_fonts" == true ]] && tool_arguments+=("--skip-fonts")
[[ "$codespaces" == true ]] && tool_arguments+=("--codespaces")
[[ "$dry_run" == true ]] && tool_arguments+=("--dry-run")

bash "$script_directory/install-tools.sh" "${tool_arguments[@]}"

dotfile_arguments=()
[[ "$replace" == true ]] && dotfile_arguments+=("--replace")
[[ "$copy" == true ]] && dotfile_arguments+=("--copy")
[[ "$dry_run" == true ]] && dotfile_arguments+=("--dry-run")

bash "$script_directory/install-dotfiles.sh" "${dotfile_arguments[@]}"
