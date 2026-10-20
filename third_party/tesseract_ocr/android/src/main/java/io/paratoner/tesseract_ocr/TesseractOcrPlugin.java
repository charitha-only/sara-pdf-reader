package io.paratoner.tesseract_ocr;

import android.graphics.BitmapFactory;
import android.os.Handler;
import android.os.Looper;
import com.googlecode.tesseract.android.TessBaseAPI;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import java.io.File;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class TesseractOcrPlugin implements FlutterPlugin, MethodChannel.MethodCallHandler {
    private MethodChannel channel;
    private ExecutorService executor;
    private final Object apiGuard = new Object();
    private TessBaseAPI activeApi;
    private final java.util.concurrent.atomic.AtomicLong cancelEpoch = new java.util.concurrent.atomic.AtomicLong();
    private final Handler main = new Handler(Looper.getMainLooper());
    @Override public void onAttachedToEngine(FlutterPluginBinding binding) {
        executor = Executors.newSingleThreadExecutor();
        channel = new MethodChannel(binding.getBinaryMessenger(), "tesseract_ocr");
        channel.setMethodCallHandler(this);
    }
    @Override public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if(channel != null) channel.setMethodCallHandler(null);
        if(executor != null) executor.shutdown();
        channel = null;
    }
    @Override public void onMethodCall(MethodCall call, MethodChannel.Result result) {
        if(call.method.equals("cancel")) {
            cancelEpoch.incrementAndGet();
            synchronized(apiGuard) { if(activeApi != null) activeApi.stop(); }
            result.success(null); return;
        }
        if(!call.method.equals("extractText") && !call.method.equals("extractHocr")) {
            result.notImplemented(); return;
        }
        final String data = call.argument("tessData");
        final String path = call.argument("imagePath");
        final String requested = call.argument("language");
        final String language = requested == null ? "sin" : requested;
        final Map<String, String> options = call.argument("options");
        if(data == null || path == null || !language.matches("[a-z_+]+") || !new File(path).isFile()) {
            result.error("INVALID_ARGUMENT", "Select a valid image and bundled OCR language.", null); return;
        }
        if(executor == null || executor.isShutdown()) {
            result.error("OCR_CLOSED", "The OCR engine is closed.", null); return;
        }
        final long epoch = cancelEpoch.get();
        executor.execute(() -> {
            TessBaseAPI api = null;
            String output = null;
            Exception failure = null;
            try {
                if(epoch != cancelEpoch.get()) throw new IllegalStateException("OCR cancelled.");
                BitmapFactory.Options dimensions = new BitmapFactory.Options();
                dimensions.inJustDecodeBounds = true;
                BitmapFactory.decodeFile(path, dimensions);
                if(dimensions.outWidth < 1 || dimensions.outHeight < 1 ||
                    (long)dimensions.outWidth * dimensions.outHeight > 16000000L) {
                    throw new IllegalArgumentException("The OCR image must be valid and at most 16 megapixels.");
                }
                api = new TessBaseAPI();
                if(!api.init(data, language)) throw new IllegalStateException("Could not load the bundled " + language + " OCR model.");
                synchronized(apiGuard) { activeApi = api; }
                if(epoch != cancelEpoch.get()) throw new IllegalStateException("OCR cancelled.");
                int mode = 3;
                if(options != null && options.containsKey("tessedit_pageseg_mode")) {
                    mode = Integer.parseInt(options.get("tessedit_pageseg_mode"));
                    if(mode != 3 && mode != 4 && mode != 6 && mode != 7 && mode != 11 && mode != 13) {
                        throw new IllegalArgumentException("Unsupported page segmentation mode.");
                    }
                }
                api.setPageSegMode(mode);
                if(options != null && options.containsKey("preserve_interword_spaces")) {
                    api.setVariable("preserve_interword_spaces", options.get("preserve_interword_spaces"));
                }
                api.setImage(new File(path));
                output = call.method.equals("extractHocr") ? api.getHOCRText(0) : api.getUTF8Text();
            } catch(Exception e) { failure = e; }
            finally { synchronized(apiGuard) { activeApi = null; if(api != null) api.recycle(); } }
            final String text = output == null ? "" : output;
            final Exception error = failure;
            main.post(() -> {
                if(error == null) result.success(text);
                else result.error("OCR_FAILED", "Offline OCR failed: " + error.getMessage(), null);
            });
        });
    }
}
