#!/usr/bin/env bash

# inputs:
# - GITHUB_TOKEN (clone repo)
# - AGE_PASSPHRASE (decrypt)

function binary-found() {
	command -v "$1" >/dev/null 2>&1
}

function install-bins() {
    sudo apt update
    for bin in "$@"; do
        if ! binary-found "$bin"; then
            sudo apt install -y "$bin"
        fi
    done
}

function main() {

    # shellcheck disable=SC2034
    local target_shell="/bin/zsh"

    # if two inputs are not set, directly exec "/bin/zsh" or exec "$@"
    if [[ -z "$GITHUB_TOKEN" || -z "$AGE_PASSPHRASE" ]]; then
        echo "GITHUB_TOKEN and AGE_PASSPHRASE must be set."
        if [[ $# -eq 0 ]]; then
            exec "$target_shell"
        else
            exec "$@"
        fi
        return 0
    fi

    install-bins wget curl expect git gh
    if ! binary-found "chezmoi"; then
        sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
    fi

    echo "$GITHUB_TOKEN" | gh auth login -p ssh --hostname github.com --with-token

    dotroot="${HOME}"/.local/share/chezmoi
    gh repo clone zhuoqun-chen/dotfiles "$dotroot"
    mkdir -p "${HOME}"/.config/chezmoi

    # this step requires `AGE_PASSPHRASE` to be set
    expect "${dotroot}"/pvc_home/decrypt-key.exp
    sleep 1
    chezmoi init --source="${dotroot}" --apply
    echo ".config/git/config" >> "${dotroot}"/home/.chezmoiignore.tmpl

    if [[ $# -eq 0 ]]; then
        exec "$target_shell"
    else
        exec "$@"
    fi
}

main "$@"
