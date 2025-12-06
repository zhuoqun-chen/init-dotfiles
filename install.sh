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

function is-in-container() {
    # Detection order based on starship (ref: starship/src/modules/container.rs)
    # 1. OpenVZ
    [[ -d /proc/vz && ! -d /proc/bc ]] && return 0
    # 2. OCI
    [[ -f /run/host/container-manager ]] && return 0
    # 3. Podman and others
    [[ -f /run/.containerenv ]] && return 0
    # 4. Systemd (skip WSL)
    if [[ -f /run/systemd/container ]]; then
        local content
        content=$(cat /run/systemd/container 2>/dev/null)
        [[ "$content" != "wsl" ]] && return 0
    fi
    # 5. Docker
    [[ -f /.dockerenv ]] && return 0
    return 1
}

function has-sudo-privileges() {
    # Check group membership based on OS (fast)
    if [[ "$(uname -s)" == "Darwin" ]]; then
        # macOS: admin group grants sudo
        groups "$(id -un)" | grep -qE '\<admin\>' && return 0
    else
        # Linux: sudo or wheel group
        groups "$(id -un)" | grep -qE '\<(sudo|wheel)\>' && return 0
    fi
    # In container: try passwordless sudo (NOPASSWD via sudoers)
    if is-in-container; then
        sudo -n true 2>/dev/null
        return $?
    fi
    # Not in container & not in sudo group: assume no sudo
    return 1
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

    echo "Installing missing binaries: ${missing_bins[*]}"
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
    if binary-found "chezmoi"; then
        echo "chezmoi already installed"
        return 0
    fi
    echo "Installing chezmoi..."
    if has-sudo-privileges; then
        sudo sh -c "$(curl -fsLS get.chezmoi.io)" -- -b /usr/local/bin
    else
        sh -c "$(curl -fsLS get.chezmoi.io)" -- -b "$HOME/.local/bin"
    fi
}

function install-uv() {
    if binary-found "uv"; then
        echo "uv already installed"
        return 0
    fi
    echo "Installing uv..."
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

    # Track warnings to print at the end
    local warnings=()

    if has-sudo-privileges; then
        echo "sudo access: yes"
        echo "apt updating..."
        sudo apt update >/dev/null
    else
        echo "sudo access: no (will use brew or ~/.local/bin)"
    fi

    install-bins curl git age
    # openssh-server can only be installed via apt
    if ! binary-found "sshd"; then
        if has-sudo-privileges; then
            echo "Installing openssh-server..."
            sudo apt install -y openssh-server
        else
            warnings+=("openssh-server not installed (requires sudo/apt)")
        fi
    fi
    install-uv
    install-chezmoi

    # deprecated: found the base ubuntu:22-jammy image apt-installed-gh doesn't support `-p` flag
    # install-bins gh
    # echo "$GITHUB_TOKEN" | gh auth login -p ssh --hostname github.com --with-token
    # gh repo clone "$GITHUB_USERNAME"/dotfiles "$dotroot"

    echo "Cloning dotfiles repo..."
    git clone https://"${GITHUB_TOKEN}"@github.com/"${GITHUB_USERNAME}"/dotfiles.git "$dotroot"

    # this step requires `AGE_PASSPHRASE` + `dotroot` to be set
    echo "Decrypting age key..."
    ensure-executable "${dotroot}/pvc_home/decrypt-key.py"
    sleep 1
    echo "Applying chezmoi..."
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
        echo "SSH server: already running"
    elif has-sudo-privileges && binary-found "sshd"; then
        echo "SSH server: starting..."
        # note: remember to use `[cmd] >/dev/null 2>&1` when adding to `/etc/<rc|env>` bash/zsh files to avoid `navi` not working
        sudo service ssh start
    else
        warnings+=("SSH server not started (requires sudo & sshd installed)")
    fi

    # shellcheck disable=SC1091
    source "${dotroot}/pvc_home/init_vscode.sh"
    # shellcheck disable=SC1091
    source "${dotroot}/pvc_home/init_cursor.sh"

    # Print warnings if any
    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo -e "\n[Warnings]"
        for w in "${warnings[@]}"; do
            echo "  - $w"
        done
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
