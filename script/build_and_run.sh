#!/bin/bash
# Build and launch this checkout's development app. Stop only its exact executable path:
# the installed Sill may be serving a device and has a separate identity and preferences.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-run}"
if [ "$#" -gt 0 ]; then shift; fi
case "$mode" in
    run|--verify|--debug|--logs) ;;
    *) echo "usage: $0 [run|--verify|--debug|--logs] [app arguments...]" >&2; exit 2 ;;
esac

derived="$root/.build/DerivedData"
signing_config="$root/Signing.local.xcconfig"
signing_args=()
if [ -e "$signing_config" ] || [ -L "$signing_config" ]; then
    signing_args=(-xcconfig "$signing_config")
fi
app="$derived/Build/Products/Debug/Sill Development.app"
binary="$app/Contents/MacOS/Sill"
# A checkout may live on a volume the GUI app cannot write yet. Use the app's normal log
# location, with a separate directory so a development run never shares the installed app's log.
log="$HOME/Library/Logs/Sill-Development/Sill.log"

development_pids() {
    ps -axww -o pid=,comm= | awk -v executable="$binary" '
        { pid = $1; sub(/^[[:space:]]*[0-9]+[[:space:]]+/, ""); if ($0 == executable) print pid }
    '
}
while read -r pid; do
    [ -n "$pid" ] || continue
    kill -TERM "$pid"
    # HostShutdown restores windows on the main queue before exiting. A warm build can finish
    # sooner, so wait for that handoff instead of starting two hosts against the same resources.
    deadline=$((SECONDS + 5))
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            echo "Development app $pid is still stopping; try again after it exits." >&2
            exit 1
        fi
        sleep 0.1
    done
done < <(development_pids)

xcodebuild -workspace "$root/Sill.xcworkspace" -scheme SillMacApp \
    -configuration Debug -destination 'platform=macOS' -derivedDataPath "$derived" ${signing_args[@]+"${signing_args[@]}"} build

# The upstream log path is shared independently of bundle ID. Keep development logs here too.
if [ "$mode" = --debug ]; then
    exec lldb -- "$binary" -SillLogFile "$log" "$@"
fi
/usr/bin/open -n "$app" --args -SillLogFile "$log" "$@"
if [ "$mode" = --verify ] || [ "$mode" = --logs ]; then
    sleep 1
    pid="$(development_pids | head -n 1)"
    if [ -z "$pid" ]; then
        echo "Development app did not stay running; see $log" >&2
        exit 1
    fi
    echo "Sill Development is running (PID $pid)."
fi
if [ "$mode" = --logs ]; then exec tail -f "$log"; fi
