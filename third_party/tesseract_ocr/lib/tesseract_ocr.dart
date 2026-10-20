import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'ocr_engine_config.dart';

class TesseractOcr {
  static const _channel = MethodChannel('tesseract_ocr');
  static Future<String>? _data;
  static Future<void> cancel() async { if(Platform.isAndroid) await _channel.invokeMethod<void>('cancel'); }
  static Future<String> extractText(String imagePath, {OCRConfig? config}) => _recognize('extractText', imagePath, config);
  static Future<String> extractHocr(String imagePath, {OCRConfig? config}) => _recognize('extractHocr', imagePath, config);
  static Future<String> _recognize(String method, String imagePath, OCRConfig? config) async {
    if(!Platform.isAndroid) throw UnsupportedError('Bundled offline Sinhala OCR currently supports Android.');
    if(!await File(imagePath).exists()) throw ArgumentError('The OCR image is missing.');
    final actual = config ?? const OCRConfig(language:'sin', engine:OCREngine.tesseract);
    _data ??= _loadData();
    String directory;
    try { directory = await _data!; } catch (_) { _data = null; rethrow; }
    return await _channel.invokeMethod<String>(method, {'imagePath':imagePath,
      'tessData':directory, 'language':actual.language, 'options':actual.options}) ?? '';
  }
  static Future<String> _loadData() async {
    final directory = await getApplicationDocumentsDirectory();
    final dataDirectory = Directory('${directory.path}/tessdata');
    await dataDirectory.create(recursive:true);
    final config = jsonDecode(await rootBundle.loadString('assets/tessdata_config.json')) as Map;
    for(final name in config['files'] as List) {
      if(name is! String || !RegExp(r'^[a-z_]+\.traineddata$').hasMatch(name)) throw const FormatException('Invalid bundled model name.');
      final asset = await rootBundle.load('assets/tessdata/$name');
      final bytes = asset.buffer.asUint8List(asset.offsetInBytes,asset.lengthInBytes);
      final target = File('${dataDirectory.path}/$name');
      final valid = await target.exists() && await target.length() == bytes.length &&
        sha256.convert(await target.readAsBytes()) == sha256.convert(bytes);
      if(!valid) {
        final temp = File('${target.path}.tmp');
        await temp.writeAsBytes(bytes,flush:true);
        await temp.rename(target.path);
      }
    }
    return directory.path;
  }
}
