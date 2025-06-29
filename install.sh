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
    local ssh_auth_key_fn="id_rsa_mbp14"
    # TODO: optionally allow passing ssh_pubkey as an argument to directly dump to ~/.ssh/authorized_keys

    # if dotroot starts with "~" (passed from outside), expand it for the expect script
    # shellcheck disable=SC2088
    if [[ "$dotroot" == "~/"* ]]; then
        dotroot="${HOME}/${dotroot:2}"
    fi
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
    install-bins curl expect git age openssh-server
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

    # setup ssh-server so that if it's installed and running and configured to only allow key-based auth login of non-root user
    if ! [[ -d ~/.ssh ]]; then
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        if [[ -f ~/.ssh/"${ssh_auth_key_fn}".pub ]]; then
            [[ -f ~/.ssh/authorized_keys ]] || touch ~/.ssh/authorized_keys
            chmod 600 ~/.ssh/authorized_keys
            echo "" >> ~/.ssh/authorized_keys
            cat ~/.ssh/"${ssh_auth_key_fn}".pub >> ~/.ssh/authorized_keys
        fi
    fi

    command -v nvim >/dev/null && nvim --headless +Lazy! sync +qa

    # When this script serves as entrypoint for a container (or cmd of entrypoint `/bin/bash -c`)
    # seems `sudo service ssh start` line in `/etc/zshenv` (if there is such file and such line) won't be executed (let's assume $target_shell is zsh)
    if pgrep -x "sshd" >/dev/null; then
        echo "SSH server is already running."
    else
        echo "SSH server is not running, starting it now..."
        sudo service ssh start
    fi

    if [[ $# -eq 0 ]]; then
        echo -e "$noargs_msg"
        exec "$target_shell"
    else
        echo -e "$args_msg"
        exec "$@"
    fi
}

main "$@"
