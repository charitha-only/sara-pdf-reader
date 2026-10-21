import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

class AppPreferences {
  static Future<void> _queue = Future.value();
  static Future<File> file() async {
    final folder = await getApplicationSupportDirectory();
    await folder.create(recursive: true);
    return File('${folder.path}${Platform.pathSeparator}settings.json');
  }

  static Future<Map<String, dynamic>> read() async {
    try {
      final f = await file();
      if (await f.exists()) {
        return Map<String, dynamic>.from(jsonDecode(await f.readAsString()));
      }
    } catch (_) {}
    return {};
  }

  static Future<void> write(Map<String, dynamic> changes) {
    final next = _queue.then((_) async {
      final values = (await read())..addAll(changes);
      final target = await file();
      final temporary = File('${target.path}.tmp');
      await temporary.writeAsString(jsonEncode(values), flush: true);
      await temporary.rename(target.path);
    });
    _queue = next.catchError((Object error) {});
    return next;
  }
}

class AppLanguage extends ValueNotifier<String> {
  AppLanguage._() : super('en');
  static final instance = AppLanguage._();
  Future<void> load() async {
    final saved = await AppPreferences.read();
    value = saved['language'] == 'si' ? 'si' : 'en';
  }

  Future<void> choose(String language) async {
    if (!['en', 'si'].contains(language)) return;
    value = language;
    await AppPreferences.write({'language': language});
  }
}

String tr(String english) {
  if (AppLanguage.instance.value != 'si') return english;
  final translated = _sinhala[english] ?? _moreSinhala[english];
  if (translated != null) return translated;
  final page = RegExp(r'^Page (\d+)$').firstMatch(english);
  if (page != null) return 'පිටුව ${page[1]}';
  final count = RegExp(r'^PAGE (\d+) OF (\d+)$').firstMatch(english);
  if (count != null) return 'පිටුව ${count[1]} / ${count[2]}';
  return english;
}

