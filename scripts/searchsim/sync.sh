#!/bin/bash
# Copies BetterBahnKit's platform-neutral sources and its main test file into this Linux package,
# with the Linux Foundation imports, so the station search can be run and tested without a Mac:
#   ./sync.sh && swift run SearchSim scenarios.txt [filter]   # live search against Transitous
#   ./sync.sh && swift test                                   # BetterBahnKitTests.swift
# Needs Swift 6.2 for Linux (https://www.swift.org/install/linux/). Run sync.sh after every change.
set -e
S=$(cd "$(dirname "$0")" && pwd)
R=$(cd "$S/../../Packages/BetterBahnKit" && pwd)
rm -rf "$S/Sources/Kit" && mkdir -p "$S/Sources/Kit/Resources"
cp "$R/Sources/BetterBahnKit/Resources/StationHints.json" "$S/Sources/Kit/Resources/"
cd "$R/Sources/BetterBahnKit"
for f in $(find . -name "*.swift"); do
  # Tickets, Träwelling and anything importing Apple-only frameworks stay out.
  # ShortShareLinkClient needs JourneyShareLink, which imports Compression.
  case "$f" in ./Traewelling/*|./Tickets/*|./Sharing/ShortShareLinkClient.swift) continue;; esac
  grep -qE "^import (ActivityKit|Compression|CoreGraphics|CryptoKit|DeviceCheck|ImageIO|PDFKit|Security|SwiftUI|UniformTypeIdentifiers|Vision)" "$f" && continue
  mkdir -p "$S/Sources/Kit/$(dirname "$f")"
  { printf '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n#if canImport(FoundationXML)\nimport FoundationXML\n#endif\n'; cat "$f"; } > "$S/Sources/Kit/$f"
done
cp "$S/Stubs.swift" "$S/Sources/Kit/"
rm -rf "$S/Tests" && mkdir -p "$S/Tests/KitTests" && cp -r "$R/Tests/BetterBahnKitTests/Fixtures" "$S/Tests/KitTests/"
{ printf '#if canImport(FoundationNetworking)\nimport FoundationNetworking\n#endif\n'
  sed 's/@testable import BetterBahnKit/@testable import Kit/' "$R/Tests/BetterBahnKitTests/BetterBahnKitTests.swift"; } > "$S/Tests/KitTests/KitTests.swift"
python3 "$S/striptests.py" "$S/Tests/KitTests/KitTests.swift"
