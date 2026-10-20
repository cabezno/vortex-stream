package com.vortex.vortexcam.studio

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

// Switcher recordings in the phone's gallery (Movies/Samba Air) instead of the app's private folder, where nothing —
// gallery, file manager, USB — could reach them and an uninstall deleted them (2026-10-15). The encoder still writes a
// plain file (MediaMuxer wants a path); on stop it is copied into MediaStore and the private copy removed.
// Android 9 and older: no RELATIVE_PATH without the storage permission, so the files stay in the app's external folder
// (Android/data/…/files/Movies, reachable over USB) and are listed from there.
class RecordingsStore private constructor(private val ctx: Context) {
    companion object {
        private const val TAG = "Recordings"
        private const val CHANNEL = "com.samba.studio/recordings"
        private const val FOLDER = "Samba Air"
        @JvmStatic fun registerWith(engine: FlutterEngine, ctx: Context) =
            RecordingsStore(ctx).also { it.register(engine) }
    }

    private val io = Executors.newSingleThreadExecutor()
    private val modern = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    private fun register(engine: FlutterEngine) {
        val main = android.os.Handler(android.os.Looper.getMainLooper())
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            // Copies and queries touch storage: off the UI thread, answer on it.
            fun bg(work: () -> Any?) = io.execute {
                val r = try { Result.success(work()) } catch (e: Exception) { Result.failure(e) }
                main.post {
                    r.fold({ result.success(it) }, { result.error("recordings", it.message, null) })
                }
            }
            when (call.method) {
                "publish" -> bg { publish(File(call.argument<String>("path")!!)) }
                "list" -> bg { list() }
                // false = no app could take it (Android 9-: a file:// uri can't be handed to another app).
                "open" -> result.success(tryStart { open(call.argument<String>("uri")!!) })
                "share" -> result.success(tryStart { share(call.argument<String>("uri")!!) })
                "legacyDir" -> result.success(legacyDir().absolutePath)
                else -> result.notImplemented()
            }
        }
    }

    private fun legacyDir(): File =
        File(ctx.getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: ctx.filesDir, FOLDER).apply { mkdirs() }

    /** Moves a finished recording into the gallery. Returns its uri (content:// or file://). */
    private fun publish(src: File): String {
        require(src.exists() && src.length() > 0) { "no existe o está vacío: ${src.path}" }
        if (!modern) {
            val dst = File(legacyDir(), src.name)
            if (!src.renameTo(dst)) { src.copyTo(dst, overwrite = true); src.delete() }
            return Uri.fromFile(dst).toString()
        }
        val cr = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Video.Media.DISPLAY_NAME, src.name)
            put(MediaStore.Video.Media.MIME_TYPE, "video/mp4")
            put(MediaStore.Video.Media.RELATIVE_PATH, "${Environment.DIRECTORY_MOVIES}/$FOLDER")
            put(MediaStore.Video.Media.IS_PENDING, 1)
        }
        val uri = cr.insert(MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY), values)
            ?: error("MediaStore no creó el archivo")
        try {
            cr.openOutputStream(uri)!!.use { out -> src.inputStream().use { it.copyTo(out, 1 shl 20) } }
            cr.update(uri, ContentValues().apply { put(MediaStore.Video.Media.IS_PENDING, 0) }, null, null)
        } catch (e: Exception) {
            cr.delete(uri, null, null)   // never leave a half copy in the gallery; the private file stays
            throw e
        }
        src.delete()
        Log.i(TAG, "publicada ${src.name} → $uri")
        return uri.toString()
    }

    /** The switcher's recordings, newest first: uri, name, bytes, ms, date (epoch s). */
    private fun list(): List<Map<String, Any?>> {
        if (!modern) {
            return legacyDir().listFiles { f -> f.extension == "mp4" }.orEmpty()
                .sortedByDescending { it.lastModified() }
                .map { f ->
                    mapOf("uri" to Uri.fromFile(f).toString(), "name" to f.name, "bytes" to f.length(),
                          "ms" to durationOf(Uri.fromFile(f)), "date" to f.lastModified() / 1000)
                }
        }
        val out = ArrayList<Map<String, Any?>>()
        val col = MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val proj = arrayOf(MediaStore.Video.Media._ID, MediaStore.Video.Media.DISPLAY_NAME, MediaStore.Video.Media.SIZE,
                           MediaStore.Video.Media.DURATION, MediaStore.Video.Media.DATE_ADDED)
        ctx.contentResolver.query(col, proj, "${MediaStore.Video.Media.RELATIVE_PATH} LIKE ?",
            arrayOf("${Environment.DIRECTORY_MOVIES}/$FOLDER%"), "${MediaStore.Video.Media.DATE_ADDED} DESC")?.use { c ->
            while (c.moveToNext()) {
                val uri = ContentUris.withAppendedId(col, c.getLong(0))
                val ms = c.getLong(3).takeIf { it > 0 } ?: durationOf(uri)
                out += mapOf("uri" to uri.toString(), "name" to c.getString(1), "bytes" to c.getLong(2),
                             "ms" to ms, "date" to c.getLong(4))
            }
        }
        return out
    }

    // MediaStore fills DURATION a while after the copy, and not at all for an MP4 left unclosed by a crash.
    private fun durationOf(uri: Uri): Long = try {
        MediaMetadataRetriever().run {
            try { setDataSource(ctx, uri); extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLong() ?: 0L }
            finally { release() }
        }
    } catch (_: Exception) { 0L }

    private fun tryStart(start: () -> Unit): Boolean =
        try { start(); true } catch (e: Exception) { Log.w(TAG, "no se pudo abrir: ${e.message}"); false }

    private fun open(uri: String) {
        ctx.startActivity(Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(Uri.parse(uri), "video/mp4")
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        })
    }

    private fun share(uri: String) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "video/mp4"
            putExtra(Intent.EXTRA_STREAM, Uri.parse(uri))
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        ctx.startActivity(Intent.createChooser(send, "Compartir grabación").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    }
}
