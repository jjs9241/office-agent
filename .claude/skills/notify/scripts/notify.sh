#!/usr/bin/env bash
# Show a desktop notification on macOS (osascript) or Linux (notify-send).
# Usage: notify.sh -Title "Claude Code" -Message "Done" [-Silent]
set -u

title="Claude Code"
message=""
silent=0
while [ $# -gt 0 ]; do
    case "$1" in
        -Title|--title) title="${2:-}"; shift 2 ;;
        -Message|--message) message="${2:-}"; shift 2 ;;
        -Silent|--silent) silent=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[ -n "$message" ] || { echo "Usage: notify.sh -Title <t> -Message <m> [-Silent]" >&2; exit 2; }

case "$(uname -s)" in
    Darwin)
        # Pass text as argv so quotes in the message cannot break the AppleScript.
        if [ "$silent" -eq 1 ]; then
            osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' "$title" "$message"
        else
            osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' -e 'end run' "$title" "$message"
        fi
        ;;
    MINGW*|MSYS*|CYGWIN*)
        dir=$(cd "$(dirname "$0")" && pwd)
        args=(-NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$dir/notify.ps1")" -Title "$title" -Message "$message")
        [ "$silent" -eq 1 ] && args+=(-Silent)
        powershell.exe "${args[@]}"
        ;;
    *)
        command -v notify-send >/dev/null 2>&1 || { echo "notify-send not found (install libnotify-bin)" >&2; exit 1; }
        notify-send -a "Claude Code" -- "$title" "$message"
        ;;
esac
