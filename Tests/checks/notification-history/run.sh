#!/bin/bash
# Offline only: isolated Sill history/outbox SQLite, protocol compatibility, and APNs classification.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -emit-library -emit-module -module-name StreamProtocol \
    Sources/StreamProtocol/MirroredNotification.swift -o "$out/libStreamProtocol.dylib"
swiftc -O -package-name Sill -I "$out" -L "$out" -lStreamProtocol -Xlinker -rpath -Xlinker "$out" \
    Sources/SillHost/NotificationStoreReader.swift Sources/SillHost/NotificationHistoryStore.swift \
    Sources/SillHost/APNsProvider.swift Sources/SillHost/NotificationMirror.swift \
    "$here/CollectorStub.swift" "$here/main.swift" -o "$out/check"
"$out/check"
