package com.rubik3x3.rnote_mobile

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import java.io.File

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        // copy before the Flutter side lists the library
        if (savedInstanceState == null) importFromIntent(intent)
        super.onCreate(savedInstanceState)
    }

    override fun onNewIntent(intent: Intent) {
        importFromIntent(intent)
        super.onNewIntent(intent)
    }

    /**
     * Copies `.rnote` files opened or shared from other apps into the library
     * folder (`getApplicationDocumentsDirectory()/Rnote` on the Flutter side).
     * The library reloads when the app is resumed.
     */
    private fun importFromIntent(intent: Intent?) {
        if (intent == null) return
        val uris = mutableListOf<Uri>()
        when (intent.action) {
            Intent.ACTION_VIEW -> intent.data?.let { uris.add(it) }
            Intent.ACTION_SEND -> intentStream(intent)?.let { uris.add(it) }
            Intent.ACTION_SEND_MULTIPLE -> uris.addAll(intentStreams(intent))
            else -> return
        }
        val library = File(getDir("flutter", Context.MODE_PRIVATE), "Rnote")
        library.mkdirs()
        for (uri in uris) {
            try {
                val name = displayName(uri) ?: continue
                if (!name.lowercase().endsWith(".rnote")) continue
                val base = name.substring(0, name.length - ".rnote".length).replace('/', '_')
                var target = File(library, "$base.rnote")
                var i = 2
                while (target.exists()) {
                    target = File(library, "$base ($i).rnote")
                    i++
                }
                contentResolver.openInputStream(uri)?.use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (_: Exception) {
            }
        }
        // handled, do not import again on configuration changes
        intent.action = Intent.ACTION_MAIN
    }

    @Suppress("DEPRECATION")
    private fun intentStream(intent: Intent): Uri? =
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }

    @Suppress("DEPRECATION")
    private fun intentStreams(intent: Intent): List<Uri> =
        if (android.os.Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
        } else {
            intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM) ?: emptyList()
        }

    private fun displayName(uri: Uri): String? {
        if (uri.scheme == "file") return uri.lastPathSegment
        contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (idx >= 0) return c.getString(idx)
            }
        }
        return uri.lastPathSegment
    }
}
