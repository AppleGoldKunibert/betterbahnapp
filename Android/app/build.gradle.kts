plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
}

// Same version as the iOS app: bump-version.yml writes it into the Xcode project, read from there.
val xcodeProject = rootDir.resolve("../BetterBahn.xcodeproj/project.pbxproj").readText()
fun xcodeSetting(name: String) =
    Regex("$name = ([0-9.]+);").find(xcodeProject)?.groupValues?.get(1) ?: error("$name missing in the Xcode project")

android {
    namespace = "de.goldkunibert.betterbahn"
    compileSdk = 37

    defaultConfig {
        applicationId = "de.goldkunibert.betterbahn"
        minSdk = 28 // the Swift SDK for Android is built for API 28 (kit/build.sh)
        targetSdk = 37
        versionName = xcodeSetting("MARKETING_VERSION")
        versionCode = xcodeSetting("CURRENT_PROJECT_VERSION").toInt()
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
        // Play Integrity (PlayIntegrity.kt) stays off while this is 0.
        buildConfigField("long", "PLAY_CLOUD_PROJECT_NUMBER", "${providers.gradleProperty("playCloudProjectNumber").getOrElse("0")}L")
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

// BetterBahnKit (Swift) can't be built on Windows itself: there Android Studio builds it inside WSL2 before every
// build whose Kit sources changed (kit/build-wsl.sh, set up once with kit/setup-wsl.sh). Elsewhere kit/build.sh
// is run by hand or by CI. `-PskipKitBuild` skips the WSL build, e.g. to use libraries copied in from CI.
val kitDir = rootDir.resolve("kit")
val kitSources = rootDir.resolve("../Packages/BetterBahnKit/Sources")
val jniLibs = file("src/main/jniLibs")
val kitAssets = file("src/main/assets/BetterBahnKit")
val isWindows = System.getProperty("os.name").startsWith("Windows")

val buildKitInWsl = tasks.register<Exec>("buildKitInWsl") {
    group = "build"
    description = "Builds BetterBahnKit for Android inside WSL2 (Windows only)."
    onlyIf { isWindows && !providers.gradleProperty("skipKitBuild").isPresent }
    inputs.files(fileTree(kitDir) { exclude(".build/**", "Sources/**", ".linux-test/**", ".linux-bridge/**") })
    inputs.dir(kitSources)
    outputs.dir(jniLibs)
    outputs.dir(kitAssets)
    // The script may have CRLF line endings in a Windows checkout; bash wants LF.
    commandLine("wsl.exe", "--cd", rootDir.parentFile.absolutePath, "-e", "bash", "-c",
        "sed 's/\\r$//' Android/kit/build-wsl.sh | bash -s")
}

val checkKitLibraries = tasks.register("checkKitLibraries") {
    description = "Stops the build when BetterBahnKit's libraries are missing, instead of building an app that crashes."
    dependsOn(buildKitInWsl)
    val libraries = jniLibs
    doLast {
        // The WSL build makes only the emulator's x86_64; any one is enough to run somewhere.
        if (libraries.listFiles().orEmpty().none { it.resolve("libBetterBahnKit.so").exists() }) {
            throw GradleException(
                "BetterBahnKit for Android is missing (Android/app/src/main/jniLibs). " +
                    if (isWindows) "Set up WSL2 once with Android/kit/setup-wsl.sh (docs/android.md)."
                    else "Run Android/kit/build.sh first (docs/android.md)."
            )
        }
    }
}
tasks.named("preBuild") { dependsOn(checkKitLibraries) }

// KitBridgeTest calls the real bridge, built for Linux by Android/kit/bridge-linux.sh into this folder; without it
// those tests are skipped.
tasks.withType<Test>().configureEach {
    providers.environmentVariable("KIT_LINUX_DIR").orNull?.let {
        systemProperty("betterbahn.kitLinuxDir", it)
        systemProperty("java.library.path", it)
    }
}

dependencies {
    implementation(platform(libs.androidx.compose.bom))
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.compose.material3)
    implementation(libs.androidx.compose.ui)
    implementation(libs.androidx.compose.ui.tooling.preview)
    implementation(libs.androidx.compose.material.icons.extended)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.kotlinx.serialization.json)
    implementation(libs.androidx.work.runtime.ktx)
    implementation(libs.androidx.glance.appwidget)
    implementation(libs.androidx.glance.material3)
    implementation(libs.play.integrity)
    debugImplementation(libs.androidx.compose.ui.tooling)
    testImplementation(libs.junit)
}
