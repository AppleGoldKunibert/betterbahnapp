// The JNI functions the Android app calls (Android/app/.../kit/Kit.kt). Results go to Kotlin as JSON, the
// Kit's own Codable models, so the bridge stays a thin layer and the logic stays in BetterBahnKit.
import BetterBahnKit
import Dispatch
import Foundation
import jni

/// Called once at app start with the folder the app copied the Kit's JSON data to (station names, platforms …).
@_cdecl("Java_de_goldkunibert_betterbahn_kit_Kit_nativeStart")
public func nativeStart(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass, _ resources: jstring) {
    // SwiftPM's resource lookup can't see into the APK; it reads this override instead (debug builds only,
    // see docs/android.md).
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", string(env, resources), 1)
}

/// Station search through Transitous: the stations as a JSON array of `Station`.
@_cdecl("Java_de_goldkunibert_betterbahn_kit_Kit_nativeSearchStations")
public func nativeSearchStations(_ env: UnsafeMutablePointer<JNIEnv?>, _ cls: jclass, _ query: jstring) -> jstring? {
    let text = string(env, query)
    let json = blocking {
        let stations = (try? await TransitousProvider().searchStations(text)) ?? []
        return (try? JSONEncoder().encode(stations)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }
    return env.pointee!.pointee.NewStringUTF(env, json)
}

private func string(_ env: UnsafeMutablePointer<JNIEnv?>, _ value: jstring) -> String {
    let jni = env.pointee!.pointee
    guard let chars = jni.GetStringUTFChars(env, value, nil) else { return "" }
    defer { jni.ReleaseStringUTFChars(env, value, chars) }
    return String(cString: chars)
}

private final class ResultBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// Runs async Kit code for a JNI call. Kotlin calls these from a background thread, never the main thread.
private func blocking<Value: Sendable>(_ work: @escaping @Sendable () async -> Value) -> Value {
    let box = ResultBox<Value>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await work()
        done.signal()
    }
    done.wait()
    return box.value!
}