const _moreSinhala = <String, String>{
  'Display options': 'තිර විකල්ප',
  'Full screen': 'සම්පූර්ණ තිරය',
  'Keep screen on': 'තිරය සක්‍රියව තබන්න',
  'Automatic rotation': 'ස්වයංක්‍රීය තිර හැරවීම',
  'Lock portrait': 'සිරස් දිශාවට අගුළු දමන්න',
  'Lock landscape': 'තිරස් දිශාවට අගුළු දමන්න',
  'Book contents': 'පොතේ පටුන',
  'Find in book': 'පොතේ සොයන්න',
  'Book appearance': 'පොතේ පෙනුම',
  'Line spacing': 'පේළි අතර ඉඩ',
  'Folder and tags': 'ෆෝල්ඩරය සහ ටැග්',
  'All folders': 'සියලු ෆෝල්ඩර',
  'Unfiled': 'ෆෝල්ඩරයක් නැති',
  'Document contents': 'ලේඛන පටුන',
  'Read / search scanned text': 'ස්කෑන් කළ පෙළ කියවන්න / සොයන්න',
  'Scanned PDF text': 'ස්කෑන් කළ PDF පෙළ',
  'Copy recognized text': 'හඳුනාගත් පෙළ පිටපත් කරන්න',
  'Sinhala + English': 'සිංහල සහ ඉංග්‍රීසි',
  'Read all pages': 'සියලු පිටු කියවන්න',
  'Previous chapter': 'පෙර පරිච්ඡේදය',
  'Next chapter': 'ඊළඟ පරිච්ඡේදය',

  'Read Document': 'ගොනුව කියවන්න',
  'Find in document': 'ගොනුව තුළ සොයන්න',
  'Share original file': 'මුල් ගොනුව බෙදාගන්න',
  'Preparing preview…': 'පෙරදසුන සකස් කරමින්…',
  'Read PDFs, Office documents and images\nprivately on your device.':
      'PDF, Office ගොනු සහ පින්තූර\nඔබේ උපාංගයේම කියවන්න.',
  'Add area': 'ප්‍රදේශය එක් කරන්න',
  'Add selectable text with font and alignment':
      'අකුරු සහ පෙළගැස්ම සමඟ පෙළ එක් කරන්න',
  'Add text to this page': 'මෙම පිටුවට පෙළ එක් කරන්න',
  'Bookmarked pages': 'සලකුණු කළ පිටු',
  'Choose image': 'රූපයක් තෝරන්න',
  'Clear app PDF copies?': 'යෙදුමේ PDF පිටපත් මකන්නද?',
  'Clear page areas': 'පිටුවේ තේරීම් ඉවත් කරන්න',
  'Clear search': 'සෙවුම ඉවත් කරන්න',
  'Convert selectable text to Excel': 'පෙළ Excel ගොනුවකට හරවන්න',
  'Convert selectable text to PowerPoint': 'පෙළ PowerPoint ගොනුවකට හරවන්න',
  'Convert selectable text to Word': 'පෙළ Word ගොනුවකට හරවන්න',
  'Copy extracted text': 'හඳුනාගත් පෙළ පිටපත් කරන්න',
  'Correct scanned Sinhala text': 'පරිලෝකනය කළ සිංහල පෙළ නිවැරදි කරන්න',
  'Crop page': 'පිටුව කපන්න',
  'Delete selected object': 'තෝරාගත් වස්තුව මකන්න',
  'Delete this PDF object?': 'මෙම PDF වස්තුව මකන්නද?',
  'Discard': 'අත්හරින්න',
  'Document details': 'ලේඛනයේ විස්තර',
  'Edit Document': 'ලේඛනය වෙනස් කරන්න',
  'Edit Tools': 'සංස්කරණ මෙවලම්',
  'Edit pages and save a copy': 'පිටු වෙනස් කර පිටපතක් සුරකින්න',
  'Edit selected text / font / style':
      'තෝරාගත් පෙළ, අකුරු සහ පෙනුම වෙනස් කරන්න',
  'Export current page as JPEG': 'මෙම පිටුව JPEG ලෙස සුරකින්න',
  'Export current page as PNG': 'මෙම පිටුව PNG ලෙස සුරකින්න',
  'Export extracted text as CSV': 'හඳුනාගත් පෙළ CSV ලෙස සුරකින්න',
  'Export extracted text as TXT': 'හඳුනාගත් පෙළ TXT ලෙස සුරකින්න',
  'Extracting PDF text…': 'PDF පෙළ හඳුනාගනිමින්…',
  'Finding and replacing text locally…':
      'උපාංගයේ පෙළ සොයා ප්‍රතිස්ථාපනය කරමින්…',
  'Go': 'යන්න',
  'Go to page': 'පිටුවට යන්න',
  'Largest first': 'විශාලතම ගොනු පළමුව',
  'Smallest first': 'කුඩාම ගොනු පළමුව',
  'Make a copy': 'පිටපතක් සාදන්න',
  'Merge this PDF with other PDFs': 'මෙම PDF වෙනත් PDF සමඟ එක් කරන්න',
  'Merging PDFs locally…': 'උපාංගයේ PDF එක් කරමින්…',
  'Move / resize selected object':
      'තෝරාගත් වස්තුව ගෙනයන්න හෝ ප්‍රමාණය වෙනස් කරන්න',
  'Name A–Z': 'නම A–Z',
  'Name Z–A': 'නම Z–A',
  'Newest first': 'අලුත්ම ගොනු පළමුව',
  'Oldest first': 'පැරණිම ගොනු පළමුව',
  'No bookmarks saved.': 'පිටු සලකුණු නැත.',
  'No editable text, image, or vector objects were found on this page.':
      'මෙම පිටුවේ වෙනස් කළ හැකි පෙළ හෝ වස්තු හමු නොවීය.',
  'No text could be recognized in this PDF.':
      'මෙම PDF එකේ පෙළ හඳුනාගත නොහැකි විය.',
  'Noto Sans · Sinhala / English': 'Noto Sans · සිංහල / ඉංග්‍රීසි',
  'Noto Serif · Sinhala / English': 'Noto Serif · සිංහල / ඉංග්‍රීසි',
  'OCR and correct scanned Sinhala text': 'සිංහල අකුරු හඳුනාගෙන නිවැරදි කරන්න',
  'PDF DOCUMENT': 'PDF ලේඛනය',
  'PDF Reader,\nRead All Docs': 'PDF කියවන්න,\nලේඛන බලන්න',
  'Page thumbnails / insert / delete / crop / split':
      'පිටු පෙරදසුන් / එක් කිරීම / මකා දැමීම / කැපීම / වෙන් කිරීම',
  'Permanently redact selected content?': 'තෝරාගත් දත්ත ස්ථිරව ඉවත් කරන්නද?',
  'Preparing a PDF copy of this page…': 'මෙම පිටුවේ PDF පිටපත සකස් කරමින්…',
  'Preparing this page for export…': 'පිටුව අපනයනයට සූදානම් කරමින්…',
  'Read, manage and organize your PDFs\neasily in one place.':
      'ඔබේ PDF එකම තැනක\nකියවා කළමනාකරණය කරන්න.',
  'Reader 👋': 'පාඨකයා 👋',
  'Recent reads': 'මෑත කියවීම්',
  'Recently opened': 'මෑතකදී විවෘත කළ',
  'Remove': 'ඉවත් කරන්න',
  'Remove PDF?': 'PDF ඉවත් කරන්නද?',
  'Remove from app': 'යෙදුමෙන් ඉවත් කරන්න',
  'Remove this app’s stored copies and reset its library':
      'යෙදුමේ පිටපත් මකා පුස්තකාලය නැවත සකසන්න',
  'Remove, reorder, or rotate pages':
      'පිටු ඉවත් කරන්න, පිළිවෙළ වෙනස් කරන්න හෝ කරකවන්න',
  'Rename PDF': 'PDF නම වෙනස් කරන්න',
  'Replace all': 'සියල්ල ප්‍රතිස්ථාපනය කරන්න',
  'Replace all matches across the PDF':
      'PDF එකේ ගැළපෙන සියලු පෙළ ප්‍රතිස්ථාපනය කරන්න',
  'Replace an image or area on this page':
      'මෙම පිටුවේ රූපයක් හෝ ප්‍රදේශයක් ප්‍රතිස්ථාපනය කරන්න',
  'Replace existing text on this page': 'මෙම පිටුවේ පෙළ ප්‍රතිස්ථාපනය කරන්න',
  'Replace selectable PDF text': 'තෝරාගත හැකි PDF පෙළ ප්‍රතිස්ථාපනය කරන්න',
  'Replace text on this page': 'මෙම පිටුවේ පෙළ ප්‍රතිස්ථාපනය කරන්න',
  'Replacement color': 'නව වර්ණය',
  'Replacing the selected area locally…': 'තෝරාගත් ප්‍රදේශය වෙනස් කරමින්…',
  'Reset zoom to fit page': 'විශාලනය පිටුවට ගළපන්න',
  'Retry': 'නැවත උත්සාහ කරන්න',
  'Review edited page': 'වෙනස් කළ පිටුව පරීක්ෂා කරන්න',
  'Save current page as a PDF image': 'මෙම පිටුව PDF රූපයක් ලෙස සුරකින්න',
  'See all': 'සියල්ල බලන්න',
  'Select the area to replace': 'ප්‍රතිස්ථාපනය කළ යුතු ප්‍රදේශය තෝරන්න',
  'Share PDF': 'PDF බෙදාගන්න',
  'Text size': 'අකුරු ප්‍රමාණය',
  'YOUR DOCUMENTS, IN ONE PLACE': 'ඔබේ ලේඛන එකම තැනක',
  'This PDF has no interactive form fields.':
      'මෙම PDF එකේ පිරවිය හැකි පෝරම කොටස් නැත.',
  'This document is stored and processed on this device.':
      'මෙම ලේඛනය උපාංගයේ ගබඩා කර සැකසෙයි.',
  'This embedded image could not be displayed.': 'මෙම රූපය පෙන්විය නොහැකි විය.',
  'This removes the selected content object from this page.':
      'මෙම පිටුවේ තෝරාගත් වස්තුව ඉවත් කරයි.',
  'This removes the selected copies from this app and its library.':
      'තෝරාගත් පිටපත් යෙදුමෙන් සහ පුස්තකාලයෙන් ඉවත් කරයි.',
  'Save a new copy, or replace the original in this app’s library.':
      'නව පිටපතක් සුරකින්න හෝ යෙදුමේ පුස්තකාල පිටපත ප්‍රතිස්ථාපනය කරන්න.',
  'The current library copy will be overwritten. The file you originally picked from your device is kept.': 'පුස්තකාල පිටපත වෙනුවට වෙනස්කම් සුරකියි. උපාංගයෙන් තෝරාගත් මුල් ගොනුව තබා ගනියි.',
  'Correct OCR mistakes and arrange paragraphs here. Exported text is editable. Tables, fonts and page layout can differ from the PDF.': 'හඳුනාගත් අකුරුවල වැරදි නිවැරදි කර ඡේද සකසන්න. අපනයනය කළ පෙළ වෙනස් කළ හැකිය. වගු, අකුරු සහ පිටු සැලැස්ම වෙනස් විය හැකිය.',
  'Editable text lets you review and correct extracted text. Preserve appearance embeds page images; text in those images is not editable.': 'වෙනස් කළ හැකි පෙළ පරීක්ෂා කර නිවැරදි කළ හැකිය. මුල් පෙනුම රැකීමේ විකල්පය පිටු රූප යොදයි; ඒ රූපවල පෙළ වෙනස් කළ නොහැකිය.',
  'Apply field changes, then save the PDF from the editor. Read-only and unsupported fields are shown without editing.': 'පෝරමයේ වෙනස්කම් යොදා සංස්කාරකයෙන් PDF සුරකින්න. කියවීමට පමණක් සහ සහය නොදක්වන කොටස් වෙනස් කළ නොහැකිය.',
  'Drag over sensitive content. Add areas on other pages, then apply redaction.': 'සංවේදී දත්ත මත ප්‍රදේශයක් තෝරන්න. වෙනත් පිටුවලත් තෝරා ස්ථිර ඉවත් කිරීම යොදන්න.',
  'Tap a recognized line, or drag over an area to type a correction. Review OCR text before saving.': 'හඳුනාගත් පේළියක් තෝරන්න හෝ ප්‍රදේශයක් ඇඳ නිවැරදි පෙළ ලියන්න. සුරැකීමට පෙර පෙළ පරීක්ෂා කරන්න.',
  'No text was recognized. Drag a region and enter the text manually, or try a clearer scan.': 'පෙළ හඳුනාගත නොහැකි විය. ප්‍රදේශයක් තෝරා පෙළ ලියන්න හෝ පැහැදිලි පිටුවක් භාවිත කරන්න.',
  'Text wraps to the box width. Increase the box height if it does not fit. Positions are measured from the bottom-left of the page.': 'පෙළ කොටුවේ පළලට ගළපයි. නොගැළපේ නම් උස වැඩි කරන්න. පිහිටීම පිටුවේ පහළ වම් කෙළවරෙන් මනියි.',
};
const _sinhala = <String, String>{
  'Get Started': 'ආරම්භ කරන්න',
  'Cancel': 'අවලංගු කරන්න',
  'Apply': 'යොදන්න',
  'Continue': 'ඉදිරියට',
  'Save': 'සුරකින්න',
  'Delete': 'මකන්න',
  'Close': 'වසන්න',
  'Settings & privacy': 'සැකසුම් සහ පෞද්ගලිකත්වය',
  'Dark mode': 'අඳුරු පෙනුම',
  'Save this appearance on this device': 'මෙම පෙනුම උපාංගයේ සුරකින්න',
  'App storage': 'යෙදුමේ ගබඩාව',
  'Back up library': 'පුස්තකාල උපස්ථයක් සාදන්න',
  'Restore backup': 'උපස්ථය යළි පිහිටුවන්න',
  'Save documents, bookmarks and reading progress':
      'ලේඛන, පිටු සලකුණු සහ කියවීමේ ප්‍රගතිය සුරකින්න',
  'Recover app copies and reading data; keep existing files':
      'පවතින ගොනු තබා උපස්ථයේ ලේඛන සහ කියවීමේ දත්ත ලබා ගන්න',
  'Language': 'භාෂාව',
  'English': 'ඉංග්‍රීසි',
  'Sinhala': 'සිංහල',
  'Private, on-device files': 'උපාංගයේ පමණක් පවතින පෞද්ගලික ගොනු',
  'Sinhala OCR available offline': 'අන්තර්ජාලය නොමැතිව සිංහල අකුරු හඳුනාගැනීම',
  'Sharing': 'බෙදාගැනීම',
  'Clear app PDF copies': 'යෙදුමේ PDF පිටපත් මකන්න',
  'Clear app copies': 'යෙදුමේ පිටපත් මකන්න',
  'Documents': 'ලේඛන',
  'All': 'සියල්ල',
  'Favorites': 'ප්‍රියතම',
  'Recent': 'මෑත ලේඛන',
  'Import PDF': 'PDF ගෙන එන්න',
  'Import files': 'ගොනු ගෙන එන්න',
  'Search': 'සොයන්න',
  'Find in document': 'ලේඛනයේ සොයන්න',
  'Bookmarks': 'පිටු සලකුණු',
  'Bookmark this page': 'මෙම පිටුව සලකුණු කරන්න',
  'Remove bookmark': 'පිටු සලකුණ ඉවත් කරන්න',
  'Reading options': 'කියවීමේ විකල්ප',
  'Fit width': 'පළලට ගළපන්න',
  'Fit page': 'සම්පූර්ණ පිටුව ගළපන්න',
  'Sepia reading': 'සැහැල්ලු දුඹුරු කියවීම',
  'Normal colors': 'සාමාන්‍ය වර්ණ',
  'PDF object editor': 'PDF සංස්කාරකය',
  'Edit PDF objects and text': 'PDF වස්තු සහ පෙළ වෙනස් කරන්න',
  'Save PDF': 'PDF සුරකින්න',
  'Save copy': 'පිටපතක් සුරකින්න',
  'Replace library original': 'පුස්තකාලයේ මුල් පිටපත වෙනුවට සුරකින්න',
  'Replace': 'ප්‍රතිස්ථාපනය කරන්න',
  'Replace the library PDF?': 'පුස්තකාලයේ PDF පිටපත ප්‍රතිස්ථාපනය කරන්නද?',
  'Fill PDF forms': 'PDF පෝරම පුරවන්න',
  'Fill interactive PDF forms': 'PDF පෝරම පුරවන්න',
  'Pages and split PDF': 'පිටු සහ PDF වෙන් කිරීම',
  'Insert PDF': 'PDF පිටු ඇතුළත් කරන්න',
  'Delete selected': 'තෝරාගත් පිටු මකන්න',
  'Crop selected page': 'තෝරාගත් පිටුව කපන්න',
  'Split PDF': 'PDF වෙන් කරන්න',
  'Permanent redaction': 'සංවේදී දත්ත ස්ථිරව ඉවත් කරන්න',
  'Redact': 'ස්ථිරව ඉවත් කරන්න',
  'Review text before export': 'අපනයනයට පෙර පෙළ පරීක්ෂා කරන්න',
  'Export': 'අපනයනය',
  'Office export': 'Office අපනයනය',
  'Editable text': 'වෙනස් කළ හැකි පෙළ',
  'Preserve appearance': 'මුල් පෙනුම රකින්න',
  'Apply changes': 'වෙනස්කම් යොදන්න',
  'Add text': 'පෙළ එක් කරන්න',
  'Bold': 'තද අකුරු',
  'Left': 'වම',
  'Center': 'මැද',
  'Right': 'දකුණ',
  'Preparing…': 'සූදානම් කරමින්…',
  'Stopping after the current step…': 'දැනට සිදුවන පියවරෙන් පසු නවත්වමින්…',
  'Reading text / Sinhala OCR': 'පෙළ සහ සිංහල අකුරු හඳුනාගැනීම',
  'Preparing Office export': 'Office ගොනුව සකස් කරමින්',
  'Exporting Office layout': 'Office පෙනුම අපනයනය කරමින්',
  'Backing up library': 'පුස්තකාලය උපස්ථ කරමින්',
  'Restoring library': 'පුස්තකාලය යළි පිහිටුවමින්',
  'Recognizing scanned Sinhala text': 'පරිලෝකනය කළ සිංහල පෙළ හඳුනාගනිමින්',
  'Open-source licenses': 'විවෘත මූලාශ්‍ර බලපත්‍ර',
  'Privacy': 'පෞද්ගලිකත්වය',
  'Document password': 'ලේඛනයේ මුරපදය',
  'Password': 'මුරපදය',
  'Unlock': 'විවෘත කරන්න',
};

