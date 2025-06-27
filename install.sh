#!/usr/bin/env bash

# inputs:
# - GITHUB_TOKEN (clone repo)
# - AGE_PASSPHRASE (decrypt)

function binary-found() {
	command -v "$1" >/dev/null 2>&1
}

function install-bins() {
    for bin in "$@"; do
        if ! binary-found "$bin"; then
            sudo apt install -y "$bin"
        fi
    done
}

function main() {

    # export dotroot to be seen by expect script
    export GITHUB_USERNAME=${GITHUB_USERNAME:="zhuoqun-chen"}
    export dotroot=${dotroot:="${HOME}/.local/share/chezmoi"}
    echo "selected dotroot: $dotroot"

    local target_shell
    if binary-found "/bin/zsh"; then
        target_shell="/bin/zsh"
    elif binary-found "/bin/bash"; then
        target_shell="/bin/bash"
    elif binary-found "/bin/sh"; then
        target_shell="/bin/sh"
    else
        echo "No supported shell found, exiting."
        return 1
    fi

    local noargs_msg="\nno args provided, executing target shell: $target_shell"
    local args_msg="\nargs provided, executing: $*"

    # if two inputs are not set, directly exec "/bin/zsh" or exec "$@"
    if [[ -z "$GITHUB_TOKEN" || -z "$AGE_PASSPHRASE" ]]; then
        echo "GITHUB_TOKEN and AGE_PASSPHRASE not set, skipping dotfiles init."
        if [[ $# -eq 0 ]]; then
            echo -e "$noargs_msg"
            exec "$target_shell"
        else
            echo -e "$args_msg"
            exec "$@"
        fi
        return 0
    fi

    sudo apt update
    install-bins curl expect git age
    if ! binary-found "chezmoi"; then
        sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
    fi

    # deprecated: found the base ubuntu:22-jammy image apt-installed-gh doesn't support `-p` flag
    # install-bins gh
    # echo "$GITHUB_TOKEN" | gh auth login -p ssh --hostname github.com --with-token
    # gh repo clone "$GITHUB_USERNAME"/dotfiles "$dotroot"

    git clone https://"${GITHUB_TOKEN}"@github.com/"${GITHUB_USERNAME}"/dotfiles.git "$dotroot"

    mkdir -p "${HOME}"/.config/chezmoi

    # this step requires `AGE_PASSPHRASE` + `dotroot` to be set
    expect "${dotroot}"/pvc_home/decrypt-key.exp
    sleep 1
    chezmoi init --source="${dotroot}" --apply
    echo ".config/git/config" >> "${dotroot}"/home/.chezmoiignore.tmpl

    command -v nvim >/dev/null && nvim --headless +Lazy! sync +qa

    if [[ $# -eq 0 ]]; then
        echo -e "$noargs_msg"
        exec "$target_shell"
    else
        echo -e "$args_msg"
        exec "$@"
    fi
}

main "$@"
