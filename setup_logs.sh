#!/usr/bin/env bash
function main() {
    if [[ -z "$logdir" ]]; then
        echo "logdir is not set, exiting."
        exit 1
    fi

    mkdir -p "$logdir" || (echo "Failed to create log directory: $logdir" && exit 1)
    ts=$(date +"%Y.%m.%d-%H.%M.%S")
    logfile="${logdir}/$ts-debug.log"
    # exec > >(tee -a "$logfile") 2>&1

    # filter out ANSI escape codes from the log to make it human-readable
    # m: color codes
    # G: cursor movement
    # K: line clearing
    # H: cursor positioning
    exec > >(tee >(sed -r "s/\x1B\[[0-9;]*[mGKH]"// > "$logfile")) 2>&1
}
main "$@"
