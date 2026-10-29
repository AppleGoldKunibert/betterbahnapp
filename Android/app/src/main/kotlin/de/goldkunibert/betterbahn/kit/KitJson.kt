package de.goldkunibert.betterbahn.kit

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/** Reading the Kit's answers; apart from [Kit] so unit tests can use it without the native library. */
object KitJson {
    val json = Json {
        ignoreUnknownKeys = true
        explicitNulls = false
        coerceInputValues = true
    }

    /** `{"ok": …}` or `{"error": "…"}`, see `Methods.call`. */
    fun parseAnswer(answer: String): JsonElement {
        val obj = json.parseToJsonElement(answer).jsonObject
        obj["error"]?.let { throw KitException(it.jsonPrimitive.content) }
        return obj.getValue("ok")
    }

    fun journeysPage(element: JsonElement): JourneysPage {
        val page = json.decodeFromJsonElement<JourneysPage>(element)
        val raws = element.jsonObject.getValue("journeys").jsonArray
        page.journeys.forEachIndexed { i, journey -> journey.raw = raws[i].jsonObject.getValue("journey").jsonObject }
        return page
    }

    fun journey(element: JsonElement): JourneyDisplay =
        json.decodeFromJsonElement<JourneyDisplay>(element).also {
            it.raw = element.jsonObject.getValue("journey").jsonObject
        }

    fun trip(element: JsonElement): TripDisplay =
        json.decodeFromJsonElement<TripDisplay>(element).also {
            it.raw = element.jsonObject.getValue("trip").jsonObject
        }

    fun trains(element: JsonElement): List<TrainResult> =
        element.jsonArray.map { item -> json.decodeFromJsonElement<TrainResult>(item).also { it.raw = item.jsonObject } }
}
