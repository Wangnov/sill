#!/bin/bash
# Offline only: captured synthetic AX group identities and pure banner field parsing. No AX,
# Notification Center, system store, permissions, or GUI is accessed by this check.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O -swift-version 6 -strict-concurrency=complete \
    Sources/SillHost/NotificationBannerObservation.swift "$here/main.swift" -o "$out/check"
"$out/check"
