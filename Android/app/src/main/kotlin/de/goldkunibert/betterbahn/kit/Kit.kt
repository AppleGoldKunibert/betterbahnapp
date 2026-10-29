package de.goldkunibert.betterbahn.kit

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import java.io.File

/** A station as the Kit returns it (`Station` in BetterBahnKit, only the fields the app shows so far). */
data class Station(val id: String, val name: String, val region: String?)

/**
 * BetterBahnKit, the iOS app's Swift logic, built for Android by `Android/kit/build.sh`. The native side is
 * `Android/kit/Bridge/KitBridge.swift`; results come back as JSON of the Kit's own models.
 */
object Kit {
    init {
        System.loadLibrary("BetterBahnKit")
    }

    /** Copies the Kit's JSON data out of the APK (once per app update) and hands its folder to the Kit. */
    fun start(context: Context) {
        val dir = File(context.filesDir, "BetterBahnKit")
        val stamp = File(dir, ".installed")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (!stamp.exists() || stamp.readText() != installed) {
            dir.deleteRecursively()
            dir.mkdirs()
            for (name in context.assets.list("BetterBahnKit").orEmpty()) {
                context.assets.open("BetterBahnKit/$name").use { input ->
                    File(dir, name).outputStream().use { input.copyTo(it) }
                }
            }
            stamp.writeText(installed)
        }
        nativeStart(dir.absolutePath)
    }

    suspend fun searchStations(query: String): List<Station> = withContext(Dispatchers.IO) {
        val json = JSONArray(nativeSearchStations(query))
        List(json.length()) { i ->
            val station = json.getJSONObject(i)
            Station(station.getString("id"), station.getString("name"), station.optString("region").ifEmpty { null })
        }
    }

    private external fun nativeStart(resources: String)
    private external fun nativeSearchStations(query: String): String
}
