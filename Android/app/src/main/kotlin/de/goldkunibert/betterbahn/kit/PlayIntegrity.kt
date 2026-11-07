package de.goldkunibert.betterbahn.kit

import android.content.Context
import android.util.Log
import com.google.android.gms.tasks.Task
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import de.goldkunibert.betterbahn.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.long
import kotlinx.serialization.json.put
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * Proves to our servers that requests come from the genuine app from Google Play, the Android counterpart to App
 * Attest (`WorkerAuth` on iOS): a challenge from `/auth/challenge`, a Play Integrity token over it, and `/auth/play`
 * answers with the same access token the iPhone gets, valid for an hour. The Kit sends it along
 * (`Android/kit/Shims/AndroidShims.swift`). Off while `playCloudProjectNumber` (gradle.properties) is 0: requests
 * then go out without a token.
 */
object PlayIntegrity {
    private const val BASE = "https://betterbahn2.betterbahn.workers.dev/auth"
    private const val TAG = "PlayIntegrity"
    /** A token is replaced this long before it runs out. */
    private const val RENEW_BEFORE = 5 * 60 * 1000L
    /** After a failed attempt (offline, Play unavailable) the next one waits this long. */
    private const val RETRY_DELAY = 5 * 60 * 1000L

    val isActive get() = BuildConfig.PLAY_CLOUD_PROJECT_NUMBER != 0L

    private val mutex = Mutex()
    private var expiresAt = 0L
    private var failedAt = 0L
    private var provider: StandardIntegrityTokenProvider? = null

    /** Gets a fresh token when the Kit has none or it runs out soon. Never throws: without one requests still go out. */
    suspend fun ensureToken(context: Context) {
        if (!isActive) return
        mutex.withLock {
            val now = System.currentTimeMillis()
            if (expiresAt - now > RENEW_BEFORE && hasToken()) return
            if (now - failedAt < RETRY_DELAY) return
            try {
                val (token, expires) = fetchToken(context)
                Kit.callDirectly("setWorkerToken", buildJsonObject {
                    put("token", token)
                    put("expiresAt", expires)
                })
                expiresAt = expires
                failedAt = 0
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "No token: ${e.message}")
                provider = null
                failedAt = now
            }
        }
    }

    /** False once a server refused the token and the Kit forgot it. */
    private fun hasToken() = runCatching {
        Kit.callDirectly("hasWorkerToken", buildJsonObject {}).jsonPrimitive.content == "true"
    }.getOrDefault(false)

    private suspend fun fetchToken(context: Context): Pair<String, Long> {
        val challenge = request("$BASE/challenge", null).jsonObject["challenge"]!!.jsonPrimitive.content
        val tokenProvider = provider ?: IntegrityManagerFactory.createStandard(context.applicationContext)
            .prepareIntegrityToken(
                PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(BuildConfig.PLAY_CLOUD_PROJECT_NUMBER).build()
            ).await().also { provider = it }
        val integrityToken = tokenProvider
            .request(StandardIntegrityTokenRequest.builder().setRequestHash(sha256Hex(challenge)).build())
            .await().token()
        val answer = request("$BASE/play", buildJsonObject {
            put("integrityToken", integrityToken)
            put("challenge", challenge)
        }.toString()).jsonObject
        val expiresIn = answer["expiresIn"]!!.jsonPrimitive.long
        return answer["token"]!!.jsonPrimitive.content to System.currentTimeMillis() + expiresIn * 1000
    }

    /** GET, or POST with a JSON body; the answer's JSON. */
    private suspend fun request(url: String, body: String?) = withContext(Dispatchers.IO) {
        val connection = URL(url).openConnection() as HttpURLConnection
        try {
            connection.connectTimeout = 15_000
            connection.readTimeout = 15_000
            connection.setRequestProperty("Accept", "application/json")
            if (body != null) {
                connection.requestMethod = "POST"
                connection.doOutput = true
                connection.setRequestProperty("Content-Type", "application/json")
                connection.outputStream.use { it.write(body.toByteArray()) }
            }
            val status = connection.responseCode
            if (status != 200) error("$url: HTTP $status")
            Json.parseToJsonElement(connection.inputStream.bufferedReader().use { it.readText() })
        } finally {
            connection.disconnect()
        }
    }

    /** The `requestHash` the server expects: hex SHA-256 of the challenge. */
    fun sha256Hex(text: String): String =
        MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    private suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
        addOnSuccessListener { continuation.resume(it) }
        addOnFailureListener { continuation.resumeWithException(it) }
        addOnCanceledListener { continuation.cancel() }
    }
}
