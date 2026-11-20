// The JNI entry points of libBetterBahnKit.so (Android/app/.../kit/Kit.kt). Kotlin calls one function with a
// method name and JSON arguments and gets JSON back (`Methods.swift`), so the bridge stays a thin layer and the
// logic stays in BetterBahnKit.
import Dispatch
import Foundation
import jni

/// Called once at app start with the folder the app copied the Kit's JSON data to (station names, platforms …).
@_cdecl("Java_de_goldkunibert_betterbahn_kit_Kit_nativeStart")
public func nativeStart(_ env: UnsafeMutablePointer<JNIEnv?>, _ this: jobject, _ resources: jstring) {
    // SwiftPM's resource lookup can't see into the APK; it looks for its bundle in this folder instead (Package.swift
    // makes it read the override in release builds too).
    let folder = string(env, resources)
    setenv("PACKAGE_RESOURCE_BUNDLE_PATH", folder, 1)
    // An app process has no home or temp folder of its own: give Foundation the app's files folder, so the Kit's
    // caches (UserDefaults, the caches directory) can be written. `folder` is <files>/BetterBahnKit.
    let files = (folder as NSString).deletingLastPathComponent
    let cache = files + "/cache"
    try? FileManager.default.createDirectory(atPath: cache, withIntermediateDirectories: true)
    setenv("HOME", files, 1)
    setenv("TMPDIR", cache, 1)
    setenv("XDG_CACHE_HOME", cache, 1)
    setenv("XDG_CONFIG_HOME", files + "/config", 1)
}

/// Runs `method` with `arguments` (a JSON object) and answers `{"ok": result}` or `{"error": "message"}`. JSON
/// goes both ways as UTF-8 bytes: JNI's own strings use modified UTF-8, which mangles emoji.
@_cdecl("Java_de_goldkunibert_betterbahn_kit_Kit_nativeCall")
public func nativeCall(_ env: UnsafeMutablePointer<JNIEnv?>, _ this: jobject, _ method: jstring, _ arguments: jbyteArray) -> jbyteArray? {
    let jni = env.pointee!.pointee
    let name = string(env, method)
    let count = Int(jni.GetArrayLength(env, arguments))
    var input = Data(count: count)
    input.withUnsafeMutableBytes { jni.GetByteArrayRegion(env, arguments, 0, jsize(count), $0.bindMemory(to: jbyte.self).baseAddress) }
    let json = input
    let answer = Array(blocking { await Methods.call(name, json) }.utf8)
    guard let result = jni.NewByteArray(env, jsize(answer.count)) else { return nil }
    answer.withUnsafeBytes { jni.SetByteArrayRegion(env, result, 0, jsize(answer.count), $0.bindMemory(to: jbyte.self).baseAddress) }
    return result
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
