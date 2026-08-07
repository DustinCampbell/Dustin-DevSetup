#!/usr/bin/env zsh

script_directory=${0:A:h}
exec bash "$script_directory/install-dotfiles.sh" "$@"
