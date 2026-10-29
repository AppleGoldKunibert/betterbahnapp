# BetterBahn for Android

Status: prototype (#467). The Android app lives in `Android/` in this repo and keeps feature parity with the iOS
app: same logic (BetterBahnKit, built with the Swift SDK for Android), native UI in Kotlin/Jetpack Compose, same
version number.

## Layout

| Path | Contents |
| --- | --- |
| `Android/kit/` | Swift package building BetterBahnKit for Android. `build.sh` links the Kit's source folders into `Sources/BetterBahnKit/` (gitignored), `Package.swift` leaves out what needs Apple frameworks, `Shims/` holds the Android stand-ins (FoundationNetworking/FoundationXML re-exported, a no-op `WorkerAuth`), `Bridge/KitBridge.swift` the JNI functions. Output: `libBetterBahnKit.so` (Swift runtime linked in) + `libc++_shared.so` per ABI in `Android/app/src/main/jniLibs/`, the Kit's JSON data in `Android/app/src/main/assets/BetterBahnKit/` (both gitignored). |
| `Android/app/` | The Android app (Gradle, AGP 9, Kotlin, Compose, Material 3). `kit/Kit.kt` loads the library, copies the JSON data out of the APK once per update and wraps the JNI calls; results come as JSON of the Kit's own models. `MainActivity.kt`: so far one screen, the station search. |
| `Android/gradle/libs.versions.toml` | Versions of AGP, Kotlin, Compose. |

`applicationId` and package are `de.goldkunibert.betterbahn`. The ID is permanent once the app is on Google Play:
confirm it before the first upload. `versionName`/`versionCode` come from `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `BetterBahn.xcodeproj/project.pbxproj`, which `bump-version.yml` already raises, so
both apps always carry the same version. minSdk 28, compileSdk and targetSdk 37; ABIs `arm64-v8a` (phones) and
`x86_64` (emulator on a Windows/Intel PC).

## Building

1. **Kit** (macOS, Linux or WSL2 on Windows; the Swift SDK for Android has no native Windows host): install a
   Swift toolchain, the matching Swift SDK for Android (`swift sdk install …_android.artifactbundle.tar.gz`, then
   its `scripts/setup-android-sdk.sh`) and the Android NDK (r27+), set `ANDROID_NDK_HOME`, then
   `Android/kit/build.sh`. Rerun after every Kit change. Tested with Swift 6.4.1 and NDK r27d.
2. **App**: open `Android/` in Android Studio (Windows, macOS or Linux) and run it on an emulator, or
   `cd Android && ./gradlew assembleDebug`. Needs the libraries from step 1.

Without a local Swift setup: `.github/workflows/android-build.yml` (Linux) builds both on every PR that changes
`Android/` or the Kit's sources and uploads the debug APK as the artifact `BetterBahn-Android-debug` (on the PR's
"Checks" tab, 14 days). Unzip it and drag `app-debug.apk` onto the running emulator. The same run keeps Kit changes
from breaking the Android build unnoticed.

From a cloud session: Swift, the SDK and the NDK aren't preinstalled; download them from swift.org and
dl.google.com (a few GB, ~5 min). Maven Central sometimes answers `429`: rerun Gradle with `--max-workers=1`.
There's no emulator in the cloud (no KVM), so the app is only built there and tested on the owner's PC.

## What's not on Android yet

Left out of the Android Kit build (`Android/kit/Package.swift`) because they need Apple frameworks:

| Kit part | Needs | Android replacement (to do) |
| --- | --- | --- |
| `Support/WorkerAuth.swift` | DeviceCheck (App Attest), CryptoKit | Play Integrity: an `AppAttesting`-like Kotlin service, plus a verification path in `Cloudflare/shared/appattest.mjs` and `Server/bahnde-proxy/proxy.py` issuing the same `X-BetterBahn-Token`. Until then requests go out without a token, which our servers refuse unless `ALLOW_UNATTESTED` is set, so bahn.de data doesn't work yet. |
| `Traewelling/` | CryptoKit (PKCE), Security (Keychain) | swift-crypto, Android Keystore via Kotlin |
| `Tickets/`, `Calendar/` | CryptoKit, PDFKit, Vision | Google Wallet passes (`pass-signer` needs a second format), ML Kit barcode scanning, Android calendar |
| `Sharing/JourneyShareLink.swift`, `ShortShareLinkClient.swift` | Compression (zlib) | zlib from the NDK |

Kit code behind `#if canImport(SwiftUI|ActivityKit|PDFKit)` (product colours, Live Activity attributes, ticket
scanning) compiles to nothing on Android.

Open technical points:
- **Resources in release builds**: SwiftPM's `Bundle.module` can't see into the APK. The bridge points it at the
  copied JSON data with `PACKAGE_RESOURCE_BUNDLE_PATH`, which SwiftPM only reads in debug builds. Before a
  release build the Kit needs its own resource lookup that the app can set.
- **Size**: `libBetterBahnKit.so` is ~60 MB per ABI without symbols (~23 MB compressed), mostly ICU data for
  Foundation. Google Play delivers one ABI per device (App Bundle).
- **Push**: APNs only so far; `Cloudflare/checkin-push` and `Cloudflare/live-activity` need FCM.
- **Platform features**: widgets → Glance, Live Activity → ongoing/progress notification, MapKit → Google Maps
  or MapLibre, App Intents/Spotlight → App Shortcuts, share extension → intent filter, CloudKit sync → none (own
  backend or no sync).

## Keeping both apps in sync

Every feature or bug fix that changes behaviour is built for iOS first (own branch, own PR into
`indevelopment`), then for Android in the same session on `<branch>android` with its own PR. The two PRs are
tested and merged separately, so one app never waits for the other's test. Android PRs carry the label
`android`, which `bump-version.yml` skips: the version goes up once, with the iOS PR. Rules: `.claude/CLAUDE.md`
("Android").

## Testing and release

- Day to day: the Android Studio emulator on the owner's Windows PC (Windows Hypervisor Platform on, x86_64
  image). Play Integrity never passes on an emulator: debug builds need a server-side bypass.
- Before a release: Firebase Test Lab or the Play Console pre-launch report (real devices in the cloud).
- Google Play: a new personal developer account must run a closed test with 12 testers for 14 days before the
  first public release. Data safety form and privacy policy (`/datenschutz`) as for the App Store.
