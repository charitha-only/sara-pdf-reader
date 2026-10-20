import 'file_mime.dart';
import 'image_viewer.dart';

import 'package:offline_document_viewer/offline_document_viewer.dart' as odv;

import 'pdf_click_canvas.dart';
import 'text_file_editor.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'password_dialog.dart';
import 'app_language.dart';
import 'office_editable_export.dart';
import 'task_progress.dart';
import 'library_backup.dart';
import 'office_layout_export.dart';
import 'office_viewer.dart';
import 'office_review.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pdf_annotations/flutter_pdf_annotations.dart';
import 'package:image/image.dart' as img;

import 'package:path_provider/path_provider.dart';

import 'pdf_raster_adapter.dart';

import 'package:pdfrx/pdfrx.dart' as pdfrx;

import 'pdfium_object_editor.dart';
import 'pdf_form_page.dart';
import 'pdf_page_manager.dart';
import 'pdf_redaction_page.dart';
import 'text_box.dart';
import 'text_box_dialog.dart';
import 'scanned_text_editor.dart';
import 'sinhala_ocr.dart';

const ink = Color(0xFF092F35);
const teal = Color(0xFF07363B);
const aqua = Color(0xFFB8ECEE);
const canvas = Color(0xFFF3F7F7);
// Reader launch: keep future editing work dormant.
const _editingEnabled = bool.fromEnvironment(
  'PAGEFLOW_EDITING',
  defaultValue: false,
);
const _shareChannel = MethodChannel('pageflow_reader/share');

String _kindForPath(String path) {
  final extension = path.split('.').last.toLowerCase();
  if (['txt', 'plain'].contains(extension)) return 'TXT';
  if (['png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp'].contains(extension)) {
    return 'Image';
  }
  odv.DocumentFormat? format;
  for (final candidate in odv.DocumentFormat.values) {
    if (candidate.extensions.contains(extension)) {
      format = candidate;
      break;
    }
  }
  return switch (format?.family) {
    odv.FormatFamily.word => 'Word',
    odv.FormatFamily.excel => 'Excel',
    odv.FormatFamily.powerPoint => 'PPT',
    _ => 'PDF',
  };
}

String _mimeForPath(String path) => fileMime(path);

String _recentLabel(int timestamp) {
  final elapsed = DateTime.now().difference(
    DateTime.fromMillisecondsSinceEpoch(timestamp),
  );
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
  if (elapsed.inDays < 1) return '${elapsed.inHours}h ago';
  if (elapsed.inDays == 1) return 'yesterday';
  return '${elapsed.inDays}d ago';
}

class _PdfImagePage {
  const _PdfImagePage({
    required this.jpegBytes,
    required this.imageWidth,
    required this.imageHeight,
    required this.pageWidth,
    required this.pageHeight,
  });

  final Uint8List jpegBytes;
  final int imageWidth;
  final int imageHeight;
  final double pageWidth;
  final double pageHeight;
  int get rotation => 0;
}

class _SelectedPdfPage {
  const _SelectedPdfPage(this.number, this.rotation);
  final int number;
  final int rotation;
}

Uint8List _imagePagesPdf(List<_PdfImagePage> pages) {
  if (pages.isEmpty) throw ArgumentError('At least one PDF page is required.');
  final output = BytesBuilder(copy: false);
  final objectCount = 2 + pages.length * 3;
  final offsets = List<int>.filled(objectCount + 1, 0);
  void addText(String value) => output.add(utf8.encode(value));
  void addObject(int number, String body) {
    offsets[number] = output.length;
    addText('$number 0 obj\n$body\nendobj\n');
  }

  addText('%PDF-1.4\n%\u00e2\u00e3\u00cf\u00d3\n');
  addObject(1, '<< /Type /Catalog /Pages 2 0 R >>');
  final pageObjectNumbers = [
    for (var index = 0; index < pages.length; index++) 3 + index * 3,
  ];
  final kids = pageObjectNumbers.map((number) => '$number 0 R').join(' ');
  addObject(2, '<< /Type /Pages /Kids [$kids] /Count ${pages.length} >>');

  for (var index = 0; index < pages.length; index++) {
    final imagePage = pages[index];
    final pageObject = 3 + index * 3;
    final contentObject = pageObject + 1;
    final imageObject = pageObject + 2;
    final pageWidth = imagePage.pageWidth.toStringAsFixed(3);
    final pageHeight = imagePage.pageHeight.toStringAsFixed(3);
    addObject(
      pageObject,
      '<< /Type /Page /Parent 2 0 R '
      '/MediaBox [0 0 $pageWidth $pageHeight] /Rotate ${imagePage.rotation} '
      '/Resources << /XObject << /Im$index $imageObject 0 R >> >> '
      '/Contents $contentObject 0 R >>',
    );

    final content = utf8.encode(
      'q $pageWidth 0 0 $pageHeight 0 0 cm /Im$index Do Q',
    );
    offsets[contentObject] = output.length;
    addText('$contentObject 0 obj\n<< /Length ${content.length} >>\nstream\n');
    output.add(content);
    addText('\nendstream\nendobj\n');

    offsets[imageObject] = output.length;
    addText(
      '$imageObject 0 obj\n<< /Type /XObject /Subtype /Image '
      '/Width ${imagePage.imageWidth} /Height ${imagePage.imageHeight} '
      '/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode '
      '/Length ${imagePage.jpegBytes.length} >>\nstream\n',
    );
    output.add(imagePage.jpegBytes);
    addText('\nendstream\nendobj\n');
  }

  final xrefOffset = output.length;
  addText('xref\n0 ${objectCount + 1}\n0000000000 65535 f \n');
  for (var index = 1; index < offsets.length; index++) {
    addText('${offsets[index].toString().padLeft(10, '0')} 00000 n \n');
  }
  addText(
    'trailer\n<< /Size ${objectCount + 1} /Root 1 0 R >>\n'
    'startxref\n$xrefOffset\n%%EOF\n',
  );
  return output.takeBytes();
}

List<_SelectedPdfPage>? _parsePageSelection(String input, int pageCount) {
  final pages = <_SelectedPdfPage>[];
  final seenPages = <int>{};
  for (final rawPart in input.split(',')) {
    final part = rawPart.trim();
    final match = RegExp(r'^(\d+)(?:\s*-\s*(\d+))?\s*([rRlL])?$')
        .firstMatch(part);
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2) ?? match.group(1)!);
    final direction = match.group(3)?.toLowerCase();
    final rotation = direction == 'r'
        ? 90
        : direction == 'l'
        ? 270
        : 0;
    if (start == null ||
        end == null ||
        start < 1 ||
        end < start ||
        end > pageCount) {
      return null;
    }
    for (var page = start; page <= end; page++) {
      if (!seenPages.add(page)) return null;
      pages.add(_SelectedPdfPage(page, rotation));
      if (pages.length > 200) return null;
    }
  }
  return pages.isEmpty ? null : pages;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString(
      'assets/licenses/THIRD_PARTY_NOTICES.txt',
    );
    yield LicenseEntryWithLineBreaks([
      'Pageflow bundled native libraries, fonts and OCR model',
    ], text);
  });
  runApp(const PageflowApp());
}

class PageflowApp extends StatefulWidget {
  const PageflowApp({super.key});

  @override
  State<PageflowApp> createState() => _PageflowAppState();
}

class _PageflowAppState extends State<PageflowApp> {
  bool _darkMode = false;

  @override
  void initState() {
    super.initState();
    _loadThemePreference();
    AppLanguage.instance.load();
    AppLanguage.instance.addListener(_localeChanged);
  }

