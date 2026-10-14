package ec.amoba.lector_amoba

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.OpenableColumns
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.Executors
import org.json.JSONObject
import android.net.Uri

class MainActivity : AudioServiceActivity() {
    companion object {
        // Survives activity recreation while the playback service keeps running.
        private var wakeLock: PowerManager.WakeLock? = null
        private const val HANDLED = "ec.amoba.lector.HANDLED"
        private const val MAX_BYTES = 30 * 1024 * 1024
    }

    private val executor = Executors.newSingleThreadExecutor()
    private val intents = Executors.newSingleThreadExecutor()
    private var intentChannel: MethodChannel? = null
    private var pendingDocument: Map<String, Any>? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        intentChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ec.amoba.lector/intent")
            .apply {
                setMethodCallHandler { call, result ->
                    if (call.method != "takeDocument") {
                        result.notImplemented()
                        return@setMethodCallHandler
                    }
                    result.success(pendingDocument)
                    pendingDocument = null
                }
            }
        receive(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ec.amoba.lector/power")
            .setMethodCallHandler { call, result ->
                if (call.method != "keepAwake") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                keepAwake(call.arguments == true)
                result.success(null)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ec.amoba.lector/model")
            .setMethodCallHandler { call, result ->
                if (call.method != "prepareModel") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                executor.execute {
                    try {
                        val root = "flutter_assets/assets/model"
                        val manifest = assets.open("$root/manifest.json").bufferedReader().use { JSONObject(it.readText()) }
                        val directory = File(filesDir, "kokoro-es-v1").apply { mkdirs() }
                        val entries = manifest.getJSONArray("files")
                        for (i in 0 until entries.length()) {
                            val entry = entries.getJSONObject(i)
                            val name = entry.getString("path")
                            require(!name.contains("..") && !name.startsWith("/"))
                            val target = File(directory, name)
                            val expected = entry.getString("sha256")
                            if (target.exists() && target.length() == entry.getLong("bytes") && digest(target) == expected) continue
                            target.parentFile?.mkdirs()
                            val temporary = File(directory, "$name.tmp")
                            val assetName = Uri.encode(name, "/!$&'()*+,-.:;=@_~")
                            assets.open("$root/$assetName").use { input ->
                                temporary.outputStream().use { output -> input.copyTo(output, 65536) }
                            }
                            check(digest(temporary) == expected) { "Integridad inválida: $name" }
                            if (target.exists()) check(target.delete())
                            check(temporary.renameTo(target)) { "No se pudo instalar $name" }
                        }
                        runOnUiThread { result.success(directory.absolutePath) }
                    } catch (error: Exception) {
                        runOnUiThread { result.error("MODEL_RESOURCES", "No se pudo preparar Kokoro: ${error.message}", null) }
                    }
                }
            }
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    // "Open with" and "Share" from other apps: read the file (or shared text)
    // here, where the URI permission was granted, and hand it to Dart.
    private fun receive(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(HANDLED, false)) return
        val action = intent.action
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return
        intent.putExtra(HANDLED, true)
        val uri: Uri? = if (action == Intent.ACTION_VIEW) intent.data else if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_STREAM)
        }
        val text = intent.getStringExtra(Intent.EXTRA_TEXT)
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        intents.execute {
            val document: Map<String, Any>? = try {
                if (uri != null) {
                    val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                        ?.use { if (it.moveToFirst()) it.getString(0) else null }
                        ?: uri.lastPathSegment ?: "documento"
                    val bytes = contentResolver.openInputStream(uri)!!.use { input ->
                        val buffer = java.io.ByteArrayOutputStream()
                        val block = ByteArray(65536)
                        var count = input.read(block)
                        while (count != -1) {
                            buffer.write(block, 0, count)
                            check(buffer.size() <= MAX_BYTES) { "El documento es demasiado grande." }
                            count = input.read(block)
                        }
                        buffer.toByteArray()
                    }
                    mapOf("name" to name, "bytes" to bytes)
                } else if (!text.isNullOrBlank()) {
                    val title = subject?.takeIf { it.isNotBlank() }?.take(60) ?: "Texto compartido"
                    mapOf("name" to "$title.txt", "bytes" to text.toByteArray())
                } else {
                    null
                }
            } catch (error: Exception) {
                mapOf("error" to (error.message ?: "No se pudo abrir el documento."))
            }
            if (document != null) runOnUiThread {
                pendingDocument = document
                intentChannel?.invokeMethod("documentAvailable", null)
            }
        }
    }

    private fun keepAwake(value: Boolean) {
        val power = applicationContext.getSystemService(Context.POWER_SERVICE) as PowerManager
        val lock = wakeLock ?: power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "lector:reading")
            .apply { setReferenceCounted(false) }
            .also { wakeLock = it }
        // The timeout bounds a lock that a crashed Dart side never releases.
        if (value) lock.acquire(3 * 60 * 60 * 1000L) else if (lock.isHeld) lock.release()
    }

    private fun digest(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            var count = input.read(buffer)
            while (count != -1) {
                hash.update(buffer, 0, count)
                count = input.read(buffer)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }
}
