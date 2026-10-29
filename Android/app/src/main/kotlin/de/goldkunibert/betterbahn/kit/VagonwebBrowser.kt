package de.goldkunibert.betterbahn.kit

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import kotlin.coroutines.resume

/**
 * Loads vagonweb.cz pages in a hidden web view (`VagonwebBrowser` on iOS), for when vagonweb's bot check turns the
 * Kit's plain request away: a browser engine gets through, and its cookie keeps later loads quick. vagonweb gave
 * written permission to use its data. One page at a time.
 */
object VagonwebBrowser {
    private val one = Mutex()

    /** The page's HTML once vagonweb's own page has loaded, or null after 25 seconds. */
    suspend fun html(context: Context, url: String): String? = one.withLock {
        withContext(Dispatchers.Main) {
            val view = newView(context.applicationContext)
            try {
                view.loadUrl(url)
                repeat(50) {
                    delay(500)
                    evaluate(view)?.let { return@withContext it }
                }
                null
            } finally {
                view.stopLoading()
                view.destroy()
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun newView(context: Context) = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        webViewClient = WebViewClient()
    }

    private suspend fun evaluate(view: WebView): String? = suspendCancellableCoroutine { continuation ->
        view.evaluateJavascript(SCRIPT) { result ->
            // The value comes as JSON: a quoted string, or null.
            val value = runCatching { KitJson.json.parseToJsonElement(result ?: "null") }.getOrNull()
            continuation.resume(if (value is JsonPrimitive && value !is JsonNull && value.isString) value.content else null)
        }
    }

    /**
     * The iOS script (`VagonwebBrowser.htmlScript`): the page's HTML once vagonweb's own page has loaded (it has the
     * `stred0` content column, the bot check doesn't). On a first visit vagonweb shows only an "anzeigen" link; then
     * the scheduled compositions are fetched inside the page, as its own "all planned" button does. Android's
     * evaluateJavascript can't wait for that fetch, so its answer is kept on the page and read on a later round.
     */
    private const val SCRIPT = """
        (function () {
          if (document.readyState !== 'complete' || !document.getElementById('stred0')) return null;
          if (document.getElementById('planovane_razeni')) return document.documentElement.outerHTML;
          if (window.__betterbahn !== undefined) return window.__betterbahn;
          window.__betterbahn = null;
          const query = new URLSearchParams(location.search);
          const year = query.get('rok') || '';
          const form = new URLSearchParams({rok: year, zeme: query.get('zeme') || 'DB', cislo: query.get('cislo') || '',
              nazev: '_n_', styl: 'r', aktualni_rok: year, cislo_vozu: '', od: '', do_x: '', virtualni_vlak: '',
              cislo_alias: '', vsechny_planovane: '1'});
          fetch('/razeni/ajax_dalsi_razeni_vlak.php', {method: 'POST', body: form,
              headers: {'X-Requested-With': 'XMLHttpRequest'}})
            .then(function (response) { return response.text(); })
            .then(function (part) { window.__betterbahn = part.includes('color-z') ? part : document.documentElement.outerHTML; })
            .catch(function () { window.__betterbahn = document.documentElement.outerHTML; });
          return null;
        })()
    """
}
