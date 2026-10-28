#!/bin/bash
# Offline metadata/parser/pipe checks. Only synthetic child processes run; no log stream,
# notification database, GUI, user notification content, or permissions are accessed.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
    Sources/SillHost/NotificationBannerObservation.swift \
    Sources/SillHost/NotificationArrivalMatcher.swift \
    Sources/SillHost/NotificationSourceObserver.swift "$here/main.swift" -o "$out/check"
"$out/check"
