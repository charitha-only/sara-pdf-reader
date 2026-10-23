package app.pageflow.reader

import androidx.core.content.FileProvider
import android.content.ClipData
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest
import androidx.documentfile.provider.DocumentFile
import android.app.Activity
import java.util.concurrent.Executors
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    private var incomingBridge: MethodChannel? = null
    private val incomingFiles = ArrayList<Map<String, String>>()
    private var incomingError: String? = null
    private var incomingLaunch = false
    private fun documentIntent(value: Intent?): Boolean =
        value?.action == Intent.ACTION_VIEW || value?.action == Intent.ACTION_SEND || value?.action == Intent.ACTION_SEND_MULTIPLE

    override fun onNewIntent(value: Intent) {
        super.onNewIntent(value)
        setIntent(value)
        receiveDocument(value)
    }

    @Suppress("DEPRECATION")
    private fun receiveDocument(value: Intent?) {
        if (!documentIntent(value)) return
        incomingLaunch = true
        val uris = when (value?.action) {
            Intent.ACTION_VIEW -> listOfNotNull(value.data)
            Intent.ACTION_SEND -> listOfNotNull(value.getParcelableExtra<Uri>(Intent.EXTRA_STREAM))
            else -> value?.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)?.toList() ?: emptyList()
        }.distinct().take(20)
        fileExecutor.execute {
            val copied = ArrayList<Map<String, String>>()
            var failure: String? = null
            for (uri in uris) {
                var target: File? = null
                try {
                    require(uri.scheme == "content" || uri.scheme == "file") { "Unsupported document location." }
                    var displayName = uri.lastPathSegment ?: "Document"
                    if (uri.scheme == "content") contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                        if (cursor.moveToFirst()) displayName = cursor.getString(0) ?: displayName
                    }
                    displayName = displayName.substringAfterLast('/').substringAfterLast('\\')
                        .replace(Regex("[<>:\"/\\\\|?*\\p{Cntrl}]"), "_").take(180).ifBlank { "Document" }
                    if (!displayName.contains('.')) {
                        MimeTypeMap.getSingleton().getExtensionFromMimeType(contentResolver.getType(uri))?.let { displayName += ".$it" }
                    }
                    val directory = File(cacheDir, "incoming").also { it.mkdirs() }
                    val destination = File(directory, "${System.nanoTime()}-$displayName")
                    target = destination
                    contentResolver.openInputStream(uri)?.use { input ->
                        destination.outputStream().use { output ->
                            val buffer = ByteArray(65536)
                            var total = 0L
                            while (true) {
                                val count = input.read(buffer)
                                if (count < 0) break
                                total += count
                                require(total <= 256L * 1024 * 1024) { "Document exceeds the 256 MB import limit." }
                                output.write(buffer, 0, count)
                            }
                        }
                    } ?: error("The sending app did not grant access to this document.")
                    copied.add(mapOf("path" to destination.absolutePath, "name" to displayName))
                } catch (error: Exception) {
                    target?.delete()
                    failure = error.message ?: "Could not receive this document. Save it to Files and try again."
                }
            }
            runOnUiThread {
                incomingFiles.addAll(copied)
                incomingError = failure
                incomingBridge?.invokeMethod("incomingReady", null)
            }
        }
    }

    private var permissionResult: MethodChannel.Result? = null
    private fun permissionState(): Map<String, Any> {
        val photo = if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE"
        return mapOf("camera" to (checkSelfPermission("android.permission.CAMERA") == PackageManager.PERMISSION_GRANTED),
            "photos" to if (checkSelfPermission(photo) == PackageManager.PERMISSION_GRANTED) "all"
                else if (Build.VERSION.SDK_INT >= 34 && checkSelfPermission("android.permission.READ_MEDIA_VISUAL_USER_SELECTED") == PackageManager.PERMISSION_GRANTED) "selected" else "denied")
    }
    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == 2060) {
            val result = permissionResult; permissionResult = null
            result?.success(permissionState())
        }
    }
    private var cameraResult: MethodChannel.Result? = null
    private var cameraFile: File? = null
    private var receiverResult: MethodChannel.Result? = null
    private var batchResult: MethodChannel.Result? = null
    private var batchNames: List<String> = emptyList()
    private var batchBytes: List<ByteArray> = emptyList()
    private val fileExecutor = Executors.newSingleThreadExecutor()
    override fun onCreate(savedInstanceState: Bundle?) {
        if (!BuildConfig.DEBUG && !hasExpectedReleaseCertificate()) {
            throw SecurityException("Pageflow release signature verification failed.")
        }
        incomingLaunch = documentIntent(intent)
        super.onCreate(savedInstanceState)
        receiveDocument(intent)
    }

    @Suppress("DEPRECATION")
    private fun hasExpectedReleaseCertificate(): Boolean {
        if (BuildConfig.RELEASE_CERT_SHA256.isEmpty()) return false
        return try {
            val info = packageManager.getPackageInfo(packageName,
                if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
                else PackageManager.GET_SIGNATURES)
            val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
                else info.signatures
            signatures?.any { signature ->
                val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
                val fingerprint = digest.joinToString("") { ((it.toInt() and 255) + 256).toString(16).substring(1) }
                fingerprint == BuildConfig.RELEASE_CERT_SHA256
            } == true
        } catch (_: Exception) { false }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        incomingBridge = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pageflow_reader/incoming")
        incomingBridge!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "permissionState" -> result.success(permissionState())
                "permissionSetupSeen" -> result.success(getSharedPreferences("reader_setup", MODE_PRIVATE).getBoolean("permissions_v106", false))
                "requestReaderPermissions" -> {
                    if (permissionResult != null) { result.error("permission_busy", "A permission request is already open.", null); return@setMethodCallHandler }
                    val kind = call.argument<String>("kind") ?: "all"
                    val requested = ArrayList<String>()
                    if (kind != "photos" && checkSelfPermission("android.permission.CAMERA") != PackageManager.PERMISSION_GRANTED) requested.add("android.permission.CAMERA")
                    if (kind != "camera") {
                        val photo = if (Build.VERSION.SDK_INT >= 33) "android.permission.READ_MEDIA_IMAGES" else "android.permission.READ_EXTERNAL_STORAGE"
                        if (checkSelfPermission(photo) != PackageManager.PERMISSION_GRANTED) {
                            requested.add(photo)
                            if (Build.VERSION.SDK_INT >= 34) requested.add("android.permission.READ_MEDIA_VISUAL_USER_SELECTED")
                        }
                    }
                    getSharedPreferences("reader_setup", MODE_PRIVATE).edit().putBoolean("permissions_v106", true).apply()
                    if (requested.isEmpty()) result.success(permissionState())
                    else { permissionResult = result; requestPermissions(requested.toTypedArray(), 2060) }
                }

                "capturePhoto" -> {
                    if (checkSelfPermission("android.permission.CAMERA") != PackageManager.PERMISSION_GRANTED) { result.error("camera_permission", "Allow Camera in Settings > Permissions to take photos.", null); return@setMethodCallHandler }
                    if (cameraResult != null) { result.error("camera_busy", "Camera is already open.", null); return@setMethodCallHandler }
                    try {
                        val folder = File(cacheDir, "camera").apply { mkdirs() }
                        val file = File.createTempFile("capture-", ".jpg", folder)
                        cameraFile = file
                        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                        val capture = Intent(android.provider.MediaStore.ACTION_IMAGE_CAPTURE).apply {
                            putExtra(android.provider.MediaStore.EXTRA_OUTPUT, uri)
                            clipData = ClipData.newRawUri("Photo", uri)
                            addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        }
                        cameraResult = result
                        startActivityForResult(capture, 2058)
                    } catch (error: Exception) {
                        cameraFile?.delete(); cameraFile = null; cameraResult = null
                        result.error("camera_unavailable", "Camera could not open. Check that a camera app is installed and camera access is allowed.", null)
                    }
                }
                "removeCameraCopy" -> {
                    val file = call.argument<String>("path")?.let { File(it).canonicalFile }
                    if (file != null && file.parentFile == File(cacheDir, "camera").canonicalFile) file.delete()
                    result.success(null)
                }

                "readerSetupSeen" -> result.success(getSharedPreferences("reader_setup", MODE_PRIVATE).getBoolean("seen", false))
                "readerSetupComplete" -> {
                    getSharedPreferences("reader_setup", MODE_PRIVATE).edit().putBoolean("seen", true).apply()
                    result.success(null)
                }
                "openDefaultSettings" -> {
                    try {
                        startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("settings_unavailable", "Open Android Settings > Apps to manage default readers.", null)
                    }
                }

                "readerDisplay" -> {
                    runOnUiThread {
                        if (call.argument<Boolean>("awake") == true) window.addFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        else window.clearFlags(android.view.WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        result.success(null)
                    }
                }
                "hasIncoming" -> result.success(incomingLaunch)
                "takeIncoming" -> {
                    result.success(mapOf("files" to incomingFiles.toList(), "error" to incomingError))
                    incomingFiles.clear(); incomingError = null
                }
                "removeIncomingCopy" -> {
                    val path = call.argument<String>("path")
                    val file = path?.let { File(it).canonicalFile }
                    val parent = File(cacheDir, "incoming").canonicalFile
                    if (file != null && file.parentFile == parent) file.delete()
                    result.success(null)
                }
                "openReleaseLink" -> {
                    val url = call.argument<String>("url")
                    if (url != "https://github.com/charitha-only/sara-pdf-reader/releases/latest" &&
                        url != "https://github.com/charitha-only/sara-pdf-reader/releases") {
                        result.error("invalid_url", "Unsupported update link.", null)
                    } else try {
                        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
                        result.success(null)
                    } catch (_: Exception) { result.error("no_browser", "Install a browser to open GitHub releases.", null) }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pageflow_reader/office")
            .setMethodCallHandler { call, result ->
                if (call.method != "renderLegacyWord") { result.notImplemented(); return@setMethodCallHandler }
                val bytes = call.argument<ByteArray>("bytes")
                if (bytes == null) { result.error("invalid", "Document bytes are missing.", null); return@setMethodCallHandler }
                fileExecutor.execute {
                    try {
                        val html = LegacyWordRenderer.render(bytes)
                        runOnUiThread { result.success(html) }
                    } catch (error: Exception) {
                        if (BuildConfig.DEBUG) android.util.Log.e("PageflowOffice", "Legacy Word conversion failed", error)
                        runOnUiThread { result.error("word_preview", error.message, null) }
                    } catch (error: LinkageError) {
                        if (BuildConfig.DEBUG) android.util.Log.e("PageflowOffice", "Word engine unavailable", error)
                        runOnUiThread { result.error("word_engine", "The Word preview engine is unavailable.", null) }
                    } catch (error: Error) {
                        // Xerces provider failures are Error subclasses. Contain
                        // these in the document preview rather than killing the app.
                        if (error is ThreadDeath) throw error
                        if (BuildConfig.DEBUG) android.util.Log.e("PageflowOffice", "Word preview failed", error)
                        runOnUiThread { result.error("word_preview", "This document could not be rendered.", null) }
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pageflow_reader/files")
            .setMethodCallHandler { call, result ->
                if (call.method != "savePdfBatch") { result.notImplemented(); return@setMethodCallHandler }
                if (batchResult != null) { result.error("busy", "A folder selection is already open.", null); return@setMethodCallHandler }
                val names = call.argument<List<String>>("names") ?: emptyList()
                val bytes = call.argument<List<ByteArray>>("bytes") ?: emptyList()
                if (names.isEmpty() || names.size != bytes.size || names.size > 2000) { result.error("invalid", "Invalid split files.", null); return@setMethodCallHandler }
                batchNames = names.map { it.replace(Regex("[<>:\"/\\\\|?*]"), "_") }
                batchBytes = bytes
                batchResult = result
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_READ_URI_PERMISSION), 2056)
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "pageflow_reader/share")
            .setMethodCallHandler { call, result ->
                if(call.method == "clearSharedCopies") {
                    fileExecutor.execute { try { File(cacheDir, "share").deleteRecursively(); File(cacheDir, "odv_workspaces").deleteRecursively(); File(cacheDir, "incoming").deleteRecursively(); File(cacheDir, "sara-ocr-reader").deleteRecursively(); runOnUiThread { result.success(null) } } catch(e: Exception) { runOnUiThread { result.error("cleanup_failed", e.message, null) } } }
                    return@setMethodCallHandler
                }
                val verify = BuildConfig.DEBUG && call.method == "verifyReceiver"
                if (call.method != "sharePdf" && call.method != "sharePdfs" && !verify) { result.notImplemented(); return@setMethodCallHandler }
                val paths = call.argument<List<String>>("paths") ?: listOfNotNull(call.argument<String>("path"))
                val names = call.argument<List<String>>("names") ?: listOfNotNull(call.argument<String>("name"))
                val mime = call.argument<String>("mimeType") ?: "application/pdf"
                if(paths.isEmpty()) { result.error("missing_path", "Select files to share.", null); return@setMethodCallHandler }
                fileExecutor.execute {
                    try {
                        val directory = File(cacheDir, "share/${System.nanoTime()}").also { if(!it.mkdirs()) throw IllegalStateException("Could not prepare share folder.") }
                        val files = paths.mapIndexed { index, path ->
                            val source = File(path)
                            if(!source.isFile) throw IllegalArgumentException("A selected file could not be found.")
                            val label = (names.getOrNull(index) ?: source.name).replace(Regex("[<>:\"/\\\\|?*\\p{Cntrl}]"), "_").take(200).ifBlank { source.name }
                            var destination = File(directory, label)
                            if (destination.exists()) destination = File(directory, "$index-$label")
                            source.copyTo(destination, overwrite = false)
                        }
                        val uris = files.map { FileProvider.getUriForFile(this, "$packageName.fileprovider", it) }
                        runOnUiThread {
                            try {
                                val clip = ClipData.newUri(contentResolver, files.first().name, uris.first())
                                uris.drop(1).forEach { clip.addItem(ClipData.Item(it)) }
                                val send = Intent(if(uris.size == 1) Intent.ACTION_SEND else Intent.ACTION_SEND_MULTIPLE).apply {
                                    type = mime
                                    if(uris.size == 1) putExtra(Intent.EXTRA_STREAM, uris.first()) else putParcelableArrayListExtra(Intent.EXTRA_STREAM, ArrayList(uris))
                                    clipData = clip; addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                                }
                                if(verify) {
                                    if(receiverResult != null) throw IllegalStateException("A receiver verification is already active.")
                                    receiverResult = result
                                    send.setPackage("app.pageflow.testreceiver")
                                    startActivityForResult(send, 2057)
                                } else { startActivity(Intent.createChooser(send, "Share files")); result.success(null) }
                            } catch(e: Exception) { receiverResult = null; result.error("share_failed", e.message, null) }
                        }
                    } catch(e: Exception) { runOnUiThread { result.error("share_failed", e.message, null) } }
                }
            }
    }


    @Deprecated("Android compatibility activity-result API")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == 2058) {
            val result = cameraResult; cameraResult = null
            val file = cameraFile; cameraFile = null
            if (file != null) {
                val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
                revokeUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            }
            if (resultCode == Activity.RESULT_OK && file != null && file.exists() && file.length() > 0) result?.success(file.absolutePath)
            else { file?.delete(); result?.success(null) }
            return
        }

        if(requestCode == 2057) {
            val result = receiverResult; receiverResult = null
            if(resultCode == Activity.RESULT_OK) result?.success(data?.getIntExtra("verified", 0)) else result?.error("receiver_failed", data?.getStringExtra("error") ?: "Receiver could not open the files.", null)
            return
        }
        if (requestCode != 2056) { super.onActivityResult(requestCode, resultCode, data); return }
        val result = batchResult ?: return
        batchResult = null
        val names = batchNames; val bytes = batchBytes
        batchNames = emptyList(); batchBytes = emptyList()
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        fileExecutor.execute {
            val saved = ArrayList<String>()
            try {
                val directory = DocumentFile.fromTreeUri(this, uri) ?: throw IllegalArgumentException("Could not open the selected folder.")
                names.indices.forEach { index ->
                    val file = directory.createFile("application/pdf", names[index]) ?: throw IllegalStateException("Could not create ${names[index]}.")
                    contentResolver.openOutputStream(file.uri, "w")?.use { it.write(bytes[index]) } ?: throw IllegalStateException("Could not write ${names[index]}.")
                    saved.add(file.uri.toString())
                }
                runOnUiThread { result.success(saved) }
            } catch (e: Exception) { runOnUiThread { result.error("save_failed", "Saved ${saved.size} of ${names.size} files. ${e.message}", null) } }
        }
    }

    override fun onDestroy() { receiverResult?.error("closed", "Receiver verification closed.", null); receiverResult = null; batchResult?.error("closed", "Folder selection closed.", null); batchResult = null; fileExecutor.shutdown(); super.onDestroy() }
}

