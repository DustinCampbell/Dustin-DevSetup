#!/usr/bin/env sh

set -eu

repository_root="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
exec bash "$repository_root/scripts/setup.sh" --codespaces --yes --replace "$@"
