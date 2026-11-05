# BetterBahn for Android

Status: prototype (#467). The Android app lives in `Android/` in this repo and keeps feature parity with the iOS
app: same logic (BetterBahnKit, built with the Swift SDK for Android), native UI in Kotlin/Jetpack Compose, same
version number.

On Android so far:
- connections with via stations, ticket filter ("Nur Deutschlandticket"/"Nur BahnCard 100"), earlier/later pages
- journey details with stops, transfers, exit side, weather, CO₂, live data, "Alternative suchen"
- departure board with filters and favourites; train view (saving a ride); train number search
- saved journeys with notifications in the background (WorkManager, every 15 minutes)
- widgets "Reiseübersicht" (next saved journey, `JourneyWidgetState`) and "Abfahrten" (a station's departures,
  `BoardWidgetRows`), with Glance
- connections shared from DB Navigator

## Layout

| Path | Contents |
| --- | --- |
| `Android/kit/` | Swift package building BetterBahnKit for Android. `build.sh` links the Kit's source folders into `Sources/BetterBahnKit/` (gitignored), `Package.swift` leaves out what needs Apple frameworks, `Shims/` holds the Android stand-ins (FoundationNetworking/FoundationXML re-exported, a `WorkerAuth` that sends the Play Integrity token the app hands over). Output: `libBetterBahnKit.so` (Swift runtime linked in) + `libc++_shared.so` per ABI in `Android/app/src/main/jniLibs/`, the Kit's JSON data in `Android/app/src/main/assets/BetterBahnKit/` (both gitignored). |
| `Android/kit/Bridge/` | The bridge. `KitBridge.swift`: one JNI function taking a method name and JSON (UTF-8 bytes both ways), run on Swift concurrency. `Methods.swift`: one handler per method (`searchStations`, `journeys` incl. via stations and ticket filter, `completeJourney`, `refreshJourney`, `describeJourneys`, `refreshSaved` (live data plus what to notify, as `AppModel.refresh` on iOS), `journeyExtras` (CO₂, weather), `widgetState`, `boardWidgetRows`, `board`, `trip`, `tripForLeg`, `tripLeg`, `searchTrains`, `trainRun`, `importShared`, `plannedCoachSequence` (vagonweb.cz's plan; answers `needsPage:<url>` when its bot check wants the page loaded in a web view), `setWorkerToken`/`hasWorkerToken` (Play Integrity)), calling the Kit as the iOS views do (same provider, same steps). `Display.swift`: Kit models go out as their own Codable JSON (dates in ms) plus what iOS computes from them (line display name and colour, journey duration, bar spans, issues, intermediate stops …); route shapes are dropped. `StationNames.swift`: adds `displayName` to every station. |
| `Android/app/` | The Android app (Gradle, AGP 9, Kotlin, Compose, Material 3). `kit/`: `Kit.kt` loads the library, copies the JSON data out of the APK once per update and wraps the methods; `Models.kt` mirrors the Kit's JSON (journeys and trips keep it as `raw` to hand back); `PlayIntegrity.kt` gets the access token for our servers (below); `VagonwebBrowser.kt` loads vagonweb.cz pages in a hidden `WebView` with the iOS app's script; `KitJson.kt` reads answers (unit-tested against recorded answers in `src/test/resources/kit/`). `AppModel.kt`: tabs, a stack of screens per tab (state of results/detail lives in the route), saved journeys. `data/Store.kt`: favourites, recent stations and searches, saved journeys, the ticket, as JSON in SharedPreferences (one store per process). `data/SavedRefresh.kt`: refreshing saved journeys and notifying (in the app and in a `WorkManager` worker, which also reloads the widgets). `widget/`: the Glance widgets, the departures widget's station per widget ID and its config screen. `ui/`: the screens, `Theme.kt`/`Format.kt`/`Components.kt` port the iOS app's colours, formats and badges (`DesignSystem.swift`). |
| `Android/gradle/libs.versions.toml` | Versions of AGP, Kotlin, Compose. |

`applicationId` and package are `de.goldkunibert.betterbahn` (confirmed by the owner; permanent once the app is on
Google Play). `versionName`/`versionCode` come from `MARKETING_VERSION` and
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
There's no emulator in the cloud (no KVM), so the app is only built there and tested on the owner's PC. What can be
checked there: the bridge on Linux (a package with the same sources plus an executable calling `Methods.call`, or
the bridge built as a Linux `.so` against the JDK's `jni.h` and called from a JVM test through `Kit`), and Compose
screens rendered with Paparazzi in a scratch copy of `Android/`. Point `PACKAGE_RESOURCE_BUNDLE_PATH` at the folder
holding `<package>_BetterBahnKit.bundle`.

## What's not on Android yet

Left out of the Android Kit build (`Android/kit/Package.swift`) because they need Apple frameworks:

| Kit part | Needs | Android replacement (to do) |
| --- | --- | --- |
| `Support/WorkerAuth.swift` | DeviceCheck (App Attest), CryptoKit | Play Integrity (below): written, off until the Google setup exists. Until then requests go out without a token, which our servers refuse unless `ALLOW_UNATTESTED` is set, so bahn.de data doesn't work yet. |
| `Traewelling/` | CryptoKit (PKCE), Security (Keychain) | swift-crypto, Android Keystore via Kotlin |
| `Tickets/`, `Calendar/` | CryptoKit, PDFKit, Vision | Google Wallet passes (`pass-signer` needs a second format), ML Kit barcode scanning, Android calendar |
| `Sharing/JourneyShareLink.swift`, `ShortShareLinkClient.swift` | Compression (zlib) | zlib from the NDK |

Kit code behind `#if canImport(SwiftUI|ActivityKit|PDFKit)` (product colours, Live Activity attributes, ticket
scanning) compiles to nothing on Android.

Not ported yet (app side): tickets and passenger rights, Träwelling, live map, the live widgets and Live Activity, bike
option, "Anderer Zug", regular trips, statistics and the collection, sharing a journey, iCloud sync. bahn.de's
extras (train names, occupancy, live coach sequence) and the train statistics arrive once Play Integrity is there.
Wagenreihung: vagonweb.cz's plan is there (journey detail, "Wagenreihung" per leg), its page loaded in a hidden web
view when the bot check answers, as `VagonwebBrowser` does on iOS.

## Play Integrity

The Android counterpart to App Attest: our servers only answer the genuine app. `PlayIntegrity.kt` fetches a
challenge from `betterbahn2` (`/auth/challenge`), asks Google Play for a Standard integrity token with
`requestHash` = hex SHA-256 of the challenge, and trades it at `/auth/play` for the same one-hour access token the
iPhone gets (`Cloudflare/shared/playintegrity.mjs`: Google decodes the token for the Worker, which wants our
package, the matching hash, at most 5 minutes old, `PLAY_RECOGNIZED` and `MEETS_DEVICE_INTEGRITY`). Before every Kit
call the app renews it when it's missing or runs out within 5 minutes (after a failure, 5 minutes later), and hands
it to the Kit with `setWorkerToken`. `Server/bahnde-proxy` accepts it unchanged; each token has its own `kid`, so
the rate limit counts devices separately.

Off while `playCloudProjectNumber` in `Android/gradle.properties` is 0. Setup (owner):
1. Google Play Console (developer account), create the app with package `de.goldkunibert.betterbahn`.
2. Play Console → Test and release → App integrity → Play Integrity API: link a Google Cloud project (or create
   one). In the Cloud console enable the Play Integrity API for it.
3. Cloud console → IAM → Service accounts: create one (no roles needed), add a JSON key. Store it in the Worker:
   `cd Cloudflare/bahnde-proxy && npx wrangler secret put PLAY_INTEGRITY_KEY` (paste the JSON), `npx wrangler
   deploy`.
4. Put the Cloud project's number (Cloud console dashboard, not the ID) into `playCloudProjectNumber`.

Tokens only pass for builds installed from Google Play (internal testing track) on certified devices. An emulator
or a sideloaded debug build fails the app and device checks: for testing set `PLAY_INTEGRITY_ALLOW_TESTING =
"true"` in the Worker's vars (the challenge, package and age are still checked) and remove it before release.

Open technical points:
- **Resources**: SwiftPM's `Bundle.module` can't see into the APK. `Kit.start` copies the JSON data to
  `files/BetterBahnKit/BetterBahnKitAndroid_BetterBahnKit.bundle/` and the bridge points `PACKAGE_RESOURCE_BUNDLE_PATH`
  at the folder above it. SwiftPM reads that override only with `DEBUG` defined, so `Android/kit/Package.swift`
  defines it for the Kit (which uses `DEBUG` only for Apple's logging).
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
  image). Play Integrity never passes on an emulator: the Worker needs `PLAY_INTEGRITY_ALLOW_TESTING` (above) while
  testing there.
- Before a release: Firebase Test Lab or the Play Console pre-launch report (real devices in the cloud).
- Google Play: a new personal developer account must run a closed test with 12 testers for 14 days before the
  first public release. Data safety form and privacy policy (`/datenschutz`) as for the App Store.
