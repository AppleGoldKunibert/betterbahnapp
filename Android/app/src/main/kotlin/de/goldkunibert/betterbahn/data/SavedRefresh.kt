package de.goldkunibert.betterbahn.data

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import de.goldkunibert.betterbahn.MainActivity
import de.goldkunibert.betterbahn.R
import de.goldkunibert.betterbahn.kit.JourneyDisplay
import de.goldkunibert.betterbahn.kit.Kit
import de.goldkunibert.betterbahn.kit.SavedNotification
import de.goldkunibert.betterbahn.ui.timeString
import java.util.concurrent.TimeUnit

/**
 * Fresh live data for saved journeys departing within 24 hours, and notifications for what's new: broken or
 * tight transfers, cancelled trains, delay reasons, platform changes (`refreshSavedJourneys` on iOS). Runs while
 * the app is open (every 5 minutes on "Reisen") and in the background ([SavedRefreshWorker]).
 */
object SavedRefresh {
    private const val HORIZON = 24 * 3600_000L

    /** Refreshes what is due; [onFresh] gets each journey as the Kit now describes it. */
    suspend fun run(context: Context, onFresh: (id: String, JourneyDisplay) -> Unit = { _, _ -> }) {
        val store = Store.get(context)
        val now = System.currentTimeMillis()
        val due = store.savedJourneys.value.filter { entry ->
            val departure = entry.journey.departure() ?: return@filter false
            val arrival = entry.journey.arrival() ?: departure
            departure - now < HORIZON && arrival + 10 * 60_000 > now
        }
        for (entry in due) {
            val result = runCatching { Kit.refreshSaved(entry.journey, entry.notified) }.getOrNull() ?: continue
            // Saved again or deleted meanwhile: this result belongs to an old plan.
            if (store.savedJourneys.value.none { it.id == entry.id && it.journeyId == entry.journeyId }) continue
            store.update(entry.id, result.journey.id, result.journey.raw, result.notified)
            onFresh(entry.id, result.journey)
            result.notifications.forEach { Notifier.show(context, it, entry.id) }
        }
    }

    /** Planned departure/arrival from the stored JSON, without asking the Kit. */
    private fun kotlinx.serialization.json.JsonObject.departure(): Long? = legTime(first = true, key = "departure")
    private fun kotlinx.serialization.json.JsonObject.arrival(): Long? = legTime(first = false, key = "arrival")

    private fun kotlinx.serialization.json.JsonObject.legTime(first: Boolean, key: String): Long? {
        val legs = this["legs"] as? kotlinx.serialization.json.JsonArray ?: return null
        val leg = (if (first) legs.firstOrNull() else legs.lastOrNull()) as? kotlinx.serialization.json.JsonObject ?: return null
        val time = leg[key] as? kotlinx.serialization.json.JsonObject ?: return null
        val value = time["actual"] ?: time["planned"] ?: return null
        return (value as? kotlinx.serialization.json.JsonPrimitive)?.content?.toDoubleOrNull()?.toLong()
    }

    /** Every 15 minutes (Android's shortest), as long as there are saved journeys. */
    fun schedule(context: Context) {
        val request = PeriodicWorkRequestBuilder<SavedRefreshWorker>(15, TimeUnit.MINUTES).build()
        WorkManager.getInstance(context).enqueueUniquePeriodicWork("savedRefresh", ExistingPeriodicWorkPolicy.KEEP, request)
    }
}

class SavedRefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        if (Store.get(applicationContext).savedJourneys.value.isEmpty()) return Result.success()
        Kit.start(applicationContext)
        SavedRefresh.run(applicationContext)
        return Result.success()
    }
}

/** Local notifications for saved journeys (`ConnectionNotifier` on iOS). */
object Notifier {
    private const val CHANNEL = "journeys"

    fun createChannel(context: Context) {
        val channel = NotificationChannel(CHANNEL, "Deine Reisen", NotificationManager.IMPORTANCE_HIGH).apply {
            description = "Ausfälle, knappe Umstiege, Verspätungsgründe und Gleiswechsel"
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    fun canNotify(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun show(context: Context, notification: SavedNotification, savedId: String) {
        if (!canNotify(context)) return
        val lines = notification.lines.toMutableList()
        notification.since?.let { since -> if (lines.isNotEmpty()) lines[0] = lines[0] + " (seit ${timeString(since)})" }
        val text = lines.joinToString("\n")
        val open = PendingIntent.getActivity(
            context, savedId.hashCode(),
            Intent(context, MainActivity::class.java).putExtra(MainActivity.EXTRA_SAVED_ID, savedId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val built = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(notification.title)
            .setContentText(lines.firstOrNull())
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(if (notification.urgent) NotificationCompat.PRIORITY_MAX else NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_STATUS)
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        try {
            NotificationManagerCompat.from(context).notify((notification.id + savedId).hashCode(), built)
        } catch (_: SecurityException) {
            // Permission taken away meanwhile.
        }
    }
}
