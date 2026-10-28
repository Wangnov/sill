#!/bin/bash
# Actual reader against a synthetic Notification Center schema and a live WAL writer. No TCC or
# personal notification store access. Checks delivered filtering, identities, updates, and resets.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -emit-library -emit-module -module-name StreamProtocol \
    Sources/StreamProtocol/MirroredNotification.swift -o "$out/libStreamProtocol.dylib"
swiftc -O -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/NotificationStoreReader.swift "$here/main.swift" -o "$out/check"
"$out/check"
