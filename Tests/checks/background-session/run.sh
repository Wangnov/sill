#!/bin/bash
# Durable per-scene resume intent, source identity and balanced inputs. No simulator or real defaults.
here="$(cd "$(dirname "$0")" && pwd)"
source "$here/../common.sh"
swiftc -O Sources/StreamProtocol/Input.swift Sources/StreamProtocol/StreamMessage.swift Sources/StreamProtocol/Switcher.swift iOSClient/BackgroundSessionIntent.swift "$here/main.swift" -o "$out/check"
"$out/check"
