package de.goldkunibert.betterbahn.kit

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import java.io.File

/** A failed Kit call, with the Kit's (German) message. */
class KitException(message: String) : Exception(message)

/**
 * BetterBahnKit, the iOS app's Swift logic, built for Android by `Android/kit/build.sh`. Every call goes through
 * one JNI function with a method name and JSON (`Android/kit/Bridge/Methods.swift`).
 */
object Kit {
    private val json = KitJson.json

    init {
        System.loadLibrary("BetterBahnKit")
    }

    private var started = false

    /**
     * Copies the Kit's JSON data out of the APK (once per app update) and hands its folder to the Kit, once per
     * process: the app, its widgets and the background refresh all call this, maybe at the same time. SwiftPM looks
     * for `<package>_<target>.bundle` inside the folder it's given.
     */
    @Synchronized
    fun start(context: Context) {
        if (started) return
        val base = File(context.filesDir, "BetterBahnKit")
        val bundle = File(base, "BetterBahnKitAndroid_BetterBahnKit.bundle")
        val stamp = File(base, ".installed")
        val installed = context.packageManager.getPackageInfo(context.packageName, 0).lastUpdateTime.toString()
        if (!stamp.exists() || stamp.readText() != installed || !bundle.isDirectory) {
            // Copied next to it first, then swapped in, so the data is never half there.
            val fresh = File(context.filesDir, "BetterBahnKit.new")
            fresh.deleteRecursively()
            val freshBundle = File(fresh, bundle.name).apply { mkdirs() }
            for (name in context.assets.list("BetterBahnKit").orEmpty()) {
                context.assets.open("BetterBahnKit/$name").use { input ->
                    File(freshBundle, name).outputStream().use { input.copyTo(it) }
                }
            }
            File(fresh, stamp.name).writeText(installed)
            base.deleteRecursively()
            fresh.renameTo(base)
        }
        nativeStart(base.absolutePath)
        appContext = context.applicationContext
        started = true
    }

    @Volatile private var appContext: Context? = null

    /**
     * Runs a Kit method off the main thread; its result, or a [KitException]. Gets the Play Integrity token for our
     * servers first when it's missing or about to expire.
     */
    suspend fun call(method: String, arguments: JsonObject): JsonElement = withContext(Dispatchers.IO) {
        appContext?.let { PlayIntegrity.ensureToken(it) }
        callDirectly(method, arguments)
    }

    /** [call] without the token check, for [PlayIntegrity] itself. */
    internal fun callDirectly(method: String, arguments: JsonObject): JsonElement =
        KitJson.parseAnswer(String(nativeCall(method, arguments.toString().toByteArray()), Charsets.UTF_8))

    // MARK: Methods

    suspend fun searchStations(text: String): List<Station> =
        json.decodeFromJsonElement(call("searchStations", buildJsonObject { put("text", text) }))

    suspend fun journeys(
        from: Station,
        to: Station,
        date: Long,
        isArrival: Boolean,
        cursor: String? = null,
        products: Set<Product>? = null,
        maxTransfers: Int? = null,
        via: List<Station> = emptyList(),
        ticket: TicketType? = null,
    ): JourneysPage {
        val result = call("journeys", buildJsonObject {
            put("from", json.encodeToJsonElement(from))
            put("to", json.encodeToJsonElement(to))
            put("date", date)
            put("isArrival", isArrival)
            cursor?.let { put("cursor", it) }
            products?.let { set -> put("products", json.encodeToJsonElement(set.map { it.id })) }
            maxTransfers?.let { put("maxTransfers", it) }
            ticket?.let { put("ticket", it.id) }
            if (via.isNotEmpty()) {
                put("via", JsonArray(via.map { station ->
                    buildJsonObject {
                        put("station", json.encodeToJsonElement(station))
                        put("minStayMinutes", 0)
                    }
                }))
            }
        })
        return KitJson.journeysPage(result)
    }

    suspend fun completeJourney(raw: JsonObject): JourneyDisplay = KitJson.journey(call("completeJourney", journeyArgs(raw)))

    suspend fun refreshJourney(raw: JsonObject): JourneyDisplay = KitJson.journey(call("refreshJourney", journeyArgs(raw)))

    suspend fun describeJourneys(raws: List<JsonObject>): List<JourneyDisplay> {
        val result = call("describeJourneys", buildJsonObject { put("journeys", JsonArray(raws)) })
        return result.jsonArray.map(KitJson::journey)
    }

