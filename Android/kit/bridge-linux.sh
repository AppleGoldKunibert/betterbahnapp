#!/bin/bash
# Builds the Kit with its JNI bridge as a Linux library, so the app's JVM unit tests can call the real bridge
# (`KitBridgeTest`) without an emulator. Same sources as build.sh, the host's Swift and the JDK's jni.h instead
# of the NDK. Prints the folder holding libBetterBahnKit.so and the Kit's data; the Gradle tests read it from
# KIT_LINUX_DIR:
#   KIT_LINUX_DIR=$(Android/kit/bridge-linux.sh) ./gradlew testDebugUnitTest   (in Android/)
set -euo pipefail
K=$(cd "$(dirname "$0")" && pwd)
KIT=$(cd "$K/../../Packages/BetterBahnKit/Sources/BetterBahnKit" && pwd)
P="$K/.linux-bridge"
JDK=${JAVA_HOME:-$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")}
[ -f "$JDK/include/jni.h" ] || { echo "No jni.h in $JDK/include (set JAVA_HOME to a JDK)." >&2; exit 1; }

rm -rf "$P/Sources" && mkdir -p "$P/Sources/BetterBahnKit" "$P/Sources/jni"
for d in "$KIT"/*/; do ln -s "$d" "$P/Sources/BetterBahnKit/$(basename "$d")"; done
ln -s "$K/Shims" "$P/Sources/BetterBahnKit/AndroidShims"
ln -s "$K/CZlib" "$P/Sources/CZlib"
ln -sfn "$K/CxxShims" "$P/CxxShims"
ln -s "$K/Bridge" "$P/Sources/KitBridge"
# On Android the NDK's sysroot has a `jni` module; here it's the JDK's header.
printf 'module jni [system] {\n    header "%s/include/jni.h"\n    export *\n}\n' "$JDK" > "$P/Sources/jni/module.modulemap"
# Named like the Android package, so the Kit's data folder has the name the bridge looks for.
sed -e 's|name: "KitBridge", dependencies: \["BetterBahnKit"\], path: "Bridge"|name: "KitBridge", dependencies: ["BetterBahnKit", "jni"]|' \
    -e 's|.systemLibrary(name: "CZlib", path: "CZlib"),|.systemLibrary(name: "CZlib"), .systemLibrary(name: "jni"),|' \
    "$K/Package.swift" > "$P/Package.swift"
grep -q '"jni"\]' "$P/Package.swift" || { echo "Couldn't adapt Package.swift for Linux." >&2; exit 1; }

args=(--package-path "$P" -c debug --static-swift-stdlib -Xcc "-I$JDK/include" -Xcc "-I$JDK/include/linux")
swift build "${args[@]}" >&2
swift build "${args[@]}" --show-bin-path
