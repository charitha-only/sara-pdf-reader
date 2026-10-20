package app.pageflow.reader

import androidx.core.content.FileProvider
import android.content.ClipData
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
    private var receiverResult: MethodChannel.Result? = null
    private var batchResult: MethodChannel.Result? = null
    private var batchNames: List<String> = emptyList()
    private var batchBytes: List<ByteArray> = emptyList()
    private val fileExecutor = Executors.newSingleThreadExecutor()
    override fun onCreate(savedInstanceState: Bundle?) {
        if (!BuildConfig.DEBUG && !hasExpectedReleaseCertificate()) {
            throw SecurityException("Pageflow release signature verification failed.")
        }
        super.onCreate(savedInstanceState)
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
                    fileExecutor.execute { try { File(cacheDir, "share").deleteRecursively(); File(cacheDir, "odv_workspaces").deleteRecursively(); runOnUiThread { result.success(null) } } catch(e: Exception) { runOnUiThread { result.error("cleanup_failed", e.message, null) } } }
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

