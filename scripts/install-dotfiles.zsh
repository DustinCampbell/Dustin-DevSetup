#!/usr/bin/env zsh

set -eu
setopt pipe_fail

mode="link"
replace=false
check=false
dry_run=false

usage() {
    cat <<'EOF'
Usage: install-dotfiles.zsh [--copy] [--replace] [--check] [--dry-run]

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
            print -u2 "Unknown option: $1"
            usage >&2
            exit 2
            ;;
    esac

    shift
done

script_directory=${0:A:h}
repository_root=${script_directory:h}

names=(
    "Copilot instructions"
    "Starship configuration"
    "Zsh configuration"
)
sources=(
    "$repository_root/dotfiles/copilot/copilot-instructions.md"
    "$repository_root/dotfiles/starship/starship.toml"
    "$repository_root/dotfiles/zsh/.zshrc"
)
destinations=(
    "$HOME/.copilot/copilot-instructions.md"
    "$HOME/.config/starship.toml"
    "$HOME/.zshrc"
)

for source in "${sources[@]}"; do
    if [[ ! -f "$source" ]]; then
        print -u2 "Dotfile source is missing: $source"
        exit 1
    fi
done

mapping_state() {
    local source=$1
    local destination=$2

    if [[ ! -e "$destination" && ! -L "$destination" ]]; then
        print "missing"
    elif [[ "$mode" == "link" && -L "$destination" && "$destination" -ef "$source" ]]; then
        print "current"
    elif [[ "$mode" == "copy" && ! -L "$destination" && -f "$destination" ]] &&
        cmp -s "$source" "$destination"; then
        print "current"
    else
        print "conflict"
    fi
}

states=()
has_drift=false
has_conflicts=false

for (( index = 1; index <= ${#sources}; index++ )); do
    state=$(mapping_state "${sources[$index]}" "${destinations[$index]}")
    states+=("$state")

    if [[ "$state" != "current" ]]; then
        has_drift=true
    fi

    if [[ "$state" == "conflict" ]]; then
        has_conflicts=true
    fi
done

if $check; then
    for (( index = 1; index <= ${#states}; index++ )); do
        printf "%-8s %s\n" "${(U)states[$index]}" "${destinations[$index]}"
    done

    $has_drift && exit 1
    exit 0
fi

if $has_conflicts && ! $replace; then
    print -u2 "Existing files differ from the requested $mode installation."
    print -u2 "Re-run with --replace to back them up first:"
    for (( index = 1; index <= ${#states}; index++ )); do
        if [[ "${states[$index]}" == "conflict" ]]; then
            print -u2 "  ${destinations[$index]}"
        fi
    done
    exit 1
fi

timestamp=$(date "+%Y%m%d%H%M%S")

for (( index = 1; index <= ${#sources}; index++ )); do
    source=${sources[$index]}
    destination=${destinations[$index]}
    state=${states[$index]}

    if [[ "$state" == "current" ]]; then
        print "Current: ${names[$index]}"
        continue
    fi

    if $dry_run; then
        print "Would install: ${names[$index]} ($mode)"
        [[ "$state" == "conflict" ]] && print "Would back up: $destination"
        continue
    fi

    mkdir -p "${destination:h}"

    backup=""
    if [[ "$state" == "conflict" ]]; then
        backup="$destination.backup.$timestamp"
        if [[ -e "$backup" || -L "$backup" ]]; then
            print -u2 "Backup path already exists: $backup"
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

    print "Installed: ${names[$index]}"
    [[ -n "$backup" ]] && print "Backup: $backup"
done