class LocalizedText extends StatelessWidget {
  const LocalizedText(
    this.text, {
    super.key,
    this.style,
    this.textAlign,
    this.maxLines,
    this.overflow,
    this.softWrap,
    this.textDirection,
    this.textScaler,
    this.semanticsLabel,
  });
  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;
  final bool? softWrap;
  final TextDirection? textDirection;
  final TextScaler? textScaler;
  final String? semanticsLabel;
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: AppLanguage.instance,
    builder: (_, language, _) => Text(
      tr(text),
      style: style,
      textAlign: textAlign,
      maxLines: maxLines,
      overflow: overflow,
      softWrap: softWrap,
      textDirection: textDirection,
      textScaler: textScaler,
      semanticsLabel: semanticsLabel,
    ),
  );
}

class LanguageChoice extends StatelessWidget {
  const LanguageChoice({super.key});
  @override
  Widget build(BuildContext context) => ValueListenableBuilder<String>(
    valueListenable: AppLanguage.instance,
    builder: (context, language, _) => ListTile(
      title: const LocalizedText('Language'),
      trailing: DropdownButton<String>(
        value: language,
        items: const [
          DropdownMenuItem(value: 'en', child: Text('English')),
          DropdownMenuItem(value: 'si', child: Text('සිංහල')),
        ],
        onChanged: (value) async {
          if (value == null) return;
          try {
            await AppLanguage.instance.choose(value);
          } catch (error) {
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Could not save language: $error')),
              );
            }
          }
        },
      ),
    ),
  );
}