    suspend fun board(
        station: Station,
        departures: Boolean,
        date: Long,
        duration: Int,
        products: Set<Product>?,
        ticket: TicketType? = null,
    ): List<BoardEntryDisplay> =
        json.decodeFromJsonElement(call("board", buildJsonObject {
            ticket?.let { put("ticket", it.id) }
            put("station", json.encodeToJsonElement(station))
            put("kind", if (departures) "departures" else "arrivals")
            put("date", date)
            put("duration", duration)
            products?.let { set -> put("products", json.encodeToJsonElement(set.map { it.id })) }
        }))

    suspend fun trip(id: String, source: String): TripDisplay =
        KitJson.trip(call("trip", buildJsonObject {
            put("id", id)
            put("source", source)
        }))

    suspend fun tripForLeg(rawLeg: JsonObject): TripDisplay =
        KitJson.trip(call("tripForLeg", buildJsonObject { put("leg", rawLeg) }))

    /** The ride from stop [from] to stop [to] of a trip, as a journey to save. */
    suspend fun tripLeg(trip: TripDisplay, from: Int, to: Int): JourneyDisplay =
        KitJson.journey(call("tripLeg", buildJsonObject {
            put("trip", trip.raw)
            put("from", from)
            put("to", to)
        }))

    suspend fun searchTrains(text: String, date: Long): List<TrainResult> =
        KitJson.trains(call("searchTrains", buildJsonObject {
            put("text", text)
            put("date", date)
        }))

    suspend fun trainRun(result: TrainResult): TrainRun {
        val answer = call("trainRun", buildJsonObject { put("result", result.raw) }).jsonObject
        return TrainRun(json.decodeFromJsonElement(answer.getValue("entry")), KitJson.trip(answer.getValue("trip")))
    }

    /** Fresh data for a saved journey and what's new to notify about. */
    suspend fun refreshSaved(raw: JsonObject, notified: List<String>): RefreshedSaved {
        val answer = call("refreshSaved", buildJsonObject {
            put("journey", raw)
            put("notified", json.encodeToJsonElement(notified))
        }).jsonObject
        return RefreshedSaved(
            KitJson.journey(answer.getValue("journey")),
            json.decodeFromJsonElement(answer.getValue("notifications")),
            json.decodeFromJsonElement(answer.getValue("notified")),
        )
    }

    suspend fun journeyExtras(raw: JsonObject): JourneyExtras = json.decodeFromJsonElement(call("journeyExtras", journeyArgs(raw)))

    /** The widget's state for the next of these saved journeys; null when none is coming. */
    suspend fun widgetState(raws: List<JsonObject>): WidgetState? {
        val result = call("widgetState", buildJsonObject { put("journeys", JsonArray(raws)) })
        return if (result is kotlinx.serialization.json.JsonNull) null else json.decodeFromJsonElement(result)
    }

    suspend fun boardWidgetRows(station: Station, products: Set<Product>?): List<BoardWidgetRow> =
        json.decodeFromJsonElement(call("boardWidgetRows", buildJsonObject {
            put("station", json.encodeToJsonElement(station))
            products?.let { set -> put("products", json.encodeToJsonElement(set.map { it.id })) }
        }))

    /** vagonweb pages loaded in the web view this run, by URL. */
    private val vagonwebPages = java.util.concurrent.ConcurrentHashMap<String, String>()

    /**
     * The planned Wagenreihung of a journey's leg from vagonweb.cz, null when vagonweb has none. When vagonweb's bot
     * check turns the Kit's plain request away, the Kit asks for the page ("needsPage:<url>"); it is loaded in a
     * hidden web view ([VagonwebBrowser], as on iOS) and the Kit asked again with it.
     */
    suspend fun plannedCoachSequence(context: Context, rawLeg: JsonObject): CoachSequence? {
        repeat(4) {
            try {
                val result = call("plannedCoachSequence", buildJsonObject {
                    put("leg", rawLeg)
                    put("pages", JsonObject(vagonwebPages.mapValues { kotlinx.serialization.json.JsonPrimitive(it.value) }))
                })
                return if (result is kotlinx.serialization.json.JsonNull) null else json.decodeFromJsonElement(result)
            } catch (e: KitException) {
                val url = e.message?.removePrefix("needsPage:")?.takeIf { e.message?.startsWith("needsPage:") == true } ?: throw e
                vagonwebPages[url] = VagonwebBrowser.html(context, url) ?: throw KitException("Die Wagenreihung ist gerade nicht abrufbar.")
            }
        }
        return null
    }

    /** A connection shared from DB Navigator, found again. */
    suspend fun importShared(text: String): JourneyDisplay =
        KitJson.journey(call("importShared", buildJsonObject { put("text", text) }))

    private fun journeyArgs(raw: JsonObject) = buildJsonObject { put("journey", raw) }

    private external fun nativeStart(resources: String)
    private external fun nativeCall(method: String, arguments: ByteArray): ByteArray
}
