#!/usr/bin/env bash

# inputs:
# - GITHUB_TOKEN (clone repo)
# - AGE_PASSPHRASE (decrypt)

# - (optional) dotroot (default: ~/.local/share/chezmoi, suggested option is ~/dotfiles)

# - (optional) pvcroot          (for `init_vscode.sh`, empty or not set will use dotroot, not doing ext cache)
# - (optional) VSCODE_VERSION   (for `init_vscode.sh`, empty or not set will skip installing vscode-server)
# - (optional) VSCODE_COMMIT_ID (for `init_vscode.sh`, empty or not set will skip installing vscode-server)
# - (optional) CURSOR_VERSION   (for `init_cursor.sh`, empty or not set will skip installing cursor)
# - (optional) CURSOR_COMMIT_ID (for `init_cursor.sh`, empty or not set will skip installing cursor)

function ensure-exists() {
    mkdir -p "$1" || (echo "Failed to create directory: $1" && exit 1)
}

function binary-found() {
	command -v "$1" >/dev/null 2>&1
}

function has-sudo-privileges() {
    groups "$(id -un)" | grep -q '\<sudo\>'
}

function ensure-common-paths() {
    local paths_to_add=(
        "$HOME/bin"
        "$HOME/.local/bin"
    )
    # Add brew paths only if the directories exist
    [[ -d "$HOME/homebrew" ]] && paths_to_add+=("$HOME/homebrew/bin")
    [[ -d "/home/linuxbrew/.linuxbrew" ]] && paths_to_add+=("/home/linuxbrew/.linuxbrew/bin")

    for p in "${paths_to_add[@]}"; do
        if [[ -d "$p" && ":$PATH:" != *":$p:"* ]]; then
            export PATH="$p:$PATH"
        fi
    done
}

function install-bins() {
    local missing_bins=()
    for bin in "$@"; do
        if ! binary-found "$bin"; then
            missing_bins+=("$bin")
        fi
    done
    [[ ${#missing_bins[@]} -eq 0 ]] && return 0

    if has-sudo-privileges; then
        sudo apt install -y "${missing_bins[@]}"
    elif binary-found "brew"; then
        brew install "${missing_bins[@]}"
    else
        echo "Error: Missing binaries (${missing_bins[*]}) and no sudo or brew available."
        echo "Please install them manually or install Homebrew first."
        exit 1
    fi
}

function install-chezmoi() {
    if binary-found "chezmoi"; then return 0; fi
    if has-sudo-privileges; then
        sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
    else
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    fi
}

function install-uv() {
    if binary-found "uv"; then return 0; fi
    # uv installer defaults to ~/.local/bin
    curl -LsSf https://astral.sh/uv/install.sh | sh -s -- --no-modify-path
}

function ensure-executable() {
    local script="$1"
    shift
    if [[ ! -x "$script" ]]; then
        chmod +x "$script"
    fi
    "$script" "$@"
}

function main() {

    ensure-exists "$HOME/me"
    ensure-exists "$HOME/work"
    ensure-exists "$HOME/bin"
    ensure-exists "$HOME/tmp"
    ensure-exists "$HOME/.local/bin"
    ensure-exists "$HOME/.local/lib"
    ensure-exists "$HOME/.local/share"
    ensure-exists "$HOME/.config/chezmoi"

    ensure-common-paths

    # export dotroot to be seen by scripts
    export GITHUB_USERNAME=${GITHUB_USERNAME:="zhuoqun-chen"}
    export dotroot=${dotroot:="${HOME}/.local/share/chezmoi"}
    local ssh_auth_key_fn="id_rsa_mbp14"
    # TODO: optionally allow passing ssh_pubkey as an argument to directly dump to ~/.ssh/authorized_keys

    # if dotroot starts with "~" (passed from outside), expand it
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

    if has-sudo-privileges; then
        echo "apt updating..."
        sudo apt update >/dev/null
    fi
    install-bins curl git age openssh-server
    install-uv
    install-chezmoi

    # deprecated: found the base ubuntu:22-jammy image apt-installed-gh doesn't support `-p` flag
    # install-bins gh
    # echo "$GITHUB_TOKEN" | gh auth login -p ssh --hostname github.com --with-token
    # gh repo clone "$GITHUB_USERNAME"/dotfiles "$dotroot"

    git clone https://"${GITHUB_TOKEN}"@github.com/"${GITHUB_USERNAME}"/dotfiles.git "$dotroot"

    # this step requires `AGE_PASSPHRASE` + `dotroot` to be set
    ensure-executable "${dotroot}/pvc_home/decrypt-key.py"
    sleep 1
    chezmoi init --source="${dotroot}" --apply
    echo ".config/git/config" >> "${dotroot}"/home/.chezmoiignore.tmpl

    command -v nvim >/dev/null && (echo "setting up nvim plugins..." && nvim --headless +Lazy! sync +qa >/dev/null)
    echo -e "\n"

    # setup ssh-server so that if it's installed and running and configured to only allow key-based auth login of non-root user
    [[ -d ~/.ssh ]] || mkdir -p ~/.ssh
    chmod 700 ~/.ssh
    if [[ -f ~/.ssh/"${ssh_auth_key_fn}".pub ]]; then
        [[ -f ~/.ssh/authorized_keys ]] || touch ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        echo -e "\n" >> ~/.ssh/authorized_keys
        cat ~/.ssh/"${ssh_auth_key_fn}".pub >> ~/.ssh/authorized_keys
        echo "SSH public key ${ssh_auth_key_fn} added to ~/.ssh/authorized_keys"
    fi

    # When this script serves as entrypoint for a container (or cmd of entrypoint `/bin/bash -c`)
    # seems `sudo service ssh start` line in `/etc/zshenv` (if there is such file and such line) won't be executed (let's assume $target_shell is zsh)
    if pgrep -x "sshd" >/dev/null; then
        echo "SSH server is already running."
    elif has-sudo-privileges; then
        echo "SSH server is not running, starting it now..."
        # note: remember to use `[cmd] >/dev/null 2>&1` when adding to `/etc/<rc|env>` bash/zsh files to avoid `navi` not working
        sudo service ssh start
    else
        echo "SSH server is not running, but no sudo privileges to start it."
    fi

    # shellcheck disable=SC1091
    source "${dotroot}/pvc_home/init_vscode.sh"
    # shellcheck disable=SC1091
    source "${dotroot}/pvc_home/init_cursor.sh"

    if [[ $# -eq 0 ]]; then
        echo -e "$noargs_msg"
        exec "$target_shell"
    else
        echo -e "$args_msg"
        exec "$@"
    fi
}

main "$@"