  void _localeChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    AppLanguage.instance.removeListener(_localeChanged);
    super.dispose();
  }

  Future<File> _settingsFile() async {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    return File('${directory.path}${Platform.pathSeparator}settings.json');
  }

  Future<void> _loadThemePreference() async {
    try {
      final file = await _settingsFile();
      if (!await file.exists()) return;
      final settings = jsonDecode(await file.readAsString());
      if (settings is Map<String, dynamic> && settings['darkMode'] is bool) {
        if (mounted) setState(() => _darkMode = settings['darkMode'] as bool);
      }
    } catch (_) {
      // If preferences are unavailable, keep the default light theme.
    }
  }

  Future<void> _setDarkMode(bool enabled) async {
    setState(() => _darkMode = enabled);
    try {
      await AppPreferences.write({'darkMode': enabled});
    } catch (_) {
      // Apply the choice for this session even if it cannot be persisted.
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pageflow PDF Reader',
    locale: Locale(AppLanguage.instance.value),
    supportedLocales: const [Locale('en'), Locale('si')],
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      scaffoldBackgroundColor: canvas,
      colorScheme: ColorScheme.fromSeed(seedColor: teal, primary: teal),
      fontFamily: 'Pageflow UI',
    ),
    darkTheme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF10191A),
      colorScheme: ColorScheme.fromSeed(
        seedColor: aqua,
        brightness: Brightness.dark,
        primary: const Color(0xFF9ADDE0),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF173638),
        foregroundColor: Colors.white,
      ),
      fontFamily: 'Pageflow UI',
    ),
    themeMode: _darkMode ? ThemeMode.dark : ThemeMode.light,
    home: WelcomePage(onDarkModeChanged: _setDarkMode),
  );
}

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key, required this.onDarkModeChanged});
  final ValueChanged<bool> onDarkModeChanged;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFFA9E8EB), Color(0xFFE8F6F5), Colors.white],
          stops: [0, .48, 1],
        ),
      ),
      child: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 24, 26, 22),
                child: Column(
                  children: [
                    const SizedBox.shrink(),
                    const SizedBox(height: 34),
                    Container(
                      width: 54,
                      height: 54,
                      decoration: BoxDecoration(
                        color: teal,
                        borderRadius: BorderRadius.circular(18),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x2206383D),
                            blurRadius: 20,
                            offset: Offset(0, 8),
                          ),
                        ],
                      ),
                      child: const Center(
                        child: Icon(
                          Icons.description_outlined,
                          color: Colors.white,
                          size: 32,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    const LocalizedText(
                      'YOUR DOCUMENTS, IN ONE PLACE',
                      style: TextStyle(
                        color: Color(0xFF578086),
                        fontSize: 10,
                        letterSpacing: 1.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 10),
                    const LocalizedText(
                      'PDF & Document\nReader',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: ink,
                        fontSize: 30,
                        height: 1.18,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 11),
                    const LocalizedText(
                      'Read PDFs, Office documents and images\nprivately on your device.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Color(0xFF698287),
                        height: 1.5,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 22),
                    const SizedBox(height: 240, child: _WelcomeIllustration()),
                    SizedBox(
                      width: double.infinity,
                      height: 80,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: teal,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(18),
                          ),
                        ),
                        onPressed: () => Navigator.of(context).pushReplacement(
                          MaterialPageRoute(
                            builder: (_) =>
                                HomePage(onDarkModeChanged: onDarkModeChanged),
                          ),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Flexible(
                              child: LocalizedText(
                                'Get Started',
                                textAlign: TextAlign.center,
                                style: TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            SizedBox(width: 11),
                            Icon(Icons.arrow_forward, size: 19),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _WelcomeIllustration extends StatelessWidget {
  const _WelcomeIllustration();

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final h = box.maxHeight.clamp(190.0, 340.0).toDouble();
      return Center(
        child: SizedBox(
          width: 300,
          height: h,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Positioned(
                bottom: 10,
                child: Container(
                  width: 164,
                  height: h * .78,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(28),
                    gradient: const LinearGradient(
                      colors: [Color(0xFFDFF8F6), Color(0xFF8AC5C3)],
                    ),
                    border: Border.all(color: Colors.white, width: 5),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x2214575A),
                        blurRadius: 28,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: const Center(
                    child: Icon(
                      Icons.description_outlined,
                      size: 86,
                      color: Color(0xFF559493),
                    ),
                  ),
                ),
              ),
              const _FormatTile(
                label: 'W',
                color: Color(0xFF2375CC),
                left: 18,
                top: 78,
                angle: -.12,
              ),
              const _FormatTile(
                label: 'PDF',
                color: Color(0xFFE74E52),
                right: 15,
                top: 58,
                angle: .1,
              ),
              const _FormatTile(
                label: 'X',
                color: Color(0xFF16875F),
                left: 32,
                bottom: 44,
                angle: -.14,
              ),
              const _FormatTile(
                label: 'P',
                color: Color(0xFFE47B31),
                right: 26,
                bottom: 46,
                angle: .11,
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _FormatTile extends StatelessWidget {
  const _FormatTile({
    required this.label,
    required this.color,
    this.left,
    this.right,
    this.top,
    this.bottom,
    required this.angle,
  });
  final String label;
  final Color color;
  final double? left, right, top, bottom, angle;

  @override
  Widget build(BuildContext context) => Positioned(
    left: left,
    right: right,
    top: top,
    bottom: bottom,
    child: Transform.rotate(
      angle: angle!,
      child: Container(
        width: 48,
        height: 54,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(13),
          boxShadow: const [
            BoxShadow(
              color: Color(0x1C173C40),
              blurRadius: 15,
              offset: Offset(0, 6),
            ),
          ],
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: label == 'PDF' ? 12 : 18,
            ),
          ),
        ),
      ),
    ),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.onDarkModeChanged});
  final ValueChanged<bool> onDarkModeChanged;
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final List<_Document> _documents = [];
  final TextEditingController _searchController = TextEditingController();
  String _filter = 'All';
  String _query = '';
  String _sortOrder = 'newest';
  final Set<String> _selectedPaths = {};
  bool _loadingDocuments = true;
  Future<void> _indexWrite = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _loadDocuments();
  }

  Future<Directory> _pdfDirectory() async {
    final appDirectory = await getApplicationDocumentsDirectory();
    final directory = Directory(
      '${appDirectory.path}${Platform.pathSeparator}pdfs',
    );
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _loadDocuments() async {
    Directory? directory;
    try {
      directory = await _pdfDirectory();
      final preferences = File(
        '${directory.path}${Platform.pathSeparator}library-preferences.json',
      );
      if (await preferences.exists()) {
        final saved = jsonDecode(await preferences.readAsString());
        if (saved is Map<String, dynamic> && saved['sortOrder'] is String) {
          const supportedSorts = {
            'newest',
            'oldest',
            'recentlyOpened',
            'nameAsc',
            'nameDesc',
            'sizeDesc',
            'sizeAsc',
          };
          final sortOrder = saved['sortOrder'] as String;
          if (supportedSorts.contains(sortOrder)) _sortOrder = sortOrder;
        }
      }
      final index = File(
        '${directory.path}${Platform.pathSeparator}documents.json',
      );
      if (await index.exists()) {
        final decoded = jsonDecode(await index.readAsString()) as List<dynamic>;
        final documents = decoded
            .map((entry) => _Document.fromJson(entry as Map<String, dynamic>))
            .where(
              (document) =>
                  document.path != null && File(document.path!).existsSync(),
            )
            .toList();
        _documents
          ..clear()
          ..addAll(documents);
      } else {
        await _recoverLibraryIndex(directory);
      }
    } catch (_) {
      // Recover app-owned PDF copies if the local JSON index is damaged.
      if (directory != null) await _recoverLibraryIndex(directory);
    }
    if (mounted) setState(() => _loadingDocuments = false);
  }

  Future<void> _recoverLibraryIndex(Directory directory) async {
    final recovered = <_Document>[];
    try {
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File ||
            !RegExp(
              r'\.(pdf|docx|xlsx|pptx|txt|plain|doc|xls|ppt|rtf|csv|tsv|docm|xlsm|pptm|png|jpg|jpeg|webp|gif|bmp)$',
              caseSensitive: false,
            ).hasMatch(entity.path)) {
          continue;
        }
        try {
          final metadata = await entity.stat();
          final storedName = entity.path.split(Platform.pathSeparator).last;
          final displayName = storedName.replaceFirstMapped(
            RegExp(r'^\d+(?:-\d+)?-(.+)$', caseSensitive: false),
            (match) => match.group(1)!,
          );
          final bytes = metadata.size;
          final sizeLabel = bytes >= 1024 * 1024
              ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
              : '${(bytes / 1024).round()} KB';
          final modified = metadata.modified;
          recovered.add(
            _Document(
              displayName,
              _kindForPath(entity.path),
              sizeLabel,
              '${modified.day.toString().padLeft(2, '0')}/${modified.month.toString().padLeft(2, '0')}/${modified.year}',
              path: entity.path,
            ),
          );
        } catch (_) {
          // Keep recovering the remaining files if one file has bad metadata.
        }
      }
      if (!mounted || recovered.isEmpty) return;
      recovered.sort(
        (first, second) =>
            _documentDate(second).compareTo(_documentDate(first)),
      );
      setState(() {
        _documents
          ..clear()
          ..addAll(recovered);
      });
      await _saveDocuments();
    } catch (_) {
      // Leave the app usable even if recovery or index rewriting fails.
    }
  }

  Future<void> _setSortOrder(String value) async {
    setState(() => _sortOrder = value);
    try {
      final directory = await _pdfDirectory();
      final preferences = File(
        '${directory.path}${Platform.pathSeparator}library-preferences.json',
      );
      await preferences.writeAsString(
        jsonEncode({'sortOrder': value}),
        flush: true,
      );
    } catch (_) {
      if (mounted) _message('Sort changed for this session.');
    }
  }

  Future<void> _saveDocuments() {
    final snapshot = jsonEncode(
      _documents.map((document) => document.toJson()).toList(),
    );
    final write = _indexWrite.then((_) async {
      final directory = await _pdfDirectory();
      final index = File(
        '${directory.path}${Platform.pathSeparator}documents.json',
      );
      final temporary = File('${index.path}.tmp');
      await temporary.writeAsString(snapshot, flush: true);
      await temporary.rename(index.path);
    });
    // Reading progress and bookmarks can update quickly. Serialize snapshots
    // so an older write never overwrites newer library state.
    _indexWrite = write.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return write;
  }

  Future<void> _createTextDocument() async {
    final directory = await _pdfDirectory();
    if (!mounted) return;
    final result = await Navigator.of(context)
        .push<({String path, String name})>(
          MaterialPageRoute(
            builder: (_) => TextFileEditor(directory: directory),
          ),
        );
    if (!mounted || result == null) return;
    final file = File(result.path), now = DateTime.now();
    final size = await file.length();
    if (!mounted) return;
    setState(
      () => _documents.insert(
        0,
        _Document(
          result.name,
          'TXT',
          '${(size / 1024).toStringAsFixed(1)} KB',
          '${now.day}/${now.month}/${now.year}',
          path: result.path,
        ),
      ),
    );
    await _saveDocuments();
  }

  Future<void> _importPdf() async {
    List<PlatformFile> result;
    try {
      result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'pdf',
          'docx',
          'xlsx',
          'pptx',
          'txt',
          'plain',
          'doc',
          'xls',
          'ppt',
          'rtf',
          'csv',
          'tsv',
          'docm',
          'xlsm',
          'pptm',
          'png',
          'jpg',
          'jpeg',
          'webp',
          'gif',
          'bmp',
        ],
      );
    } catch (error) {
      if (mounted) _message('Could not open the file picker: $error');
      return;
    }
    if (!mounted || result.isEmpty) return;
    try {
      final directory = await _pdfDirectory();
      final imported = <_Document>[];
      var failed = 0;
      for (var index = 0; index < result.length; index++) {
        final pickedFile = result[index];
        final sourcePath = pickedFile.path;
        if (sourcePath == null) {
          failed++;
          continue;
        }
        File? copiedFile;
        pdfrx.PdfDocument? validationDocument;
        try {
          final fileSize = await pickedFile.length();
          if (fileSize != null && fileSize > 256 * 1024 * 1024) {
            throw const FormatException('Import files up to 256 MB.');
          }
          final size = fileSize == null
              ? 'Size unknown'
              : fileSize >= 1024 * 1024
              ? '${(fileSize / 1024 / 1024).toStringAsFixed(1)} MB'
              : '${(fileSize / 1024).round()} KB';
          final safeName = pickedFile.name.replaceAll(
            RegExp(r'[<>:"/\\|?*]'),
            '_',
          );
          copiedFile = await File(sourcePath).copy(
            '${directory.path}${Platform.pathSeparator}'
            '${DateTime.now().microsecondsSinceEpoch}-$index-$safeName',
          );
          final extension = pickedFile.name.split('.').last.toLowerCase();
          var kind = 'PDF';
          if (extension == 'pdf') {
            await pdfrx.pdfrxFlutterInitialize();
            try {
              validationDocument = await pdfrx.PdfDocument.openFile(
                copiedFile.path,
              );
            } on pdfrx.PdfPasswordException {
              Uint8List? unlocked;
              for (
                var attempt = 0;
                attempt < 3 && unlocked == null;
                attempt++
              ) {
                if (!mounted) throw const TaskCancelled();
                final password = await showDialog<String>(
                  context: context,
                  builder: (_) => const DocumentPasswordDialog(),
                );
                if (password == null) throw const TaskCancelled();
                try {
                  unlocked = await PdfiumObjectEditor.unlock(
                    await copiedFile.readAsBytes(),
                    password,
                  );
                } catch (_) {
                  if (mounted) {
                    _message(
                      'Incorrect password or unreadable PDF. Try again.',
                    );
                  }
                }
              }
              if (unlocked == null) {
                throw const FormatException('Could not unlock this PDF.');
              }
              await copiedFile.writeAsBytes(unlocked, flush: true);
              validationDocument = await pdfrx.PdfDocument.openFile(
                copiedFile.path,
              );
            }
            if (validationDocument.pages.isEmpty) {
              throw const FormatException('This PDF has no readable pages.');
            }
            await validationDocument.dispose();
            validationDocument = null;
          } else if ([
            'png',
            'jpg',
            'jpeg',
            'webp',
            'gif',
            'bmp',
          ].contains(extension)) {
            if (await copiedFile.length() > 32 * 1024 * 1024) {
              throw const FormatException('Images up to 32 MB are supported.');
            }
            final codec = await ui.instantiateImageCodec(
              await copiedFile.readAsBytes(),
              targetWidth: 2560,
              targetHeight: 2560,
              allowUpscaling: false,
            );
            try {
              final frame = await codec.getNextFrame();
              frame.image.dispose();
            } finally {
              codec.dispose();
            }
            kind = 'Image';
          } else if (extension == 'txt' || extension == 'plain') {
            if (await copiedFile.length() > 8 * 1024 * 1024) {
              throw const FormatException(
                'Text files up to 8 MB are supported.',
              );
            }
            await copiedFile.readAsString();
            kind = 'TXT';
          } else {
            final report = odv.DocumentPreflight.inspect(
              bytes: await copiedFile.readAsBytes(),
              fileName: pickedFile.name,
            );
            if (report is odv.DocumentFailure) {
              throw FormatException(
                'This document could not be opened: ${report.runtimeType}',
              );
            }
            final format = (report as odv.PreflightReport).format;
            kind = switch (format.family) {
              odv.FormatFamily.word => 'Word',
              odv.FormatFamily.excel => 'Excel',
              odv.FormatFamily.powerPoint => 'PPT',
              _ => 'PDF',
            };
          }
          final now = DateTime.now();
          imported.add(
            _Document(
              pickedFile.name,
              kind,
              size,
              '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
              path: copiedFile.path,
            ),
          );
        } catch (_) {
          try {
            await validationDocument?.dispose();
          } catch (_) {}
          try {
            if (copiedFile != null && await copiedFile.exists()) {
              await copiedFile.delete();
            }
          } catch (_) {}
          failed++;
        }
      }
      if (!mounted) return;
      if (imported.isEmpty) {
        _message(
          'No document could be imported. Check the file format and access, then try again.',
        );
        return;
      }
      setState(() => _documents.insertAll(0, imported));
      await _saveDocuments();
      if (!mounted) return;
      if (imported.length == 1 && result.length == 1) {
        await _openPdf(imported.single);
      } else {
        _message(
          failed == 0
              ? '${imported.length} documents added to your library.'
              : '${imported.length} documents added; $failed could not be imported.',
        );
      }
    } catch (error) {
      if (mounted) _message('Could not save this PDF: $error');
    }
  }

  Future<void> _removeDocument(_Document document) async {
    final shouldDelete = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText('Remove PDF?'),
        content: LocalizedText('Remove "${document.name}" from this app?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LocalizedText('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LocalizedText('Remove'),
          ),
        ],
      ),
    );
    if (shouldDelete != true) return;
    try {
      if (document.path != null) {
        final file = File(document.path!);
        if (await file.exists()) await file.delete();
      }
    } catch (error) {
      if (mounted) _message('Could not remove this PDF: $error');
      return;
    }
    if (!mounted) return;
    setState(() {
      _documents.remove(document);
      if (document.path != null) _selectedPaths.remove(document.path);
    });
    await _saveDocuments();
  }

  Future<void> _duplicateDocument(_Document document) async {
    final sourcePath = document.path;
    if (sourcePath == null) return;
    try {
      final source = File(sourcePath);
      if (!await source.exists()) {
        if (mounted) _message('The original PDF could not be found.');
        return;
      }
      final extension = sourcePath.split('.').last;
      final baseName = document.name.replaceFirst(RegExp(r'\.[^.]+$'), '');
      final copyName = '$baseName copy.$extension';
      final copyPath =
          '${source.parent.path}${Platform.pathSeparator}'
          '${DateTime.now().microsecondsSinceEpoch}-$copyName';
      final copied = await source.copy(copyPath);
      final now = DateTime.now();
      final copy = _Document(
        copyName,
        document.kind,
        document.size,
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
        path: copied.path,
      );
      if (!mounted) return;
      setState(() => _documents.insert(0, copy));
      await _saveDocuments();
      if (mounted) _message('PDF copy added to your library.');
    } catch (error) {
      if (mounted) _message('Could not duplicate this PDF: $error');
    }
  }

  Future<void> _shareDocuments(List<_Document> documents) async {
    if (!Platform.isAndroid) {
      _message('PDF sharing is currently available on Android only.');
      return;
    }
    final readyFiles = <_Document>[];
    for (final document in documents) {
      final path = document.path;
      if (path == null || !await File(path).exists()) {
        _message('A selected PDF could not be found.');
        return;
      }
      readyFiles.add(document);
    }
    if (readyFiles.isEmpty) {
      _message('Select at least one PDF to share.');
      return;
    }
    try {
      await _shareChannel.invokeMethod<void>(
        readyFiles.length == 1 ? 'sharePdf' : 'sharePdfs',
        {
          'path': readyFiles.first.path,
          'name': readyFiles.first.name,
          'paths': readyFiles.map((document) => document.path).toList(),
          'names': readyFiles.map((document) => document.name).toList(),
          'mimeType': readyFiles.length == 1
              ? _mimeForPath(readyFiles.first.path!)
              : '*/*',
        },
      );
    } on PlatformException catch (error) {
      if (mounted) _message(error.message ?? 'Could not share these PDFs.');
    } on MissingPluginException {
      if (mounted) _message('Restart the app to enable PDF sharing.');
    } catch (error) {
      if (mounted) _message('Could not share these PDFs: $error');
    }
  }

  Future<void> _shareDocument(_Document document) =>
      _shareDocuments([document]);

  Future<void> _shareSelectedDocuments() async {
    final selected = _documents
        .where(
          (document) =>
              document.path != null && _selectedPaths.contains(document.path),
        )
        .toList();
    await _shareDocuments(selected);
  }

  Future<void> _showDocumentActions(_Document document) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.share_outlined),
              title: const LocalizedText('Share PDF'),
              onTap: () => Navigator.pop(sheetContext, 'share'),
            ),
            ListTile(
              leading: Icon(
                document.isFavorite ? Icons.star : Icons.star_border,
                color: const Color(0xFFE5A900),
              ),
              title: Text(
                document.isFavorite
                    ? 'Remove from favorites'
                    : 'Add to favorites',
              ),
              onTap: () => Navigator.pop(sheetContext, 'favorite'),
            ),
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const LocalizedText('Rename PDF'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const LocalizedText('Make a copy'),
              onTap: () => Navigator.pop(sheetContext, 'duplicate'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const LocalizedText('Remove from app'),
              onTap: () => Navigator.pop(sheetContext, 'remove'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'share':
        await _shareDocument(document);
      case 'favorite':
        final index = _documents.indexWhere(
          (item) => item.path == document.path,
        );
        if (index < 0) return;
        setState(
          () => _documents[index] = document.copyWith(
            isFavorite: !document.isFavorite,
          ),
        );
        await _saveDocuments();
        if (mounted) {
          _message(
            document.isFavorite
                ? 'Removed from favorites.'
                : 'Added to favorites.',
          );
        }
      case 'rename':
        await _renameDocument(document);
      case 'duplicate':
        await _duplicateDocument(document);
      case 'remove':
        await _removeDocument(document);
    }
  }

  Future<void> _renameDocument(_Document document) async {
    final controller = TextEditingController(
      text: document.name.replaceAll(RegExp(r'\.[^.]+$'), ''),
    );
    final requestedName = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Rename PDF'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(labelText: tr('File name')),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const LocalizedText('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || requestedName == null) return;
    final cleanName = requestedName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .replaceAll(RegExp(r'\.[^.]+$'), '')
        .trim();
    if (cleanName.isEmpty) {
      _message('Enter a name for this PDF.');
      return;
    }
    final sourcePath = document.path;
    if (sourcePath == null) return;
    final source = File(sourcePath);
    final extension = sourcePath.split('.').last;
    final destinationPath =
        '${source.parent.path}${Platform.pathSeparator}$cleanName.$extension';
    if (destinationPath.toLowerCase() != sourcePath.toLowerCase() &&
        await File(destinationPath).exists()) {
      if (mounted) _message('A PDF with that name already exists.');
      return;
    }
    try {
      final renamed = await source.rename(destinationPath);
      final index = _documents.indexWhere((item) => item.path == sourcePath);
      if (index < 0 || !mounted) return;
      setState(
        () => _documents[index] = document.copyWith(
          name: '$cleanName.$extension',
          path: renamed.path,
        ),
      );
      await _saveDocuments();
      if (mounted) _message('PDF renamed.');
    } catch (error) {
      if (mounted) _message('Could not rename this PDF: $error');
    }
  }

  Future<void> _openPdf(_Document doc) async {
    if (doc.path == null) {
      _message('Import a PDF from your device to open it.');
      return;
    }
    if (!await File(doc.path!).exists()) {
      _message('This PDF is missing from the app storage.');
      return;
    }
    if (doc.kind == 'Image') {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ImageFileViewer(path: doc.path!, name: doc.name),
        ),
      );
      return;
    }
    if (doc.kind == 'TXT') {
      if (!mounted) return;
      final result = await Navigator.of(context)
          .push<({String path, String name})>(
            MaterialPageRoute(
              builder: (_) => TextFileEditor(
                directory: File(doc.path!).parent,
                path: doc.path,
                displayName: doc.name,
                readOnly: !_editingEnabled,
              ),
            ),
          );
      if (result != null && mounted) {
        final index = _documents.indexWhere((d) => d.path == doc.path);
        final size = await File(result.path).length();
        if (index >= 0 && mounted) {
          setState(
            () => _documents[index] = _Document(
              doc.name,
              'TXT',
              '${(size / 1024).toStringAsFixed(1)} KB',
              doc.date,
              path: result.path,
            ),
          );
          await _saveDocuments();
        }
      }
      return;
    }
    if (doc.kind != 'PDF') {
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => OfficeViewer(path: doc.path!, name: doc.name),
        ),
      );
      return;
    }
    if (!mounted) return;
    try {
      final editedDocument = await Navigator.of(context).push<_Document>(
        MaterialPageRoute(
          builder: (_) => _PdfReaderPage(
            document: doc,
            onProgressChanged: _updateReadingProgress,
          ),
        ),
      );
      if (editedDocument == null || !mounted) return;
      setState(() {
        final existing = _documents.indexWhere(
          (d) => d.path == editedDocument.path,
        );
        if (existing >= 0) {
          _documents[existing] = editedDocument;
        } else {
          _documents.insert(0, editedDocument);
        }
      });
      await _saveDocuments();
      if (mounted) _message('New PDF saved to your documents.');
    } catch (error) {
      if (mounted) _message('Could not open this PDF: $error');
    }
  }

  void _updateReadingProgress(_Document updatedDocument) {
    final documentIndex = _documents.indexWhere(
      (document) => document.path == updatedDocument.path,
    );
    if (documentIndex < 0) return;
    setState(() => _documents[documentIndex] = updatedDocument);
    unawaited(
      _saveDocuments().catchError((Object error) {
        if (mounted) _message('Could not save reading progress: $error');
      }),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(text), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  DateTime _documentDate(_Document document) {
    final parts = document.date.split('/');
    if (parts.length != 3) return DateTime(1970);
    final day = int.tryParse(parts[0]);
    final month = int.tryParse(parts[1]);
    final year = int.tryParse(parts[2]);
    if (day == null || month == null || year == null) return DateTime(1970);
    return DateTime(year, month, day);
  }

  int _documentSize(_Document document) {
    final match = RegExp(
      r'([\d.]+)\s*(KB|MB)',
      caseSensitive: false,
    ).firstMatch(document.size);
    if (match == null) return -1;
    final value = double.tryParse(match.group(1)!);
    if (value == null) return -1;
    final unit = match.group(2)!.toUpperCase();
    return (value * (unit == 'MB' ? 1024 * 1024 : 1024)).round();
  }

  void _toggleDocumentSelection(_Document document) {
    final path = document.path;
    if (path == null) return;
    setState(() {
      if (!_selectedPaths.add(path)) _selectedPaths.remove(path);
    });
  }

  void _toggleVisibleSelection(List<_Document> visibleDocuments) {
    final visiblePaths = visibleDocuments
        .map((document) => document.path)
        .whereType<String>()
        .toSet();
    final allSelected =
        visiblePaths.isNotEmpty && visiblePaths.every(_selectedPaths.contains);
    setState(() {
      if (allSelected) {
        _selectedPaths.removeAll(visiblePaths);
      } else {
        _selectedPaths.addAll(visiblePaths);
      }
    });
  }

  Future<void> _toggleSelectedFavorites() async {
    final selected = _documents
        .where(
          (document) =>
              document.path != null && _selectedPaths.contains(document.path),
        )
        .toList();
    if (selected.isEmpty) return;
    final makeFavorite = selected.any((document) => !document.isFavorite);
    setState(() {
      for (var index = 0; index < _documents.length; index++) {
        final document = _documents[index];
        if (document.path != null && _selectedPaths.contains(document.path)) {
          _documents[index] = document.copyWith(isFavorite: makeFavorite);
        }
      }
      _selectedPaths.clear();
    });
    await _saveDocuments();
    if (mounted) {
      _message(
        makeFavorite
            ? 'Selected documents added to favorites.'
            : 'Selected PDFs removed from favorites.',
      );
    }
  }

  Future<void> _removeSelectedDocuments() async {
    final selected = _documents
        .where(
          (document) =>
              document.path != null && _selectedPaths.contains(document.path),
        )
        .toList();
    if (selected.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: LocalizedText('Remove ${selected.length} PDFs?'),
        content: const LocalizedText(
          'This removes the selected copies from this app and its library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const LocalizedText('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final removedPaths = <String>{};
    var failed = 0;
    for (final document in selected) {
      final path = document.path!;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        removedPaths.add(path);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _documents.removeWhere(
        (document) =>
            document.path != null && removedPaths.contains(document.path),
      );
      _selectedPaths.clear();
    });
    await _saveDocuments();
    if (mounted) {
      _message(
        failed == 0
            ? '${removedPaths.length} PDFs removed.'
            : '${removedPaths.length} PDFs removed; $failed could not be removed.',
      );
    }
  }

  Future<void> _clearLibraryFromSettings() async {
    final removedPaths = <String>{};
    var failed = 0;
    for (final document in List<_Document>.of(_documents)) {
      final path = document.path;
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
        removedPaths.add(path);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _documents.removeWhere(
        (document) =>
            document.path != null && removedPaths.contains(document.path),
      );
      _selectedPaths.clear();
    });
    await _saveDocuments();
    if (Platform.isAndroid) {
      try {
        await _shareChannel.invokeMethod<void>('clearSharedCopies');
      } catch (error) {
        failed++;
      }
    }
    if (mounted) {
      _message(
        failed == 0
            ? 'App copies cleared.'
            : 'Some PDFs could not be removed ($failed).',
      );
    }
  }

  Future<void> _backupLibrary() async {
    try {
      final bytes = await runPdfTask(
        context,
        'Backing up library',
        (progress) => LibraryBackup.create(
          _documents.map((d) => d.toJson()).toList(),
          progress: progress,
        ),
      );
      if (!mounted) return;
      final saved = await FilePicker.saveFile(
        fileName: 'Pageflow-library.pageflowbackup',
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Save library backup',
      );
      if (mounted) {
        _message(saved == null ? 'Backup cancelled.' : 'Library backup saved.');
      }
    } catch (error) {
      if (mounted) {
        _message(
          error is TaskCancelled
              ? 'Backup cancelled.'
              : 'Backup failed: $error',
        );
      }
    }
  }

  Future<void> _restoreLibrary() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: ['pageflowbackup', 'zip'],
      );
      if (file == null || !mounted) return;
      final directory = await _pdfDirectory();
      if (!mounted) return;
      final entries = await runPdfTask(
        context,
        'Restoring library',
        (progress) async => LibraryBackup.restore(
          await file.readAsBytes(),
          directory,
          progress: progress,
        ),
      );
      final restored = entries.map(_Document.fromJson).toList();
      if (!mounted) return;
      _documents.insertAll(0, restored);
      try {
        await _saveDocuments();
      } catch (_) {
        _documents.removeWhere((d) => restored.contains(d));
        for (final d in restored) {
          await File(d.path!).delete();
        }
        rethrow;
      }
      if (mounted) {
        setState(() {});
        _message(
          '${restored.length} documents and reading data restored. Existing documents are kept.',
        );
      }
    } catch (error) {
      if (mounted) {
        _message(
          error is TaskCancelled
              ? 'Restore cancelled.'
              : 'Restore failed: $error',
        );
      }
    }
  }

  Future<void> _openSettings() async {
    var storedBytes = 0;
    for (final document in _documents) {
      final path = document.path;
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) storedBytes += await file.length();
      } catch (_) {
        // The settings screen can still open if one file is unavailable.
      }
    }
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _SettingsPage(
          documentCount: _documents.length,
          storageBytes: storedBytes,
          onClearLibrary: _clearLibraryFromSettings,
          onBackup: _backupLibrary,
          onRestore: _restoreLibrary,
          onDarkModeChanged: widget.onDarkModeChanged,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final readingDocuments =
        _documents
            .where(
              (document) =>
                  document.lastOpenedAt > 0 ||
                  document.lastPage > 1 ||
                  document.bookmarks.isNotEmpty,
            )
            .toList()
          ..sort(
            (first, second) =>
                second.lastOpenedAt.compareTo(first.lastOpenedAt),
          );
    final resumeDocument = readingDocuments.isEmpty
        ? null
        : readingDocuments.first;
    final shown =
        _documents
            .where(
              (doc) =>
                  (_filter == 'All' ||
                      (_filter == 'Favorites'
                          ? doc.isFavorite
                          : doc.kind == _filter)) &&
                  doc.name.toLowerCase().contains(_query.toLowerCase()),
            )
            .toList()
          ..sort((first, second) {
            switch (_sortOrder) {
              case 'oldest':
                return _documentDate(first).compareTo(_documentDate(second));
              case 'recentlyOpened':
                return second.lastOpenedAt.compareTo(first.lastOpenedAt);
              case 'nameAsc':
                return first.name.toLowerCase().compareTo(
                  second.name.toLowerCase(),
                );
              case 'nameDesc':
                return second.name.toLowerCase().compareTo(
                  first.name.toLowerCase(),
                );
              case 'sizeDesc':
                return _documentSize(second).compareTo(_documentSize(first));
              case 'sizeAsc':
                return _documentSize(first).compareTo(_documentSize(second));
              default:
                return _documentDate(second).compareTo(_documentDate(first));
            }
          });
    return Scaffold(
      floatingActionButton: FloatingActionButton(
        backgroundColor: teal,
        foregroundColor: Colors.white,
        onPressed: _importPdf,
        child: const Icon(Icons.add_rounded, size: 29),
      ),
      body: SafeArea(
        child: Column(
          children: [
            if (_selectedPaths.isNotEmpty)
              Container(
                color: teal,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: LocalizedText(
                        '${_selectedPaths.length} selected',
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Select all visible documents',
                      onPressed: () => _toggleVisibleSelection(shown),
                      color: Colors.white,
                      icon: const Icon(Icons.select_all),
                    ),
                    IconButton(
                      tooltip: 'Favorite selected PDFs',
                      onPressed: _toggleSelectedFavorites,
                      color: Colors.white,
                      icon: const Icon(Icons.star_border),
                    ),
                    IconButton(
                      tooltip: 'Share selected PDFs',
                      onPressed: _shareSelectedDocuments,
                      color: Colors.white,
                      icon: const Icon(Icons.share_outlined),
                    ),
                    IconButton(
                      tooltip: 'Remove selected PDFs',
                      onPressed: _removeSelectedDocuments,
                      color: Colors.white,
                      icon: const Icon(Icons.delete_outline),
                    ),
                    IconButton(
                      tooltip: 'Cancel selection',
                      onPressed: () => setState(_selectedPaths.clear),
                      color: Colors.white,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
            Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: isDark
                      ? const [Color(0xFF163B3D), Color(0xFF203F40)]
                      : const [Color(0xFFA9E8EB), Color(0xFFD8F2F2)],
                ),
              ),
              child: Column(
                children: [
                  const Padding(
                    padding: EdgeInsets.fromLTRB(23, 12, 23, 0),
                    child: SizedBox.shrink(),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(22, 18, 20, 18),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                DateTime.now().hour < 12
                                    ? 'Good morning'
                                    : DateTime.now().hour < 17
                                    ? 'Good afternoon'
                                    : 'Good evening',
                                style: TextStyle(fontSize: 13),
                              ),
                              SizedBox(height: 2),
                              LocalizedText(
                                'Reader 👋',
                                style: TextStyle(
                                  fontSize: 24,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (_editingEnabled)
                          _RoundIcon(
                            icon: Icons.note_add_outlined,
                            onTap: _createTextDocument,
                          ),
                        const SizedBox(width: 9),
                        _RoundIcon(icon: Icons.add, onTap: _importPdf),
                        const SizedBox(width: 9),
                        _RoundIcon(
                          icon: Icons.settings_outlined,
                          onTap: _openSettings,
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 17),
                    child: TextField(
                      controller: _searchController,
                      onChanged: (value) => setState(() => _query = value),
                      decoration: InputDecoration(
                        hintText: tr('Search your documents...'),
                        hintStyle: const TextStyle(
                          fontSize: 12,
                          color: Color(0xFF96A7AA),
                        ),
                        prefixIcon: const Icon(Icons.search, size: 21),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.close, size: 18),
                              ),
                        filled: true,
                        fillColor: Theme.of(context).cardColor,
                        contentPadding: EdgeInsets.zero,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(17),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 13),
                  SizedBox(
                    height: 80,
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      children:
                          [
                                'All',
                                'Favorites',
                                'PDF',
                                'Word',
                                'Excel',
                                'PPT',
                                'TXT',
                                'Image',
                              ]
                              .map(
                                (kind) => _FilterChip(
                                  kind: kind,
                                  selected: _filter == kind,
                                  onTap: () => setState(() => _filter = kind),
                                ),
                              )
                              .toList(),
                    ),
                  ),
                  const SizedBox(height: 7),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 86),
                children: [
                  InkWell(
                    onTap: resumeDocument == null
                        ? () => setState(() => _filter = 'All')
                        : () => _openPdf(resumeDocument),
                    borderRadius: BorderRadius.circular(20),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: teal,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        children: [
                          CircleAvatar(
                            backgroundColor: const Color(0xFF244F53),
                            child: Icon(
                              resumeDocument == null
                                  ? Icons.description_outlined
                                  : Icons.menu_book_outlined,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  resumeDocument == null
                                      ? 'Recently Added'
                                      : 'Continue Reading',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  resumeDocument == null
                                      ? 'View your latest files in one place'
                                      : '${resumeDocument.name} · Page ${resumeDocument.lastPage}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Color(0xFFB4CECF),
                                    fontSize: 10,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const Icon(
                            Icons.chevron_right,
                            color: Color(0xFFB4CECF),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (readingDocuments.length > 1) ...[
                    const Padding(
                      padding: EdgeInsets.fromLTRB(2, 16, 2, 8),
                      child: LocalizedText(
                        'Recent reads',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    SizedBox(
                      height: 78,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: readingDocuments.length - 1,
                        separatorBuilder: (_, _) => const SizedBox(width: 9),
                        itemBuilder: (context, index) {
                          final recent = readingDocuments[index + 1];
                          return SizedBox(
                            width: 190,
                            child: Card(
                              margin: EdgeInsets.zero,
                              child: ListTile(
                                dense: true,
                                leading: const Icon(
                                  Icons.picture_as_pdf_outlined,
                                ),
                                title: Text(
                                  recent.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                subtitle: LocalizedText(
                                  'Page ${recent.lastPage} · ${recent.lastOpenedAt > 0 ? _recentLabel(recent.lastOpenedAt) : recent.date}',
                                  maxLines: 1,
                                ),
                                onTap: () => _openPdf(recent),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.fromLTRB(2, 20, 2, 10),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: LocalizedText(
                            '${_filter == 'Favorites' ? 'Favorite Documents' : 'All Documents'} (${shown.length})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            PopupMenuButton<String>(
                              tooltip: 'Sort documents',
                              initialValue: _sortOrder,
                              onSelected: _setSortOrder,
                              icon: const Icon(Icons.sort, size: 20),
                              itemBuilder: (context) => const [
                                PopupMenuItem(
                                  value: 'newest',
                                  child: LocalizedText('Newest first'),
                                ),
                                PopupMenuItem(
                                  value: 'oldest',
                                  child: LocalizedText('Oldest first'),
                                ),
                                PopupMenuItem(
                                  value: 'recentlyOpened',
                                  child: LocalizedText('Recently opened'),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'nameAsc',
                                  child: LocalizedText('Name A–Z'),
                                ),
                                PopupMenuItem(
                                  value: 'nameDesc',
                                  child: LocalizedText('Name Z–A'),
                                ),
                                PopupMenuDivider(),
                                PopupMenuItem(
                                  value: 'sizeDesc',
                                  child: LocalizedText('Largest first'),
                                ),
                                PopupMenuItem(
                                  value: 'sizeAsc',
                                  child: LocalizedText('Smallest first'),
                                ),
                              ],
                            ),
                            TextButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() {
                                  _filter = 'All';
                                  _query = '';
                                });
                              },
                              child: const LocalizedText(
                                'See all',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF648085),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (_loadingDocuments)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (shown.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 13),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(21),
                      ),
                      child: Column(
                        children: shown
                            .map(
                              (doc) => _DocumentTile(
                                document: doc,
                                selected:
                                    doc.path != null &&
                                    _selectedPaths.contains(doc.path),
                                onTap: () => _selectedPaths.isNotEmpty
                                    ? _toggleDocumentSelection(doc)
                                    : _openPdf(doc),
                                onLongPress: () =>
                                    _toggleDocumentSelection(doc),
                                onMenu: () => _showDocumentActions(doc),
                              ),
                            )
                            .toList(),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(24),
                      decoration: BoxDecoration(
                        color: Theme.of(context).cardColor,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Column(
                        children: [
                          const Icon(
                            Icons.search_off,
                            color: Color(0xFF8CA1A4),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            _documents.isEmpty
                                ? 'Your PDF library is empty'
                                : _filter == 'Favorites'
                                ? 'No favorite PDFs yet'
                                : 'No documents found',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 5),
                          Text(
                            _documents.isEmpty
                                ? 'Import a file to start reading offline'
                                : _filter == 'Favorites'
                                ? 'Use a PDF menu to add favorites'
                                : 'Try another search or category',
                            style: const TextStyle(
                              color: Color(0xFF7E979A),
                              fontSize: 12,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (_documents.isEmpty)
                            FilledButton.icon(
                              onPressed: _importPdf,
                              icon: const Icon(Icons.add),
                              label: const LocalizedText('Import PDF'),
                            )
                          else if (_query.isNotEmpty)
                            TextButton(
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _query = '');
                              },
                              child: const LocalizedText('Clear search'),
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface.withValues(alpha: .9),
    shape: const CircleBorder(),
    child: InkWell(
      customBorder: const CircleBorder(),
      onTap: onTap,
      child: SizedBox(
        width: 43,
        height: 43,
        child: Icon(icon, color: Theme.of(context).colorScheme.onSurface),
      ),
    ),
  );
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({
    required this.documentCount,
    required this.storageBytes,
    required this.onClearLibrary,
    required this.onBackup,
    required this.onRestore,
    required this.onDarkModeChanged,
  });

  final int documentCount;
  final int storageBytes;
  final Future<void> Function() onClearLibrary;
  final Future<void> Function() onBackup, onRestore;
  final ValueChanged<bool> onDarkModeChanged;

  String get _formattedStorage {
    if (storageBytes >= 1024 * 1024 * 1024) {
      return '${(storageBytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
    if (storageBytes >= 1024 * 1024) {
      return '${(storageBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(storageBytes / 1024).ceil()} KB';
  }

  Future<void> _confirmClearLibrary(BuildContext context) async {
    if (documentCount == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Clear app PDF copies?'),
        content: const LocalizedText(
          'This permanently removes the PDFs copied into this app and resets the library. Original files at their original locations are not changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const LocalizedText('Clear app copies'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    await onClearLibrary();
    if (context.mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Theme.of(context).scaffoldBackgroundColor,
    appBar: AppBar(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: const LocalizedText(
        'Settings & privacy',
        style: TextStyle(fontWeight: FontWeight.w700),
      ),
      iconTheme: IconThemeData(color: Theme.of(context).colorScheme.onSurface),
    ),
    body: ListView(
      padding: const EdgeInsets.all(18),
      children: [
        const LanguageChoice(),
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: const LocalizedText('Open-source licenses'),
          onTap: () => showLicensePage(
            context: context,
            applicationName: 'Pageflow',
            applicationVersion: '0.4.0',
          ),
        ),
        Card(
          color: Theme.of(context).cardColor,
          child: SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined, color: teal),
            title: const LocalizedText('Dark mode'),
            subtitle: const LocalizedText(
              'Save this appearance on this device',
            ),
            value: Theme.of(context).brightness == Brightness.dark,
            onChanged: onDarkModeChanged,
          ),
        ),
        ListTile(
          leading: const Icon(Icons.backup_outlined),
          title: const LocalizedText('Back up library'),
          subtitle: const LocalizedText(
            'Save documents, bookmarks and reading progress',
          ),
          onTap: onBackup,
        ),
        ListTile(
          leading: const Icon(Icons.restore_outlined),
          title: const LocalizedText('Restore backup'),
          subtitle: const LocalizedText(
            'Recover app copies and reading data; keep existing files',
          ),
          onTap: onRestore,
        ),
        const SizedBox(height: 12),
        _SettingsCard(
          icon: Icons.folder_copy_outlined,
          title: 'App storage',
          subtitle: '$documentCount documents · $_formattedStorage used',
          trailing: const Icon(Icons.phone_android, color: teal),
        ),
        const SizedBox(height: 12),
        const _SettingsCard(
          icon: Icons.lock_outline,
          title: 'Private, on-device files',
          subtitle: 'Documents and reading data stay in this app on your device. There is no account or cloud sync.',
        ),
        const SizedBox(height: 12),
        const _SettingsCard(
          icon: Icons.document_scanner_outlined,
          title: 'Sinhala OCR available offline',
          subtitle: 'Scanned pages can use the Sinhala recognition model bundled with this app.',
        ),
        const SizedBox(height: 12),
        const _SettingsCard(
          icon: Icons.share_outlined,
          title: 'Sharing',
          subtitle: 'A file is shared with another app only after you choose Share and select a destination.',
        ),
        const SizedBox(height: 22),
        Card(
          color: Theme.of(context).cardColor,
          child: ListTile(
            enabled: documentCount > 0,
            leading: const Icon(Icons.delete_sweep_outlined, color: Colors.red),
            title: const LocalizedText('Clear app PDF copies'),
            subtitle: const LocalizedText(
              'Remove this app’s stored copies and reset its library',
            ),
            onTap: documentCount == 0
                ? null
                : () => _confirmClearLibrary(context),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 18, 4, 6),
          child: LocalizedText(
            'Pageflow Reader · 0.4.0',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ),
      ],
    ),
  );
}

class _SettingsCard extends StatelessWidget {
  const _SettingsCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.trailing,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
    color: Theme.of(context).cardColor,
    child: ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      leading: CircleAvatar(
        backgroundColor: aqua.withValues(alpha: .35),
        foregroundColor: teal,
        child: Icon(icon),
      ),
      title: LocalizedText(
        title,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 5),
        child: Text(subtitle),
      ),
      trailing: trailing,
    ),
  );
}

class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.kind,
    required this.selected,
    required this.onTap,
  });
  final String kind;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    const colors = {
      'Favorites': Color(0xFFE5A900),
      'PDF': Color(0xFFE64C51),
      'Word': Color(0xFF246FC7),
      'Excel': Color(0xFF13865F),
      'PPT': Color(0xFFE47B31),
      'TXT': Color(0xFF526D82),
      'Image': Color(0xFF7952A3),
      'All': Color(0xFFE5A900),
    };
    final color = colors[kind]!;
    final label = {
      'Favorites': '★',
      'All': '▰',
      'PDF': 'PDF',
      'Word': 'W',
      'Excel': 'X',
      'PPT': 'P',
      'TXT': 'TXT',
      'Image': 'IMG',
    }[kind]!;
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: kind == 'Favorites' ? 82 : 65,
        child: Column(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(15),
                border: selected
                    ? Border.all(color: const Color(0x558CBDBE), width: 1.5)
                    : null,
              ),
              alignment: Alignment.center,
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w900,
                  fontSize: kind == 'PDF' ? 10 : 17,
                ),
              ),
            ),
            const SizedBox(height: 7),
            Text(
              kind,
              style: TextStyle(
                fontSize: 10,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w400,
                color: selected
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Document {
  const _Document(
    this.name,
    this.kind,
    this.size,
    this.date, {
    this.path,
    this.lastPage = 1,
    this.lastOpenedAt = 0,
    this.bookmarks = const {},
    this.isFavorite = false,
  });
  final String name, kind, size, date;
  final String? path;
  final int lastPage;
  final int lastOpenedAt;
  final Set<int> bookmarks;
  final bool isFavorite;

  _Document copyWith({
    String? name,
    String? path,
    int? lastPage,
    int? lastOpenedAt,
    Set<int>? bookmarks,
    bool? isFavorite,
  }) => _Document(
    name ?? this.name,
    kind,
    size,
    date,
    path: path ?? this.path,
    lastPage: lastPage ?? this.lastPage,
    lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    bookmarks: bookmarks ?? this.bookmarks,
    isFavorite: isFavorite ?? this.isFavorite,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'size': size,
    'date': date,
    'path': path,
    'lastPage': lastPage,
    'lastOpenedAt': lastOpenedAt,
    'bookmarks': bookmarks.toList()..sort(),
    'isFavorite': isFavorite,
  };

  factory _Document.fromJson(Map<String, dynamic> json) {
    final savedBookmarks = json['bookmarks'] as List<dynamic>? ?? const [];
    return _Document(
      json['name'] as String? ?? 'PDF document',
      json['kind'] as String? ?? 'PDF',
      json['size'] as String? ?? 'Unknown size',
      json['date'] as String? ?? '',
      path: json['path'] as String?,
      lastPage: (json['lastPage'] as num?)?.toInt() ?? 1,
      lastOpenedAt: (json['lastOpenedAt'] as num?)?.toInt() ?? 0,
      bookmarks: savedBookmarks
          .whereType<num>()
          .map((page) => page.toInt())
          .where((page) => page > 0)
          .toSet(),
      isFavorite: json['isFavorite'] as bool? ?? false,
    );
  }
}

class _DocumentTile extends StatelessWidget {
  const _DocumentTile({
    required this.document,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onMenu,
  });
  final _Document document;
  final bool selected;
  final VoidCallback onTap, onLongPress, onMenu;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final fileColor =
        {
          'PDF': const Color(0xFFE34D52),
          'Word': const Color(0xFF246FC7),
          'Excel': const Color(0xFF13865F),
          'PPT': const Color(0xFFE47B31),
        }[document.kind] ??
        teal;
    final ext =
        {
          'PDF': 'PDF',
          'Word': 'W',
          'Excel': 'XLS',
          'PPT': 'P',
          'TXT': 'TXT',
          'Image': 'IMG',
        }[document.kind] ??
        'PDF';
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: selected ? aqua.withValues(alpha: .24) : null,
          border: const Border(bottom: BorderSide(color: Color(0xFFEDF1F1))),
        ),
        child: Row(
          children: [
            Container(
              width: 39,
              height: 43,
              decoration: BoxDecoration(
                color: fileColor.withValues(alpha: .09),
                borderRadius: BorderRadius.circular(12),
              ),
              alignment: Alignment.center,
              child: Text(
                ext,
                style: TextStyle(
                  color: fileColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          document.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                      ),
                      if (document.isFavorite)
                        const Padding(
                          padding: EdgeInsets.only(left: 5),
                          child: Icon(
                            Icons.star,
                            size: 14,
                            color: Color(0xFFE5A900),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  LocalizedText(
                    '${document.lastOpenedAt > 0 ? 'Opened ${_recentLabel(document.lastOpenedAt)}' : document.date} · ${document.size}',
                    style: TextStyle(
                      color: colors.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ),
            selected
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.check_circle, color: teal, size: 21),
                  )
                : IconButton(
                    onPressed: onMenu,
                    icon: const Icon(
                      Icons.more_vert,
                      size: 19,
                      color: Color(0xFF6D8589),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

class _PdfReaderPage extends StatefulWidget {
  const _PdfReaderPage({
    required this.document,
    required this.onProgressChanged,
  });
  final _Document document;
  final ValueChanged<_Document> onProgressChanged;
  @override
  State<_PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<_PdfReaderPage> {
  final pdfrx.PdfViewerController _controller = pdfrx.PdfViewerController();
  late final Future<pdfrx.PdfDocument> _readerDocument;
  bool _fitWholePage = false;
  bool _sepia = false;
  late int _page;
  int? _pages;
  List<String>? _cachedPageTexts;
  Future<List<String>>? _pageTextFuture;
  late final Set<int> _bookmarkedPages;

  @override
  void initState() {
    super.initState();
    _page = widget.document.lastPage < 1 ? 1 : widget.document.lastPage;
    _bookmarkedPages = widget.document.bookmarks.toSet();
    _readerDocument = _loadReaderDocument();
  }

  Future<pdfrx.PdfDocument> _loadReaderDocument() async {
    await pdfrx.pdfrxFlutterInitialize();
    final document = await pdfrx.PdfDocument.openFile(widget.document.path!);
    if (!mounted) {
      await document.dispose();
      throw StateError('Reader closed.');
    }
    if (document.pages.isEmpty) {
      await document.dispose();
      throw const FormatException('This PDF has no readable pages.');
    }
    _page = _page.clamp(1, document.pages.length).toInt();
    return document;
  }

  void _fitPage(bool whole) {
    _fitWholePage = whole;
    if (!_controller.isReady) return;
    _controller.goTo(
      whole
          ? _controller.calcMatrixForFit(pageNumber: _page)
          : _controller.calcMatrixFitWidthForPage(pageNumber: _page),
    );
  }

  void _saveProgress() {
    widget.onProgressChanged(
      widget.document.copyWith(
        lastPage: _page,
        lastOpenedAt: DateTime.now().millisecondsSinceEpoch,
        bookmarks: _bookmarkedPages.toSet(),
      ),
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: LocalizedText(text)));
  }

  Future<void> _openNativeObjectEditor() async {
    final savedPath = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _NativePdfEditorPage(
          sourcePath: widget.document.path!,
          pageNumber: _page,
        ),
      ),
    );
    if (!mounted || savedPath == null) return;
    final file = File(savedPath);
    final now = DateTime.now();
    final replacing = savedPath == widget.document.path;
    final name = replacing ? widget.document.name : file.uri.pathSegments.last;
    final size = await file.length();
    if (!mounted) return;
    Navigator.of(context).pop(
      _Document(
        name,
        'PDF',
        _formatBytes(size),
        '${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
        path: file.path,
        lastPage: replacing ? widget.document.lastPage : 1,
        bookmarks: replacing ? widget.document.bookmarks : {},
        isFavorite: replacing && widget.document.isFavorite,
      ),
    );
  }

  @override
  void dispose() {
    super.dispose();
  }

  Future<void> _openAnnotator({
    bool highlight = false,
    List<Uint8List>? imageStamps,
  }) async {
    final sourcePath = widget.document.path!;
    final directory = File(sourcePath).parent;
    final baseName = widget.document.name.replaceAll(
      RegExp(r'\.pdf$', caseSensitive: false),
      '',
    );
    final editedName =
        '${baseName}_edited_${DateTime.now().millisecondsSinceEpoch}.pdf';
    final savePath = '${directory.path}${Platform.pathSeparator}$editedName';

    try {
      final result = await FlutterPdfAnnotations.openPDF(
        filePath: sourcePath,
        savePath: savePath,
        config: PDFAnnotationConfig(
          title: highlight ? 'Highlight PDF' : 'Annotate PDF',
          initialPage: _page - 1,
          initialPenColor: teal,
          initialHighlightColor: const Color(0x66FFE14A),
          initialStrokeWidth: highlight ? 14 : 3,
          imagesToInsert: imageStamps,
        ),
      );
      if (!mounted) return;
      if (result.isError) {
        _message(result.error ?? 'Could not edit this PDF.');
        return;
      }
      if (!result.isSuccess || result.savedPath == null) return;

      final savedFile = File(result.savedPath!);
      final bytes = await savedFile.length();
      final savedDate = DateTime.now();
      final editedDocument = _Document(
        editedName,
        'PDF',
        _formatBytes(bytes),
        '${savedDate.day.toString().padLeft(2, '0')}/${savedDate.month.toString().padLeft(2, '0')}/${savedDate.year}',
        path: savedFile.path,
      );
      if (!mounted) return;
      Navigator.of(context).pop(editedDocument);
    } catch (error) {
      if (mounted) _message('Could not edit this PDF: $error');
    }
  }

  Future<void> _insertSignatureImage() async {
    final selected = await FilePicker.pickFiles(type: FileType.image);
    if (!mounted || selected.isEmpty) return;
    try {
      final imageBytes = await selected.first.readAsBytes();
      if (!mounted) return;
      await _openAnnotator(imageStamps: [imageBytes]);
    } catch (error) {
      if (mounted) _message('Could not load the signature image: $error');
    }
  }

  Future<void> _addTextStamp() async {
    final input = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Add text to this page'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LocalizedText(
              'This adds a new text note on top of the PDF page. It does not change existing PDF text.',
              style: TextStyle(fontSize: 12, color: Color(0xFF6F8589)),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: input,
              autofocus: true,
              minLines: 2,
              maxLines: 5,
              maxLength: 300,
              decoration: InputDecoration(
                labelText: tr('Text note'),
                hintText: tr('Type a note or label'),
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: const LocalizedText('Continue'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (!mounted || text == null || text.isEmpty) return;

    try {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(
            color: Color(0xFF07363B),
            fontSize: 42,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        textAlign: TextAlign.left,
      )..layout(maxWidth: 1200);
      const padding = 24.0;
      final width = (painter.width + padding * 2).ceil();
      final height = (painter.height + padding * 2).ceil();
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, const Offset(padding, padding));
      final picture = recorder.endRecording();
      final image = await picture.toImage(width, height);
      picture.dispose();
      try {
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) throw Exception('Text note could not be rendered.');
        final png = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        if (!mounted) return;
        await _openAnnotator(imageStamps: [png]);
      } finally {
        image.dispose();
      }
    } catch (error) {
      if (mounted) _message('Could not add this text note: $error');
    }
  }

  Future<void> _replaceTextOnCurrentPage() async {
    final findController = TextEditingController();
    final replaceController = TextEditingController();
    const textColors = [
      Colors.black,
      Color(0xFF07363B),
      Color(0xFF245BC5),
      Color(0xFFB3261E),
      Color(0xFF16804A),
      Color(0xFF6A3DBA),
    ];
    var selectedTextColor = Colors.black;
    var selectedTextScale = 1.0;
    final replacement = await showDialog<Map<String, Object>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const LocalizedText('Replace text on this page'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LocalizedText(
                  'Finds the first exact match on the current page. The nearby background is sampled for the cover; the edited page is flattened, while other pages stay selectable.',
                  style: TextStyle(fontSize: 12, color: Color(0xFF6F8589)),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: findController,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText: tr('Find exact text'),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: replaceController,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: tr('Replace with (leave blank to erase)'),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 4),
                const LocalizedText('Replacement color'),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final color in textColors)
                      ChoiceChip(
                        label: const SizedBox(width: 12, height: 12),
                        selected: selectedTextColor == color,
                        avatar: CircleAvatar(backgroundColor: color),
                        onSelected: (_) =>
                            setDialogState(() => selectedTextColor = color),
                      ),
                  ],
                ),
                Row(
                  children: [
                    const LocalizedText('Text size'),
                    Expanded(
                      child: Slider(
                        value: selectedTextScale,
                        min: 0.6,
                        max: 1.4,
                        divisions: 8,
                        label: '${selectedTextScale.toStringAsFixed(1)}×',
                        onChanged: (value) =>
                            setDialogState(() => selectedTextScale = value),
                      ),
                    ),
                    LocalizedText('${(selectedTextScale * 100).round()}%'),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const LocalizedText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, {
                'find': findController.text,
                'replace': replaceController.text,
                'color': selectedTextColor.toARGB32(),
                'scale': selectedTextScale,
              }),
              child: const LocalizedText('Replace'),
            ),
          ],
        ),
      ),
    );
    final findText = (replacement?['find'] as String? ?? '').trim();
    final replaceText = replacement?['replace'] as String? ?? '';
    final replacementColor = Color(
      (replacement?['color'] as int?) ?? Colors.black.toARGB32(),
    );
    final replacementScale = (replacement?['scale'] as double?) ?? 1.0;
    findController.dispose();
    replaceController.dispose();
    if (!mounted || replacement == null) return;
    if (findText.isEmpty) {
      _message('Enter the exact text to find.');
      return;
    }

    pdfrx.PdfDocument? source;
    pdfrx.PdfDocument? editedPageDocument;
    pdfrx.PdfDocument? output;
    pdfrx.PdfImage? pageImage;
    ui.Image? decodedImage;
    File? savedFile;
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: LocalizedText('Finding and replacing text locally…'),
          duration: Duration(seconds: 2),
        ),
      );
      await pdfrx.pdfrxFlutterInitialize();
      source = await pdfrx.PdfDocument.openFile(widget.document.path!);
      if (_page < 1 || _page > source.pages.length) {
        throw Exception('The current page is no longer available.');
      }
      final page = source.pages[_page - 1];
      final text = await page.loadStructuredText();
      if (text.fullText.isEmpty) {
        throw Exception('This page does not contain selectable text.');
      }
      final matchStart = text.fullText.indexOf(findText);
      if (matchStart < 0) {
        throw Exception('The exact text was not found on this page.');
      }
      final matchEnd = matchStart + findText.length;
      final matchRects = <pdfrx.PdfRect>[];
      var mappedCharacters = 0;
      for (final fragment in text.fragments) {
        final overlapStart = matchStart > fragment.index
            ? matchStart
            : fragment.index;
        final overlapEnd = matchEnd < fragment.end ? matchEnd : fragment.end;
        if (overlapStart >= overlapEnd) continue;
        final localStart = overlapStart - fragment.index;
        final localEnd = overlapEnd - fragment.index;
        if (localStart < 0 || localEnd > fragment.charRects.length) {
          throw Exception('Text position could not be mapped safely.');
        }
        matchRects.addAll(fragment.charRects.sublist(localStart, localEnd));
        mappedCharacters += overlapEnd - overlapStart;
      }
      if (mappedCharacters != findText.length || matchRects.isEmpty) {
        throw Exception('Text position could not be mapped safely.');
      }
      final positionedRects = page.rotation.index == 0
          ? matchRects
          : matchRects
                .map((rect) => rect.rotate(page.rotation.index, page))
                .toList();
      final lineCenters =
          positionedRects.map((rect) => (rect.top + rect.bottom) / 2).toList()
            ..sort();
      final maxGlyphHeight = positionedRects
          .map((rect) => rect.height)
          .reduce((a, b) => a > b ? a : b);
      if (lineCenters.last - lineCenters.first > maxGlyphHeight * 0.8) {
        throw Exception(
          'Select text from a single line at a time; this match crosses lines.',
        );
      }
      var bounds = positionedRects.first;
      for (final rect in positionedRects.skip(1)) {
        bounds = bounds.merge(rect);
      }
      if (bounds.isEmpty) {
        throw Exception('The selected text has no usable page position.');
      }

      final renderWidth = page.width.clamp(1400.0, 2000.0).toDouble();
      final renderHeight = renderWidth * page.height / page.width;
      pageImage = await page.render(
        fullWidth: renderWidth,
        fullHeight: renderHeight,
        backgroundColor: 0xffffffff,
      );
      if (pageImage == null) throw Exception('Could not render this page.');
      final imageCompleter = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pageImage.pixels,
        pageImage.width,
        pageImage.height,
        ui.PixelFormat.bgra8888,
        imageCompleter.complete,
      );
      decodedImage = await imageCompleter.future;

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final fullRect = Rect.fromLTWH(
        0,
        0,
        pageImage.width.toDouble(),
        pageImage.height.toDouble(),
      );
      canvas.drawImageRect(
        decodedImage,
        Rect.fromLTWH(
          0,
          0,
          decodedImage.width.toDouble(),
          decodedImage.height.toDouble(),
        ),
        fullRect,
        Paint(),
      );
      final scaleX = pageImage.width / page.width;
      final scaleY = pageImage.height / page.height;
      final padX = 2.0 * scaleX;
      final padY = 1.5 * scaleY;
      final cover = Rect.fromLTRB(
        (bounds.left * scaleX - padX)
            .clamp(0.0, pageImage.width.toDouble())
            .toDouble(),
        ((page.height - bounds.top) * scaleY - padY)
            .clamp(0.0, pageImage.height.toDouble())
            .toDouble(),
        (bounds.right * scaleX + padX)
            .clamp(0.0, pageImage.width.toDouble())
            .toDouble(),
        ((page.height - bounds.bottom) * scaleY + padY)
            .clamp(0.0, pageImage.height.toDouble())
            .toDouble(),
      );
      final samplePoints = [
        Offset(cover.left - 3, cover.center.dy),
        Offset(cover.right + 3, cover.center.dy),
        Offset(cover.center.dx, cover.top - 3),
        Offset(cover.center.dx, cover.bottom + 3),
      ];
      var sampledRed = 0;
      var sampledGreen = 0;
      var sampledBlue = 0;
      var sampleCount = 0;
      for (final point in samplePoints) {
        final x = point.dx.round().clamp(0, pageImage.width - 1).toInt();
        final y = point.dy.round().clamp(0, pageImage.height - 1).toInt();
        final pixel = (y * pageImage.width + x) * 4;
        sampledBlue += pageImage.pixels[pixel];
        sampledGreen += pageImage.pixels[pixel + 1];
        sampledRed += pageImage.pixels[pixel + 2];
        sampleCount++;
      }
      final coverColor = Color.fromARGB(
        255,
        sampledRed ~/ sampleCount,
        sampledGreen ~/ sampleCount,
        sampledBlue ~/ sampleCount,
      );
      canvas.drawRect(cover, Paint()..color = coverColor);

      if (replaceText.isNotEmpty) {
        final inner = cover.deflate(1.0).intersect(fullRect);
        final availableWidth = inner.width;
        final availableHeight = inner.height;
        var fontSize = (availableHeight * 0.74 * replacementScale)
            .clamp(5.5, 120.0)
            .toDouble();
        TextPainter? replacementPainter;
        while (fontSize >= 5.5) {
          final candidate = TextPainter(
            text: TextSpan(
              text: replaceText,
              style: TextStyle(
                color: replacementColor,
                fontSize: fontSize,
                fontFamily: 'Pageflow UI',
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          if (candidate.width <= availableWidth &&
              candidate.height <= availableHeight) {
            replacementPainter = candidate;
            break;
          }
          fontSize -= 0.5;
          candidate.dispose();
        }
        if (replacementPainter == null) {
          throw Exception(
            'Replacement text does not fit the selected space. Use shorter text.',
          );
        }
        final textOffset = Offset(
          inner.left,
          inner.top + (inner.height - replacementPainter.height) / 2,
        );
        replacementPainter.paint(canvas, textOffset);
        replacementPainter.dispose();
      }

      final picture = recorder.endRecording();
      final finalImage = await picture.toImage(
        pageImage.width,
        pageImage.height,
      );
      picture.dispose();
      try {
        final rawImage = await finalImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        if (rawImage == null) throw Exception('Could not encode edited page.');
        final raster = img.Image.fromBytes(
          width: finalImage.width,
          height: finalImage.height,
          bytes: rawImage.buffer,
          bytesOffset: rawImage.offsetInBytes,
          numChannels: 4,
          order: img.ChannelOrder.rgba,
        );
        final jpegBytes = img.encodeJpg(raster, quality: 96);
        final editedPageBytes = _imagePagesPdf([
          _PdfImagePage(
            jpegBytes: jpegBytes,
            imageWidth: pageImage.width,
            imageHeight: pageImage.height,
            pageWidth: page.width,
            pageHeight: page.height,
          ),
        ]);
        if (!await _confirmRasterEdit(
          jpegBytes,
          pageImage.width,
          pageImage.height,
        )) {
          return;
        }
        editedPageDocument = await pdfrx.PdfDocument.openData(
          editedPageBytes,
          sourceName:
              'pageflow-edited-page-${DateTime.now().microsecondsSinceEpoch}.pdf',
        );
        output = await pdfrx.PdfDocument.createNew(
          sourceName:
              'pageflow-text-replacement-${DateTime.now().microsecondsSinceEpoch}.pdf',
        );
        output.pages = [
          for (var index = 0; index < source.pages.length; index++)
            index == _page - 1
                ? editedPageDocument.pages.single
                : source.pages[index],
        ];
        if (!await output.assemble()) {
          throw Exception('Could not assemble the edited document.');
        }
        final pdfBytes = await output.encodePdf();
        await output.dispose();
        output = null;
        await editedPageDocument.dispose();
        editedPageDocument = null;
        await source.dispose();
        source = null;

        final baseName = widget.document.name.replaceAll(
          RegExp(r'\.pdf$', caseSensitive: false),
          '',
        );
        final editedName =
            '${baseName}_text_edit_${DateTime.now().millisecondsSinceEpoch}.pdf';
        final destination =
            '${File(widget.document.path!).parent.path}${Platform.pathSeparator}$editedName';
        savedFile = await File(destination).writeAsBytes(pdfBytes, flush: true);
        final date = DateTime.now();
        final editedDocument = _Document(
          editedName,
          'PDF',
          _formatBytes(await savedFile.length()),
          '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}',
          path: savedFile.path,
        );
        if (mounted) Navigator.of(context).pop(editedDocument);
      } finally {
        finalImage.dispose();
      }
    } catch (error) {
      if (savedFile != null && await savedFile.exists()) {
        await savedFile.delete();
      }
      if (mounted) _message('Could not replace text: $error');
    } finally {
      pageImage?.dispose();
      decodedImage?.dispose();
      await output?.dispose();
      await editedPageDocument?.dispose();
      await source?.dispose();
    }
  }

  Future<void> _replaceAreaWithImage() async {
    PdfRenderDocument? previewDocument;
    PdfRenderPage? previewPage;
    Rect? normalizedArea;
    Uint8List? previewBytes;
    double previewWidth = 0;
    double previewHeight = 0;
    try {
      previewDocument = await PdfRenderDocument.openFile(widget.document.path!);
      previewPage = await previewDocument.getPage(_page);
      final renderWidth = previewPage.width.clamp(800.0, 1400.0).toDouble();
      final preview = await previewPage.render(
        width: renderWidth,
        height: renderWidth * previewPage.height / previewPage.width,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#FFFFFF',
        quality: 86,
      );
      if (preview == null) throw Exception('Could not preview this page.');
      previewBytes = preview.bytes;

      if (!mounted) return;
      final screen = MediaQuery.sizeOf(context);
      final imageWidth = preview.width;
      final imageHeight = preview.height;
      if (imageWidth == null ||
          imageHeight == null ||
          imageWidth <= 0 ||
          imageHeight <= 0) {
        throw Exception('Could not measure the page preview.');
      }
      final scale = math
          .min(
            math.min((screen.width - 76) / imageWidth, 1.35),
            math.min((screen.height * 0.48) / imageHeight, 1.0),
          )
          .toDouble();
      previewWidth = imageWidth * scale;
      previewHeight = imageHeight * scale;
      Offset? dragStart;
      Offset? dragEnd;
      normalizedArea = await showDialog<Rect>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final dragged = dragStart == null || dragEnd == null
                ? null
                : Rect.fromPoints(
                    dragStart!,
                    dragEnd!,
                  ).intersect(Rect.fromLTWH(0, 0, previewWidth, previewHeight));
            return AlertDialog(
              title: const LocalizedText('Select the area to replace'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LocalizedText(
                    'Drag a box around the existing picture or area. The edited page is flattened when saved.',
                    style: TextStyle(fontSize: 12),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: previewWidth,
                    height: previewHeight,
                    child: GestureDetector(
                      onPanStart: (details) => setDialogState(() {
                        dragStart = details.localPosition;
                        dragEnd = details.localPosition;
                      }),
                      onPanUpdate: (details) => setDialogState(() {
                        dragEnd = details.localPosition;
                      }),
                      onPanEnd: (_) => setDialogState(() {}),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Image.memory(previewBytes!, fit: BoxFit.fill),
                          if (dragged != null)
                            Positioned.fromRect(
                              rect: dragged,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0x33208080),
                                  border: Border.all(
                                    color: const Color(0xFF087D83),
                                    width: 2,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: const LocalizedText('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      dragged == null || dragged.width < 8 || dragged.height < 8
                      ? null
                      : () => Navigator.pop(
                          dialogContext,
                          Rect.fromLTRB(
                            (dragged.left / previewWidth)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                            (dragged.top / previewHeight)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                            (dragged.right / previewWidth)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                            (dragged.bottom / previewHeight)
                                .clamp(0.0, 1.0)
                                .toDouble(),
                          ),
                        ),
                  child: const LocalizedText('Choose image'),
                ),
              ],
            );
          },
        ),
      );
    } catch (error) {
      if (mounted) _message('Could not select an area: $error');
      return;
    } finally {
      await previewPage?.close();
      await previewDocument?.close();
    }
    if (!mounted || normalizedArea == null) return;

    final selected = await FilePicker.pickFiles(type: FileType.image);
    if (!mounted || selected.isEmpty) return;
    final imageSize = await selected.first.length();
    if (!mounted) return;
    if (imageSize != null && imageSize > 20 * 1024 * 1024) {
      _message('Choose an image smaller than 20 MB.');
      return;
    }
    Uint8List stampBytes;
    try {
      stampBytes = await selected.first.readAsBytes();
      if (!mounted) return;
    } catch (error) {
      _message('Could not read the replacement image: $error');
      return;
    }

    pdfrx.PdfDocument? source;
    pdfrx.PdfDocument? editedPageDocument;
    pdfrx.PdfDocument? output;
    pdfrx.PdfImage? pageImage;
    ui.Image? pageUiImage;
    ui.Image? stampImage;
    ui.Image? finalImage;
    File? savedFile;
    try {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: LocalizedText('Replacing the selected area locally…'),
          duration: Duration(seconds: 2),
        ),
      );
      await pdfrx.pdfrxFlutterInitialize();
      source = await pdfrx.PdfDocument.openFile(widget.document.path!);
      final page = source.pages[_page - 1];
      final renderWidth = page.width.clamp(1400.0, 2000.0).toDouble();
      pageImage = await page.render(
        fullWidth: renderWidth,
        fullHeight: renderWidth * page.height / page.width,
        backgroundColor: 0xffffffff,
      );
      if (pageImage == null) throw Exception('Could not render this page.');
      final pageCompleter = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pageImage.pixels,
        pageImage.width,
        pageImage.height,
        ui.PixelFormat.bgra8888,
        pageCompleter.complete,
      );
      pageUiImage = await pageCompleter.future;
      final stampCodec = await ui.instantiateImageCodec(stampBytes);
      final stampFrame = await stampCodec.getNextFrame();
      stampImage = stampFrame.image;
      stampCodec.dispose();

      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final wholeImage = Rect.fromLTWH(
        0,
        0,
        pageImage.width.toDouble(),
        pageImage.height.toDouble(),
      );
      canvas.drawImageRect(
        pageUiImage,
        Rect.fromLTWH(
          0,
          0,
          pageUiImage.width.toDouble(),
          pageUiImage.height.toDouble(),
        ),
        wholeImage,
        Paint(),
      );
      final target = Rect.fromLTRB(
        normalizedArea.left * pageImage.width,
        normalizedArea.top * pageImage.height,
        normalizedArea.right * pageImage.width,
        normalizedArea.bottom * pageImage.height,
      );
      canvas.drawRect(target, Paint()..color = const Color(0xFFFFFFFF));
      final fitted = applyBoxFit(
        BoxFit.contain,
        Size(stampImage.width.toDouble(), stampImage.height.toDouble()),
        target.size,
      );
      final sourceRect = Alignment.center.inscribe(
        fitted.source,
        Rect.fromLTWH(
          0,
          0,
          stampImage.width.toDouble(),
          stampImage.height.toDouble(),
        ),
      );
      final destinationRect = Alignment.center.inscribe(
        fitted.destination,
        target,
      );
      canvas.drawImageRect(stampImage, sourceRect, destinationRect, Paint());

      final picture = recorder.endRecording();
      finalImage = await picture.toImage(pageImage.width, pageImage.height);
      picture.dispose();
      final rawImage = await finalImage.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      if (rawImage == null) {
        throw Exception('Could not encode the edited page.');
      }
      final raster = img.Image.fromBytes(
        width: finalImage.width,
        height: finalImage.height,
        bytes: rawImage.buffer,
        bytesOffset: rawImage.offsetInBytes,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      final editedPageJpeg = img.encodeJpg(raster, quality: 96);
      if (!await _confirmRasterEdit(
        editedPageJpeg,
        pageImage.width,
        pageImage.height,
      )) {
        return;
      }
      final editedPageBytes = _imagePagesPdf([
        _PdfImagePage(
          jpegBytes: editedPageJpeg,
          imageWidth: pageImage.width,
          imageHeight: pageImage.height,
          pageWidth: page.width,
          pageHeight: page.height,
        ),
      ]);
      editedPageDocument = await pdfrx.PdfDocument.openData(
        editedPageBytes,
        sourceName:
            'pageflow-image-edit-${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      output = await pdfrx.PdfDocument.createNew(
        sourceName:
            'pageflow-image-replacement-${DateTime.now().microsecondsSinceEpoch}.pdf',
      );
      output.pages = [
        for (var index = 0; index < source.pages.length; index++)
          index == _page - 1
              ? editedPageDocument.pages.single
              : source.pages[index],
      ];
      if (!await output.assemble()) {
        throw Exception('Could not assemble the edited document.');
      }
      final pdfBytes = await output.encodePdf();
      await output.dispose();
      output = null;
      await editedPageDocument.dispose();
      editedPageDocument = null;
      await source.dispose();
      source = null;

      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final editedName =
          '${baseName}_image_edit_${DateTime.now().millisecondsSinceEpoch}.pdf';
      final destination =
          '${File(widget.document.path!).parent.path}${Platform.pathSeparator}$editedName';
      savedFile = await File(destination).writeAsBytes(pdfBytes, flush: true);
      final date = DateTime.now();
      final editedDocument = _Document(
        editedName,
        'PDF',
        _formatBytes(await savedFile.length()),
        '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}',
        path: savedFile.path,
      );
      if (mounted) Navigator.of(context).pop(editedDocument);
    } catch (error) {
      if (savedFile != null && await savedFile.exists()) {
        await savedFile.delete();
      }
      if (mounted) _message('Could not replace this area: $error');
    } finally {
      pageImage?.dispose();
      pageUiImage?.dispose();
      stampImage?.dispose();
      finalImage?.dispose();
      await output?.dispose();
      await editedPageDocument?.dispose();
      await source?.dispose();
    }
  }

  Future<bool> _confirmRasterEdit(
    Uint8List jpegBytes,
    int imageWidth,
    int imageHeight,
  ) async {
    final screen = MediaQuery.sizeOf(context);
    final scale = math
        .min(
          (screen.width - 72) / imageWidth,
          (screen.height * 0.44) / imageHeight,
        )
        .toDouble();
    return await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const LocalizedText('Review edited page'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const LocalizedText(
                  'Check the result before saving. This page will be flattened into an image; the original PDF stays unchanged.',
                  style: TextStyle(fontSize: 12),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: imageWidth * scale,
                  height: imageHeight * scale,
                  child: Image.memory(jpegBytes, fit: BoxFit.contain),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const LocalizedText('Discard'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const LocalizedText('Save copy'),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _formatBytes(int bytes) => bytes >= 1024 * 1024
      ? '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';

  Future<void> _exportCurrentPage(PdfPageImageFormat format) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: LocalizedText('Preparing this page for export…'),
        duration: Duration(seconds: 2),
      ),
    );

    PdfRenderDocument? source;
    PdfRenderPage? page;
    try {
      source = await PdfRenderDocument.openFile(widget.document.path!);
      page = await source.getPage(_page);
      final renderWidth = page.width.clamp(1200.0, 2000.0).toDouble();
      if (!mounted) return;
      final rendered = await runPdfTask(context, 'Rendering page export', (
        progress,
      ) async {
        await progress.step('Rendering page $_page…');
        return page!.render(
          width: renderWidth,
          height: renderWidth * page.height / page.width,
          format: format,
          backgroundColor: '#FFFFFF',
          quality: format == PdfPageImageFormat.jpeg ? 92 : 100,
          forPrint: true,
          progress: progress,
        );
      });
      if (rendered == null) {
        throw Exception('The page could not be rendered.');
      }

      final extension = format == PdfPageImageFormat.png ? 'png' : 'jpg';
      final mimeType = format == PdfPageImageFormat.png
          ? 'image/png'
          : 'image/jpeg';
      final saved = await FilePicker.saveFile(
        fileName:
            '${widget.document.name.replaceAll(RegExp(r'\.pdf$', caseSensitive: false), '')}-page-$_page.$extension',
        bytes: rendered.bytes,
        mimeType: mimeType,
        dialogTitle: 'Save page as ${extension.toUpperCase()}',
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null ? 'Export cancelled.' : 'Page saved as .$extension.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: LocalizedText('Could not export this page: $error'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } finally {
      await page?.close();
      await source?.close();
    }
  }

  Future<void> _exportCurrentPageAsPdf() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: LocalizedText('Preparing a PDF copy of this page…'),
        duration: Duration(seconds: 2),
      ),
    );
    PdfRenderDocument? source;
    PdfRenderPage? page;
    try {
      source = await PdfRenderDocument.openFile(widget.document.path!);
      page = await source.getPage(_page);
      final renderWidth = page.width.clamp(1400.0, 2200.0).toDouble();
      if (!mounted) return;
      final rendered = await runPdfTask(context, 'Rendering page export', (
        progress,
      ) async {
        await progress.step('Rendering page $_page…');
        return page!.render(
          width: renderWidth,
          height: renderWidth * page.height / page.width,
          format: PdfPageImageFormat.jpeg,
          backgroundColor: '#FFFFFF',
          quality: 96,
          forPrint: true,
          progress: progress,
        );
      });
      if (rendered == null ||
          rendered.width == null ||
          rendered.height == null) {
        throw Exception('The page could not be rendered.');
      }
      final pdfBytes = _imagePagesPdf([
        _PdfImagePage(
          jpegBytes: rendered.bytes,
          imageWidth: rendered.width!,
          imageHeight: rendered.height!,
          pageWidth: page.width,
          pageHeight: page.height,
        ),
      ]);
      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final saved = await FilePicker.saveFile(
        fileName: '$baseName-page-$_page.pdf',
        bytes: pdfBytes,
        mimeType: 'application/pdf',
        dialogTitle: 'Save this page as a PDF',
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'PDF export cancelled.'
                : 'This page was saved as a PDF image.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: LocalizedText('Could not create this page PDF: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      await page?.close();
      await source?.close();
    }
  }

  Future<void> _exportSelectedPagesAsPdf() async {
    final pageCount = _pages;
    if (pageCount == null) {
      _message('Wait until the PDF finishes loading.');
      return;
    }
    final input = TextEditingController(text: '$_page');
    final selection = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Edit pages and save a copy'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LocalizedText(
              'Enter pages to keep, in the order you want. Leave out page numbers to remove them. You can also rotate pages.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: input,
              autofocus: true,
              decoration: InputDecoration(
                labelText: tr('Pages'),
                hintText: tr('3, 1-2, 5r, 7l'),
                helperText:
                    'r = rotate right · l = rotate left · up to 200 pages',
              ),
              onSubmitted: (value) => Navigator.pop(dialogContext, value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text),
            child: const LocalizedText('Continue'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (!mounted || selection == null) return;
    final selectedPages = _parsePageSelection(selection, pageCount);
    if (selectedPages == null) {
      _message('Enter valid, non-duplicate pages or ranges (max 200).');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: LocalizedText('Preparing ${selectedPages.length} pages…'),
        duration: const Duration(seconds: 2),
      ),
    );
    pdfrx.PdfDocument? source;
    pdfrx.PdfDocument? output;
    try {
      await pdfrx.pdfrxFlutterInitialize();
      source = await pdfrx.PdfDocument.openFile(widget.document.path!);
      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      output = await pdfrx.PdfDocument.createNew(
        sourceName: '$baseName-pages-arranged.pdf',
      );
      output.pages = selectedPages.map((selection) {
        final page = source!.pages[selection.number - 1];
        return switch (selection.rotation) {
          90 => page.rotatedCW90(),
          270 => page.rotatedCCW90(),
          _ => page,
        };
      }).toList();
      // The new page list still refers to the source document until assembled.
      // Assemble before disposing it so the output no longer depends on it.
      if (!await output.assemble()) {
        throw Exception('The selected pages could not be assembled.');
      }
      final bytes = await output.encodePdf();
      await output.dispose();
      output = null;
      await source.dispose();
      source = null;

      final saved = await FilePicker.saveFile(
        fileName: '$baseName-pages-arranged.pdf',
        bytes: bytes,
        mimeType: 'application/pdf',
        dialogTitle: 'Save extracted PDF pages',
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'Page extraction cancelled.'
                : '${selectedPages.length} pages saved; text and vector content are retained.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: LocalizedText('Could not extract these pages: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      await output?.dispose();
      await source?.dispose();
    }
  }

  Future<void> _mergeWithOtherPdfs() async {
    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['pdf'],
    );
    if (!mounted || selected.isEmpty) return;

    final sourcePaths = <String>{widget.document.path!};
    for (final file in selected) {
      final path = file.path;
      if (path == null) {
        _message('Could not access one of the selected PDFs.');
        return;
      }
      if (path.toLowerCase().endsWith('.pdf')) {
        sourcePaths.add(path);
      }
    }
    if (sourcePaths.length < 2) {
      _message('Choose at least one other PDF to merge.');
      return;
    }

    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: LocalizedText('Merging PDFs locally…'),
        duration: Duration(seconds: 2),
      ),
    );

    final sources = <pdfrx.PdfDocument>[];
    pdfrx.PdfDocument? output;
    File? savedFile;
    try {
      await pdfrx.pdfrxFlutterInitialize();
      for (final path in sourcePaths) {
        final source = await pdfrx.PdfDocument.openFile(path);
        sources.add(source);
      }
      final totalPages = sources.fold<int>(
        0,
        (count, source) => count + source.pages.length,
      );
      if (totalPages > 200) {
        throw Exception(
          'This merge flow supports up to 200 pages per output. '
          'The selected PDFs contain $totalPages pages.',
        );
      }

      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      output = await pdfrx.PdfDocument.createNew(
        sourceName: '$baseName-merged.pdf',
      );
      output.pages = [for (final source in sources) ...source.pages];
      if (!await output.assemble()) {
        throw Exception('The selected pages could not be assembled.');
      }
      final bytes = await output.encodePdf();
      await output.dispose();
      output = null;
      for (final source in sources) {
        await source.dispose();
      }
      sources.clear();

      final now = DateTime.now();
      final mergedName = '${baseName}_merged_${now.millisecondsSinceEpoch}.pdf';
      final destination =
          '${File(widget.document.path!).parent.path}${Platform.pathSeparator}$mergedName';
      savedFile = await File(destination).writeAsBytes(bytes, flush: true);
      final savedDate = DateTime.now();
      final mergedDocument = _Document(
        mergedName,
        'PDF',
        _formatBytes(await savedFile.length()),
        '${savedDate.day.toString().padLeft(2, '0')}/${savedDate.month.toString().padLeft(2, '0')}/${savedDate.year}',
        path: savedFile.path,
      );
      if (!mounted) return;
      Navigator.of(context).pop(mergedDocument);
    } catch (error) {
      if (savedFile != null && await savedFile.exists()) {
        await savedFile.delete();
      }
      if (mounted) {
        _message('Could not merge these PDFs: $error');
      }
    } finally {
      await output?.dispose();
      for (final source in sources) {
        await source.dispose();
      }
    }
  }

  Future<void> _exportEditableOffice(String format) async {
    try {
      final extracted = await _readPdfPages();
      if (!mounted) return;
      final pages = await Navigator.of(context).push<List<String>>(
        MaterialPageRoute(builder: (_) => OfficeTextReview(pages: extracted)),
      );
      if (!mounted || pages == null) return;
      final bytes = await runPdfTask(
        context,
        'Preparing Office export',
        (progress) => OfficeEditableExport.create(pages, format, progress),
      );
      if (!mounted) return;
      final extension = format == 'word'
          ? 'docx'
          : format == 'excel'
          ? 'xlsx'
          : 'pptx';
      final mime = format == 'word'
          ? 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
          : format == 'excel'
          ? 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
          : 'application/vnd.openxmlformats-officedocument.presentationml.presentation';
      final saved = await FilePicker.saveFile(
        fileName:
            '${widget.document.name.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '')}.$extension',
        bytes: bytes,
        mimeType: mime,
        dialogTitle: 'Save reviewed Office text',
      );
      if (mounted) {
        _message(
          saved == null ? 'Export cancelled.' : 'Reviewed Office file saved.',
        );
      }
    } catch (error) {
      if (mounted) {
        _message(
          error is TaskCancelled
              ? 'Export cancelled.'
              : 'Office export failed: $error',
        );
      }
    }
  }

  Future<List<String>> _readPdfPages() async {
    final cached = _cachedPageTexts;
    if (cached != null) return List<String>.of(cached);

    final pending = _pageTextFuture ??= runPdfTask(
      context,
      'Reading text / Sinhala OCR',
      (progress) => _extractPdfPagesAndRunOcr(progress),
    );
    try {
      final pages = await pending;
      _cachedPageTexts = List<String>.unmodifiable(pages);
      return List<String>.of(pages);
    } catch (_) {
      _pageTextFuture = null;
      rethrow;
    }
  }

  Future<List<String>> _extractPdfPagesAndRunOcr(TaskProgress progress) async {
    progress.onCancel = () {
      unawaited(OfflineSinhalaOcr.cancel().catchError((Object error) {}));
    };
    await pdfrx.pdfrxFlutterInitialize();
    final pdf = await pdfrx.PdfDocument.openFile(widget.document.path!);
    final pages = <String>[];
    var characters = 0;
    try {
      for (final page in pdf.pages) {
        await progress.step(
          'Reading page ${pages.length + 1} of ${pdf.pages.length}',
          done: pages.length,
          total: pdf.pages.length,
        );
        final text = (await page.loadText())?.fullText.trim() ?? '';
        characters += text.length;
        if (characters > 12 * 1024 * 1024) {
          throw const FormatException(
            'Extract text from smaller documents; this operation supports up to 12 MB of text.',
          );
        }
        pages.add(text);
      }
    } finally {
      await pdf.dispose();
    }

    Uint8List? sourceBytes;
    for (var index = 0; index < pages.length; index++) {
      if (pages[index].isNotEmpty) continue;
      await progress.step(
        'Recognizing Sinhala page ${index + 1} of ${pages.length}',
        done: index,
        total: pages.length,
      );
      sourceBytes ??= await File(widget.document.path!).readAsBytes();
      pages[index] = (await OfflineSinhalaOcr.recognize(
        sourceBytes,
        index + 1,
      )).text.trim();
    }
    progress.check();
    return pages;
  }

  Future<void> _exportOfficeFormat(String format) async {
    final mode = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const LocalizedText('Office export'),
        content: const LocalizedText(
          'Editable text lets you review and correct extracted text. Preserve appearance embeds page images; text in those images is not editable.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const LocalizedText('Editable text'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const LocalizedText('Preserve appearance'),
          ),
        ],
      ),
    );
    if (mode == null) return;
    if (mode) {
      if (!mounted) return;
      try {
        final bytes = await runPdfTask(
          context,
          'Exporting Office layout',
          (progress) async => OfficeLayoutExport.create(
            await File(widget.document.path!).readAsBytes(),
            format,
            progress: progress,
          ),
        );
        final extension = format == 'word'
            ? 'docx'
            : format == 'excel'
            ? 'xlsx'
            : 'pptx';
        await FilePicker.saveFile(
          fileName: '${widget.document.name}.$extension',
          bytes: bytes,
          dialogTitle: 'Save Office page images',
        );
        if (mounted) _message('Office layout export prepared.');
      } catch (error) {
        if (mounted) _message('Could not export layout: $error');
      }
      return;
    }

    if (!mounted) return;
    await _exportEditableOffice(format);
  }

  Future<void> _copyExtractedText() async {
    try {
      final pages = await _readPdfPages();
      final extracted = <String>[];
      for (var index = 0; index < pages.length; index++) {
        if (pages[index].isEmpty) continue;
        extracted.add('--- Page ${index + 1} ---\n${pages[index]}');
      }
      if (extracted.isEmpty) {
        _message('No text could be recognized in this PDF.');
        return;
      }
      await Clipboard.setData(ClipboardData(text: extracted.join('\n\n')));
      if (mounted) _message('Extracted PDF text copied to clipboard.');
    } catch (error) {
      if (mounted) _message('Could not copy PDF text: $error');
    }
  }

  String _csvCell(String value) => '"${value.replaceAll('"', '""')}"';

  Future<void> _exportCsv() async {
    try {
      final pages = await _readPdfPages();
      if (!pages.any((page) => page.isNotEmpty)) {
        _message('No text could be recognized in this PDF.');
        return;
      }
      final csv = StringBuffer('\uFEFFPage,Extracted text\r\n');
      for (var index = 0; index < pages.length; index++) {
        if (pages[index].isEmpty) continue;
        csv
          ..write('${index + 1},')
          ..write(_csvCell(pages[index]))
          ..write('\r\n');
      }
      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final saved = await FilePicker.saveFile(
        fileName: '$baseName.csv',
        bytes: Uint8List.fromList(utf8.encode(csv.toString())),
        mimeType: 'text/csv',
        dialogTitle: 'Save extracted text as CSV',
      );
      if (mounted) {
        _message(
          saved == null
              ? 'CSV export cancelled.'
              : 'CSV file saved. Extracted text is grouped by PDF page.',
        );
      }
    } catch (error) {
      if (mounted) _message('Could not export CSV: $error');
    }
  }

  Future<void> _shareOriginal() async {
    try {
      await _shareChannel.invokeMethod<void>('sharePdf', {
        'path': widget.document.path,
        'name': widget.document.name,
        'mimeType': 'application/pdf',
      });
    } catch (error) {
      if (mounted) _message('Could not share this file: $error');
    }
  }

  Future<void> _showDocumentInfo() async {
    final document = widget.document;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Document details'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _detailLine('File', document.name),
            _detailLine('Type', 'PDF'),
            _detailLine('Size', document.size),
            _detailLine('Added', document.date),
            _detailLine(
              'Current page',
              '$_page${_pages == null ? '' : ' of $_pages'}',
            ),
            _detailLine('Bookmarks', '${_bookmarkedPages.length}'),
            const SizedBox(height: 10),
            const LocalizedText(
              'This document is stored and processed on this device.',
              style: TextStyle(fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Close'),
          ),
        ],
      ),
    );
  }

  Widget _detailLine(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 7),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 92,
          child: Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );

  Future<void> _exportPlainText() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: LocalizedText('Extracting PDF text…'),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      final pages = await _readPdfPages();
      if (!pages.any((page) => page.isNotEmpty)) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(
              content: LocalizedText(
                'No text could be recognized in this PDF.',
              ),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        return;
      }
      final output = StringBuffer('${widget.document.name}\n\n');
      for (var index = 0; index < pages.length; index++) {
        if (pages[index].isEmpty) continue;
        output
          ..write('--- Page ${index + 1} ---\n')
          ..write(pages[index])
          ..write('\n\n');
      }
      final baseName = widget.document.name.replaceAll(
        RegExp(r'\.pdf$', caseSensitive: false),
        '',
      );
      final saved = await FilePicker.saveFile(
        fileName: '$baseName.txt',
        bytes: Uint8List.fromList(utf8.encode(output.toString())),
        mimeType: 'text/plain',
        dialogTitle: 'Save extracted text',
      );
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'Text export cancelled.'
                : 'Extracted text saved as a TXT file.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (error) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: LocalizedText('Could not export text: $error'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    }
  }

  Future<void> _goToPage() async {
    final pageCount = _pages;
    if (pageCount == null) {
      _message('Wait until the PDF finishes loading.');
      return;
    }
    final input = TextEditingController(text: '$_page');
    final requestedPage = await showDialog<int>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Go to page'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) =>
              Navigator.pop(dialogContext, int.tryParse(input.text.trim())),
          decoration: InputDecoration(
            hintText: tr('Page 1–$pageCount'),
            suffixText: '/ $pageCount',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, int.tryParse(input.text.trim())),
            child: const LocalizedText('Go'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (!mounted || requestedPage == null) return;
    if (requestedPage < 1 || requestedPage > pageCount) {
      _message('Choose a page from 1 to $pageCount.');
      return;
    }
    _controller.goToPage(
      pageNumber: requestedPage,
      duration: const Duration(milliseconds: 300),
    );
  }

  void _toggleBookmark() {
    setState(() {
      if (!_bookmarkedPages.add(_page)) {
        _bookmarkedPages.remove(_page);
      }
    });
    _saveProgress();
    _message(
      _bookmarkedPages.contains(_page)
          ? 'Page $_page bookmarked.'
          : 'Bookmark removed from page $_page.',
    );
  }

  Future<void> _showBookmarks() async {
    if (_bookmarkedPages.isEmpty) {
      _message('No bookmarks yet. Save a page using the bookmark button.');
      return;
    }
    final pages = _bookmarkedPages.toList()..sort();
    final selectedPage = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (sheetContext, setSheetState) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .55,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 6, 20, 10),
                  child: LocalizedText(
                    'Bookmarked pages',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                ),
                Expanded(
                  child: pages.isEmpty
                      ? const Center(
                          child: LocalizedText('No bookmarks saved.'),
                        )
                      : ListView.builder(
                          itemCount: pages.length,
                          itemBuilder: (context, index) {
                            final pageNumber = pages[index];
                            return ListTile(
                              leading: const Icon(Icons.bookmark, color: teal),
                              title: LocalizedText('Page $pageNumber'),
                              trailing: IconButton(
                                tooltip: 'Remove bookmark',
                                icon: const Icon(
                                  Icons.bookmark_remove_outlined,
                                ),
                                onPressed: () {
                                  setState(
                                    () => _bookmarkedPages.remove(pageNumber),
                                  );
                                  _saveProgress();
                                  setSheetState(() => pages.remove(pageNumber));
                                },
                              ),
                              onTap: () =>
                                  Navigator.pop(sheetContext, pageNumber),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (selectedPage == null || !mounted) return;
    _controller.goToPage(
      pageNumber: selectedPage,
      duration: const Duration(milliseconds: 300),
    );
  }

  Future<void> _searchInPdf() async {
    final input = TextEditingController();
    final query = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Find in document'),
        content: TextField(
          controller: input,
          autofocus: true,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
          decoration: InputDecoration(
            hintText: tr('Enter a word or phrase'),
            prefixIcon: Icon(Icons.search),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, input.text.trim()),
            child: const LocalizedText('Search'),
          ),
        ],
      ),
    );
    Future<void>.delayed(const Duration(milliseconds: 300), input.dispose);
    if (query == null || query.isEmpty || !mounted) return;

    try {
      final pages = await _readPdfPages();
      if (!mounted) return;
      final matches = await runPdfTask(context, 'Searching document', (
        progress,
      ) async {
        final matches = <(int, String)>[];
        final needle = query.toLowerCase();
        for (var pageIndex = 0; pageIndex < pages.length; pageIndex++) {
          await progress.step(
            'Searching page ${pageIndex + 1} of ${pages.length}',
            done: pageIndex,
            total: pages.length,
          );
          final pageText = pages[pageIndex];
          final lower = pageText.toLowerCase();
          var offset = 0;
          while (offset < pageText.length) {
            final matchAt = lower.indexOf(needle, offset);
            if (matchAt < 0) break;
            final start = (matchAt - 38).clamp(0, pageText.length).toInt();
            final end = (matchAt + query.length + 72)
                .clamp(0, pageText.length)
                .toInt();
            final prefix = start > 0 ? '…' : '';
            final suffix = end < pageText.length ? '…' : '';
            matches.add((
              pageIndex + 1,
              '$prefix${pageText.substring(start, end)}$suffix',
            ));
            if (matches.length >= 200) break;
            offset = matchAt + query.length;
          }
          if (matches.length >= 200) break;
        }

        progress.check();
        return matches;
      });
      if (!mounted) return;

      if (matches.isEmpty) {
        _message(
          'No matches for “$query”. Try another word or a clearer scan.',
        );
        return;
      }

      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(sheetContext).height * .68,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                  child: LocalizedText(
                    '${matches.length}${matches.length == 200 ? '+' : ''} results for “$query”',
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                      color: ink,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: matches.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final (pageNumber, snippet) = matches[index];
                      return ListTile(
                        leading: CircleAvatar(
                          backgroundColor: aqua,
                          foregroundColor: teal,
                          child: LocalizedText('$pageNumber'),
                        ),
                        title: Text(
                          snippet,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                        onTap: () {
                          Navigator.pop(sheetContext);
                          _controller.goToPage(
                            pageNumber: pageNumber,
                            duration: const Duration(milliseconds: 350),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;

      _message(
        error is TaskCancelled
            ? 'Search cancelled.'
            : 'Could not search this PDF: $error',
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colors.surface,
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
        ),
        title: Column(
          children: [
            LocalizedText(
              'PDF DOCUMENT',
              style: TextStyle(
                fontSize: 9,
                letterSpacing: 1,
                color: colors.onSurfaceVariant,
              ),
            ),
            LocalizedText(
              'Read Document',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: colors.onSurface,
              ),
            ),
          ],
        ),
        centerTitle: true,
        actions: [
          if (_editingEnabled)
            TextButton.icon(
              onPressed: _pages == null ? null : _openNativeObjectEditor,
              icon: const Icon(Icons.edit_outlined),
              label: const LocalizedText('Edit'),
            ),
          IconButton(
            tooltip: 'Find in PDF',
            onPressed: _searchInPdf,
            icon: const Icon(Icons.search),
          ),
          PopupMenuButton<String>(
            tooltip: 'Reading options',
            icon: const Icon(Icons.chrome_reader_mode_outlined),
            onSelected: (value) {
              if (value == 'sepia') {
                setState(() => _sepia = !_sepia);
              } else {
                _fitPage(value == 'page');
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(
                value: 'width',
                child: LocalizedText('Fit width'),
              ),
              const PopupMenuItem(
                value: 'page',
                child: LocalizedText('Fit page'),
              ),
              PopupMenuItem(
                value: 'sepia',
                child: Text(_sepia ? 'Normal colors' : 'Sepia reading'),
              ),
            ],
          ),
          PopupMenuButton<String>(
            tooltip: 'Document options',
            icon: const Icon(Icons.ios_share_outlined),
            onSelected: (option) {
              switch (option) {
                case 'share':
                  _shareOriginal();
                  break;
                case 'nativeEdit':
                  _openNativeObjectEditor();
                  break;
                case 'png':
                  _exportCurrentPage(PdfPageImageFormat.png);
                  break;
                case 'jpeg':
                  _exportCurrentPage(PdfPageImageFormat.jpeg);
                  break;
                case 'pagePdf':
                  _exportCurrentPageAsPdf();
                  break;
                case 'extractPages':
                  _exportSelectedPagesAsPdf();
                  break;
                case 'mergePdfs':
                  _mergeWithOtherPdfs();
                  break;
                case 'replaceText':
                  _replaceTextOnCurrentPage();
                  break;
                case 'replaceArea':
                  _replaceAreaWithImage();
                  break;
                case 'resetZoom':
                  _fitPage(false);
                  break;
                case 'word':
                  _exportOfficeFormat('word');
                  break;
                case 'excel':
                  _exportOfficeFormat('excel');
                  break;
                case 'ppt':
                  _exportOfficeFormat('ppt');
                  break;
                case 'txt':
                  _exportPlainText();
                  break;
                case 'copyText':
                  _copyExtractedText();
                  break;
                case 'csv':
                  _exportCsv();
                  break;
                case 'info':
                  _showDocumentInfo();
                  break;
              }
            },
            itemBuilder: (context) => const [
              if (_editingEnabled) ...[
                PopupMenuItem(
                  value: 'nativeEdit',
                  child: LocalizedText('Edit PDF objects and text'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'resetZoom',
                  child: LocalizedText('Reset zoom to fit page'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'png',
                  child: LocalizedText('Export current page as PNG'),
                ),
                PopupMenuItem(
                  value: 'jpeg',
                  child: LocalizedText('Export current page as JPEG'),
                ),
                PopupMenuItem(
                  value: 'pagePdf',
                  child: LocalizedText('Save current page as a PDF image'),
                ),
                PopupMenuItem(
                  value: 'extractPages',
                  child: LocalizedText('Remove, reorder, or rotate pages'),
                ),
                PopupMenuItem(
                  value: 'mergePdfs',
                  child: LocalizedText('Merge this PDF with other PDFs'),
                ),
                PopupMenuItem(
                  value: 'replaceText',
                  child: LocalizedText('Replace existing text on this page'),
                ),
                PopupMenuItem(
                  value: 'replaceArea',
                  child: LocalizedText('Replace an image or area on this page'),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: 'word',
                  child: LocalizedText('Convert selectable text to Word'),
                ),
                PopupMenuItem(
                  value: 'excel',
                  child: LocalizedText('Convert selectable text to Excel'),
                ),
                PopupMenuItem(
                  value: 'ppt',
                  child: LocalizedText('Convert selectable text to PowerPoint'),
                ),
                PopupMenuItem(
                  value: 'txt',
                  child: LocalizedText('Export extracted text as TXT'),
                ),
                PopupMenuItem(
                  value: 'copyText',
                  child: LocalizedText('Copy extracted text'),
                ),
                PopupMenuItem(
                  value: 'csv',
                  child: LocalizedText('Export extracted text as CSV'),
                ),
                PopupMenuDivider(),
              ],
              PopupMenuItem(
                value: 'share',
                child: LocalizedText('Share original file'),
              ),
              PopupMenuItem(
                value: 'info',
                child: LocalizedText('Document details'),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: _goToPage,
                    borderRadius: BorderRadius.circular(8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        LocalizedText(
                          'PAGE ${_page.toString().padLeft(2, '0')}${_pages == null ? '' : ' OF ${_pages.toString().padLeft(2, '0')}'}',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: .7,
                            color: colors.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Icon(
                          Icons.expand_more,
                          size: 16,
                          color: colors.onSurfaceVariant,
                        ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Previous page',
                  onPressed: _page > 1
                      ? () => _controller.goToPage(
                          pageNumber: _page - 1,
                          duration: const Duration(milliseconds: 240),
                        )
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Next page',
                  onPressed: _pages != null && _page < _pages!
                      ? () => _controller.goToPage(
                          pageNumber: _page + 1,
                          duration: const Duration(milliseconds: 240),
                        )
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: _bookmarkedPages.contains(_page)
                      ? 'Remove bookmark'
                      : 'Bookmark this page',
                  onPressed: _toggleBookmark,
                  icon: Icon(
                    _bookmarkedPages.contains(_page)
                        ? Icons.bookmark
                        : Icons.bookmark_border,
                    color: colors.primary,
                    size: 20,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  tooltip: 'Bookmarks',
                  onPressed: _showBookmarks,
                  icon: Icon(
                    Icons.bookmarks_outlined,
                    color: colors.primary,
                    size: 19,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: FutureBuilder<pdfrx.PdfDocument>(
                  future: _readerDocument,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: LocalizedText(
                            'Could not open this PDF.\n${snapshot.error}',
                            textAlign: TextAlign.center,
                          ),
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    // Attach the viewer only after the initial page is validated.
                    return ColorFiltered(
                      colorFilter: _sepia
                          ? const ColorFilter.matrix([
                              1,
                              0,
                              0,
                              0,
                              12,
                              0,
                              .95,
                              0,
                              0,
                              7,
                              0,
                              0,
                              .82,
                              0,
                              0,
                              0,
                              0,
                              0,
                              1,
                              0,
                            ])
                          : const ColorFilter.mode(
                              Colors.transparent,
                              BlendMode.dst,
                            ),
                      child: pdfrx.PdfViewer(
                        pdfrx.PdfDocumentRefDirect(
                          snapshot.data!,
                          key: pdfrx.PdfDocumentRefKey(
                            'reader-${identityHashCode(this)}',
                          ),
                        ),
                        controller: _controller,
                        initialPageNumber: _page,
                        params: pdfrx.PdfViewerParams(
                          maxImageBytesCachedOnMemory: 48 * 1024 * 1024,
                          verticalCacheExtent: .5,
                          onPageChanged: (page) {
                            if (!mounted ||
                                page == null ||
                                _pages == null ||
                                page == _page) {
                              return;
                            }
                            setState(() => _page = page);
                            _saveProgress();
                          },
                          onViewerReady: (document, controller) {
                            if (!mounted) return;
                            setState(() {
                              _pages = document.pages.length;
                              _page = _page.clamp(1, _pages!).toInt();
                              _bookmarkedPages.removeWhere((p) => p > _pages!);
                            });
                            _saveProgress();
                            _fitPage(_fitWholePage);
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
          if (_editingEnabled)
            Container(
              margin: const EdgeInsets.fromLTRB(14, 12, 14, 18),
              padding: const EdgeInsets.fromLTRB(12, 13, 12, 15),
              decoration: BoxDecoration(
                color: Theme.of(context).cardColor,
                borderRadius: BorderRadius.circular(19),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LocalizedText(
                    'Edit Tools',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                      color: colors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      for (final tool in const [
                        ('Objects', Icons.select_all),
                        ('Annotate', Icons.draw_outlined),
                        ('Highlight', Icons.highlight_outlined),
                        ('Text', Icons.text_fields),
                        ('Sign', Icons.gesture),
                        ('Replace', Icons.find_replace),
                      ])
                        Expanded(
                          child: _ToolButton(
                            label: tool.$1,
                            icon: tool.$2,
                            onTap: switch (tool.$1) {
                              'Objects' => _openNativeObjectEditor,
                              'Annotate' => () => _openAnnotator(),
                              'Highlight' => () => _openAnnotator(
                                highlight: true,
                              ),
                              'Text' => _addTextStamp,
                              'Replace' => _replaceTextOnCurrentPage,
                              _ => _insertSignatureImage,
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _NativePdfEditorPage extends StatefulWidget {
  const _NativePdfEditorPage({
    required this.sourcePath,
    required this.pageNumber,
  });
  final String sourcePath;
  final int pageNumber;

  @override
  State<_NativePdfEditorPage> createState() => _NativePdfEditorPageState();
}

class _NativePdfEditorPageState extends State<_NativePdfEditorPage> {
  late Future<PdfiumObjectEditor> _opening;
  late int _editingPage;
  PdfiumObjectEditor? _editor;
  List<PdfObjectInfo> _objects = [];
  int? _selectedIndex;
  bool _busy = false;
  int _previewGeneration = 0;
  Uint8List? _previewPdf;
  double _previewAspect = 1;
  List<PdfTapTarget> _tapTargets = [];
  late final TextEditingController _left;
  late final TextEditingController _bottom;
  late final TextEditingController _width;
  late final TextEditingController _height;

  @override
  void initState() {
    super.initState();
    _editingPage = widget.pageNumber;
    _left = TextEditingController();
    _bottom = TextEditingController();
    _width = TextEditingController();
    _height = TextEditingController();
    _opening = PdfiumObjectEditor.open(widget.sourcePath).then((editor) async {
      if (!mounted) {
        await editor.dispose();
        return editor;
      }
      _editor = editor;
      await _refresh();
      return editor;
    });
  }

  Future<void> _refresh() async {
    final editor = _editor;
    if (editor == null || !mounted) return;
    _editingPage = _editingPage.clamp(1, editor.pageCount).toInt();
    final objects = await editor.listObjects(_editingPage);
    final targets = await editor.tapTargets(_editingPage);
    final previewDocument = await pdfrx.PdfDocument.openData(
      editor.currentBytes,
    );
    Uint8List? preview;
    try {
      final page = previewDocument.pages[_editingPage - 1];
      _previewAspect = page.width / page.height;
      final scale = math.min(
        1200 / page.width,
        math.sqrt(4000000 / (page.width * page.height)),
      );
      final rendered = await page.render(
        fullWidth: (page.width * scale).roundToDouble(),
        fullHeight: (page.height * scale).roundToDouble(),
      );
      if (rendered != null) {
        try {
          preview = img.encodePng(
            img.Image.fromBytes(
              width: rendered.width,
              height: rendered.height,
              bytes: rendered.pixels.buffer,
              bytesOffset: rendered.pixels.offsetInBytes,
              numChannels: 4,
              order: img.ChannelOrder.bgra,
            ),
          );
        } finally {
          rendered.dispose();
        }
      }
    } finally {
      await previewDocument.dispose();
    }

    if (!mounted) return;
    setState(() {
      _objects = objects;
      _tapTargets = targets;
      _previewPdf = preview;
      _previewGeneration++;
      if (_selectedIndex != null &&
          !_objects.any((object) => object.index == _selectedIndex)) {
        _selectedIndex = null;
      }
    });
    if (_selectedIndex != null) {
      final object = _objects
          .where((item) => item.index == _selectedIndex)
          .firstOrNull;
      if (object != null) _setBounds(object);
    }
  }

  void _setBounds(PdfObjectInfo object) {
    _left.text = object.left.toStringAsFixed(1);
    _bottom.text = object.bottom.toStringAsFixed(1);
    _width.text = object.width.toStringAsFixed(1);
    _height.text = object.height.toStringAsFixed(1);
  }

  Future<void> _zoomPage() async {
    if (_previewPdf == null || _busy) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (zoomContext) => Scaffold(
          appBar: AppBar(
            title: Text('Edit page $_editingPage — pinch to zoom'),
          ),
          body: Center(
            child: PdfClickCanvas(
              image: _previewPdf!,
              aspectRatio: _previewAspect,
              targets: _tapTargets,
              zoomable: true,
              onTap: (object) {
                Navigator.pop(zoomContext);
                _editTextObject(object);
              },
              onScan: () {
                Navigator.pop(zoomContext);
                _correctScannedText();
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _run(Future<void> Function(PdfiumObjectEditor) action) async {
    final editor = _editor;
    if (editor == null || _busy) return;
    setState(() => _busy = true);
    try {
      await action(editor);
      if (!mounted) return;
      _selectedIndex = null;
      await _refresh();
    } catch (error) {
      if (mounted) _showMessage('Edit failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replaceText() async {
    final find = TextEditingController();
    final replace = TextEditingController();
    final values = await showDialog<(String, String)>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const LocalizedText('Replace selectable PDF text'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: find,
              decoration: InputDecoration(labelText: tr('Find')),
            ),
            TextField(
              controller: replace,
              decoration: InputDecoration(labelText: tr('Replace with')),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const LocalizedText('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, (find.text, replace.text)),
            child: const LocalizedText('Replace all'),
          ),
        ],
      ),
    );
    find.dispose();
    replace.dispose();
    if (!mounted || values == null) return;
    final editor = _editor;
    if (editor == null) return;
    setState(() => _busy = true);
    try {
      final count = await editor.replaceTextMatchesEverywhere(
        values.$1,
        values.$2,
      );
      _selectedIndex = null;
      await _refresh();
      if (mounted) {
        _showMessage(
          count == 0
              ? 'No selectable text-object matches in this PDF.'
              : 'Updated text in $count text object(s) across the PDF.',
        );
      }
    } catch (error) {
      if (mounted) _showMessage('Text replacement failed: $error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addText() async {
    final editor = _editor;
    if (editor == null || _busy) return;
    final size = await editor.pageSize(_editingPage);
    if (!mounted) return;
    final box = await showDialog<PdfTextBox>(
      context: context,
      builder: (_) => TextBoxDialog(
        initial: PdfTextBox(
          id: 'box-${DateTime.now().microsecondsSinceEpoch}',
          text: '',
          left: 24,
          bottom: 24,
          width: math.min(300, size.width - 48),
          height: math.min(160, size.height - 48),
        ),
      ),
    );
    if (!mounted || box == null) return;
    await _run((e) => e.upsertTextBox(_editingPage, box));
  }

  Future<void> _editTextObject(PdfObjectInfo selected) async {
    final editor = _editor;
    if (editor == null || _busy || !selected.canEditText) return;
    final size = await editor.pageSize(_editingPage);
    if (!mounted) return;
    final style = selected.editableStyle();
    final initial = style.copyWith(
      width: math.min(style.width, math.max(12, size.width - style.left)),
      height: math.min(style.height, math.max(12, size.height - style.bottom)),
    );
    final box = await showDialog<PdfTextBox>(
      context: context,
      builder: (_) => TextBoxDialog(initial: initial, editing: true),
    );
    if (!mounted || box == null) return;
    await _run(
      (e) => e.upsertTextBox(_editingPage, box, objectIndex: selected.index),
    );
  }

  Future<void> _correctScannedText() async {
    if (_editor == null || _busy) return;
    setState(() => _busy = true);
    try {
      final changed = await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) =>
              ScannedTextEditor(editor: _editor!, page: _editingPage),
        ),
      );
      if (!mounted) return;
      if (changed == true) {
        _selectedIndex = null;
        await _refresh();
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final editor = _editor;
    if (editor == null || _busy) return;
    final mode = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const LocalizedText('Save PDF'),
        content: const LocalizedText(
          'Save a new copy, or replace the original in this app’s library.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const LocalizedText('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'replace'),
            child: const LocalizedText('Replace library original'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'copy'),
            child: const LocalizedText('Save copy'),
          ),
        ],
      ),
    );
    if (!mounted || mode == null) return;
    if (mode == 'replace') {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const LocalizedText('Replace the library PDF?'),
          content: const LocalizedText(
            'The current library copy will be overwritten. The file you originally picked from your device is kept.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const LocalizedText('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const LocalizedText('Replace'),
            ),
          ],
        ),
      );
      if (!mounted || confirmed != true) return;
    }
    final source = File(widget.sourcePath);
    final destination = mode == 'replace'
        ? source.path
        : '${source.parent.path}${Platform.pathSeparator}${source.uri.pathSegments.last.replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '')}_native_edit_${DateTime.now().millisecondsSinceEpoch}.pdf';
    await _run((session) async {
      await session.saveTo(destination);
      if (mounted) Navigator.of(context).pop(destination);
    });
  }

  Future<void> _fillForms() async {
    if (_editor == null || _busy) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PdfFormPage(editor: _editor!)),
    );
    if (mounted && changed == true) {
      _selectedIndex = null;
      await _refresh();
    }
  }

  Future<void> _pageTools() async {
    if (_editor == null || _busy) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PdfPageManager(editor: _editor!)),
    );
    if (mounted && changed == true) {
      _selectedIndex = null;
      await _refresh();
    }
  }

  Future<void> _redact() async {
    if (_editor == null || _busy) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => PdfRedactionPage(editor: _editor!)),
    );
    if (mounted && changed == true) {
      _selectedIndex = null;
      await _refresh();
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _editor?.dispose();
    _left.dispose();
    _bottom.dispose();
    _width.dispose();
    _height.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const LocalizedText('Edit PDF'),
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(28),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LocalizedText(
                'Page $_editingPage · ${_objects.length} objects',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
            ],
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: 'Undo',
          onPressed: _editor?.canUndo == true && !_busy
              ? () => _run((e) => e.undo())
              : null,
          icon: const Icon(Icons.undo),
        ),
        IconButton(
          tooltip: 'Redo',
          onPressed: _editor?.canRedo == true && !_busy
              ? () => _run((e) => e.redo())
              : null,
          icon: const Icon(Icons.redo),
        ),
        IconButton(
          tooltip: 'OCR scanned text',
          onPressed: _editor != null && !_busy ? _correctScannedText : null,
          icon: const Icon(Icons.document_scanner_outlined),
        ),
        Tooltip(
          message: 'Save PDF',
          child: TextButton.icon(
            onPressed: _editor != null && !_busy ? _save : null,
            icon: const Icon(Icons.save_outlined),
            label: const LocalizedText('Save'),
          ),
        ),
      ],
    ),
    body: FutureBuilder<PdfiumObjectEditor>(
      future: _opening,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LocalizedText(
                'Could not open the local PDF editing engine.\n${snapshot.error}',
                textAlign: TextAlign.center,
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final selected = _objects
            .where((item) => item.index == _selectedIndex)
            .firstOrNull;
        return ListView(
          key: const ValueKey('pdf-editor-tools'),
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: 'Previous editing page',
                  onPressed: _busy || _editingPage <= 1
                      ? null
                      : () => _run((_) async {
                          _editingPage--;
                        }),
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: _editingPage,
                    items: [
                      for (var n = 1; n <= _editor!.pageCount; n++)
                        DropdownMenuItem(
                          value: n,
                          child: Text('Page $n of ${_editor!.pageCount}'),
                        ),
                    ],
                    onChanged: _busy
                        ? null
                        : (n) {
                            if (n != null) {
                              _run((_) async {
                                _editingPage = n;
                              });
                            }
                          },
                  ),
                ),
                IconButton(
                  key: const ValueKey('pdf-edit-next-page'),
                  tooltip: 'Next editing page',
                  onPressed: _busy || _editingPage >= _editor!.pageCount
                      ? null
                      : () => _run((_) async {
                          _editingPage++;
                        }),
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            const Text(
              'Tap a highlighted text block to edit it. Choose any page above; use OCR for scanned text.',
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _busy ? null : _zoomPage,
                icon: const Icon(Icons.zoom_in),
                label: const Text('Zoom page'),
              ),
            ),
            const SizedBox(height: 10),
            if (_previewPdf != null)
              SizedBox(
                height: 480,
                child: Center(
                  child: PdfClickCanvas(
                    key: ValueKey(_previewGeneration),
                    image: _previewPdf!,
                    aspectRatio: _previewAspect,
                    targets: _tapTargets,
                    selected: _selectedIndex,
                    enabled: !_busy,
                    onTap: (object) {
                      setState(() {
                        _selectedIndex = object.index;
                        _setBounds(object);
                      });
                      _editTextObject(object);
                    },
                    onScan: () {
                      if (!_objects.any((o) => o.canEditText)) {
                        _correctScannedText();
                      }
                    },
                  ),
                ),
              ),
            const SizedBox(height: 12),
            if (_objects.isEmpty)
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: LocalizedText(
                    'No editable text, image, or vector objects were found on this page.',
                  ),
                ),
              ),
            for (final object in _objects)
              Card(
                child: ListTile(
                  selected: object.index == _selectedIndex,
                  leading: Icon(
                    object.canEditText
                        ? Icons.text_fields
                        : object.type == 3
                        ? Icons.image_outlined
                        : Icons.category_outlined,
                  ),
                  title: LocalizedText('${object.label} ${object.index + 1}'),
                  subtitle: LocalizedText(
                    'x ${object.left.toStringAsFixed(1)}, y ${object.bottom.toStringAsFixed(1)} · ${object.width.toStringAsFixed(1)} × ${object.height.toStringAsFixed(1)} pt',
                  ),
                  onTap: () => setState(() {
                    _selectedIndex = object.index;
                    _setBounds(object);
                  }),
                ),
              ),
            if (selected != null) ...[
              const SizedBox(height: 12),
              if (selected.canEditText)
                FilledButton.icon(
                  onPressed: _busy ? null : () => _editTextObject(selected),
                  icon: const Icon(Icons.text_fields),
                  label: const LocalizedText(
                    'Edit selected text / font / style',
                  ),
                ),
              LocalizedText(
                'Selected ${selected.label.toLowerCase()}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _numberField('Left (pt)', _left),
                  const SizedBox(width: 8),
                  _numberField('Bottom (pt)', _bottom),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _numberField('Width (pt)', _width),
                  const SizedBox(width: 8),
                  _numberField('Height (pt)', _height),
                ],
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: _busy
                    ? null
                    : () => _run(
                        (editor) => editor.transformObject(
                          _editingPage,
                          selected.index,
                          left: double.parse(_left.text),
                          bottom: double.parse(_bottom.text),
                          width: double.parse(_width.text),
                          height: double.parse(_height.text),
                        ),
                      ),
                icon: const Icon(Icons.open_with),
                label: const LocalizedText('Move / resize selected object'),
              ),
              OutlinedButton.icon(
                onPressed: _busy
                    ? null
                    : () async {
                        final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (ctx) => AlertDialog(
                            title: const LocalizedText(
                              'Delete this PDF object?',
                            ),
                            content: const LocalizedText(
                              'This removes the selected content object from this page.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.pop(ctx, false),
                                child: const LocalizedText('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.pop(ctx, true),
                                child: const LocalizedText('Delete'),
                              ),
                            ],
                          ),
                        );
                        if (confirmed == true) {
                          await _run(
                            (editor) => editor.deleteObject(
                              _editingPage,
                              selected.index,
                            ),
                          );
                        }
                      },
                icon: const Icon(Icons.delete_outline),
                label: const LocalizedText('Delete selected object'),
              ),
            ],
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _busy ? null : _fillForms,
              icon: const Icon(Icons.edit_document),
              label: const LocalizedText('Fill interactive PDF forms'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _correctScannedText,
              icon: const Icon(Icons.document_scanner_outlined),
              label: const LocalizedText(
                'OCR and correct scanned Sinhala text',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _pageTools,
              icon: const Icon(Icons.view_module_outlined),
              label: const LocalizedText(
                'Page thumbnails / insert / delete / crop / split',
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _redact,
              icon: const Icon(Icons.security_outlined),
              label: const LocalizedText('Permanent redaction'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _replaceText,
              icon: const Icon(Icons.find_replace),
              label: const LocalizedText('Replace all matches across the PDF'),
            ),
            OutlinedButton.icon(
              onPressed: _busy ? null : _addText,
              icon: const Icon(Icons.text_fields),
              label: const LocalizedText(
                'Add selectable text with font and alignment',
              ),
            ),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(14),
                child: LocalizedText(
                  'Text boxes support Sinhala and English, wrapping, fonts, bold, size, color and alignment. Saved boxes can be selected and edited again. Review scanned-text corrections before saving a copy.',
                ),
              ),
            ),
          ],
        );
      },
    ),
  );

  Widget _numberField(String label, TextEditingController controller) =>
      Expanded(
        child: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
            decimal: true,
            signed: true,
          ),
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
          ),
        ),
      );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(13),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, size: 19, color: theme.colorScheme.primary),
            ),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 9,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
