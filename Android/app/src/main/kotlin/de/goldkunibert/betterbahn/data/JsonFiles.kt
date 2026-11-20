package de.goldkunibert.betterbahn.data

import android.content.Context
import java.io.File
import java.util.concurrent.Executors

/**
 * The app's lists as JSON files in `files/BetterBahn/<key>.json`, as the iOS app's `Storage` keeps them in
 * Application Support: no size limit like SharedPreferences (saved journeys grow), and backed up by Android's
 * Auto Backup (`res/xml/backup_rules.xml`).
 */
class JsonFiles(context: Context) {
    private val directory = File(context.filesDir, "BetterBahn").apply { mkdirs() }

    /** One writer, so writes land in the order they were made and the last change always wins. */
    private val writer = Executors.newSingleThreadExecutor { Thread(it, "BetterBahn storage").apply { isDaemon = true } }

    private fun file(key: String) = File(directory, "$key.json")

    fun read(key: String): String? = file(key).takeIf { it.exists() }?.let { runCatching { it.readText() }.getOrNull() }

    /** Writes in the background: first to a temporary file, then renamed, so a crash never leaves half a file. */
    fun write(key: String, text: String) {
        writer.execute {
            val temporary = File(directory, "$key.json.tmp")
            runCatching {
                temporary.writeText(text)
                if (!temporary.renameTo(file(key))) temporary.delete()
            }
        }
    }

    /** Moves a value older versions kept in SharedPreferences into its file, as is, unless the file exists. */
    fun migrate(prefs: android.content.SharedPreferences, key: String) {
        val old = prefs.getString(key, null) ?: return
        if (!file(key).exists()) runCatching { file(key).writeText(old) }.getOrElse { return }
        prefs.edit().remove(key).apply()
    }
}
