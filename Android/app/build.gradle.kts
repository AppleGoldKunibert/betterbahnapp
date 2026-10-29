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
