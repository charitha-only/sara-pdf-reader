import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';
import 'package:pdfium_dart/pdfium_dart.dart' as p;

class PdfFormField {
  const PdfFormField({
    required this.page,
    required this.index,
    required this.name,
    required this.type,
    required this.value,
    required this.checked,
    required this.readOnly,
  });
  final int page, index, type;
  final String name, value;
  final bool checked, readOnly;
  bool get supported =>
      type == p.FPDF_FORMFIELD_TEXTFIELD || type == p.FPDF_FORMFIELD_CHECKBOX;
}

/// All callbacks execute on the same PDFium worker that owns the document.
class PdfFormEnvironment {
  PdfFormEnvironment(this.api, this.document) {
    info.ref.version = 1;
    getPage =
        ffi.NativeCallable<
          ffi.Pointer<p.fpdf_page_t__> Function(
            ffi.Pointer<p.FPDF_FORMFILLINFO>,
            ffi.Pointer<p.fpdf_document_t__>,
            ffi.Int,
          )
        >.isolateLocal(
          (
            ffi.Pointer<p.FPDF_FORMFILLINFO> self,
            p.FPDF_DOCUMENT doc,
            int index,
          ) => page(index),
        );
    currentPage =
        ffi.NativeCallable<
          ffi.Pointer<p.fpdf_page_t__> Function(
            ffi.Pointer<p.FPDF_FORMFILLINFO>,
            ffi.Pointer<p.fpdf_document_t__>,
          )
        >.isolateLocal(
          (ffi.Pointer<p.FPDF_FORMFILLINFO> self, p.FPDF_DOCUMENT doc) =>
              page(0),
        );
    rotation =
        ffi.NativeCallable<
          ffi.Int Function(
            ffi.Pointer<p.FPDF_FORMFILLINFO>,
            ffi.Pointer<p.fpdf_page_t__>,
          )
        >.isolateLocal(
          (ffi.Pointer<p.FPDF_FORMFILLINFO> self, p.FPDF_PAGE pg) =>
              api.FPDFPage_GetRotation(pg),
          exceptionalReturn: 0,
        );
    invalidate =
        ffi.NativeCallable<
          ffi.Void Function(
            ffi.Pointer<p.FPDF_FORMFILLINFO>,
            ffi.Pointer<p.fpdf_page_t__>,
            ffi.Double,
            ffi.Double,
            ffi.Double,
            ffi.Double,
          )
        >.isolateLocal(
          (
            ffi.Pointer<p.FPDF_FORMFILLINFO> self,
            p.FPDF_PAGE pg,
            double l,
            double t,
            double r,
            double b,
          ) {},
        );
    cursor =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<p.FPDF_FORMFILLINFO>, ffi.Int)
        >.isolateLocal((ffi.Pointer<p.FPDF_FORMFILLINFO> self, int value) {});
    change =
        ffi.NativeCallable<
          ffi.Void Function(ffi.Pointer<p.FPDF_FORMFILLINFO>)
        >.isolateLocal((ffi.Pointer<p.FPDF_FORMFILLINFO> self) {});
    info.ref
      ..FFI_GetPage = getPage.nativeFunction
      ..FFI_GetCurrentPage = currentPage.nativeFunction
      ..FFI_GetRotation = rotation.nativeFunction
      ..FFI_Invalidate = invalidate.nativeFunction
      ..FFI_OutputSelectedRect = invalidate.nativeFunction
      ..FFI_SetCursor = cursor.nativeFunction
      ..FFI_OnChange = change.nativeFunction;
    handle = api.FPDFDOC_InitFormFillEnvironment(document, info);
    if (handle == ffi.nullptr) {
      throw StateError('Could not initialize PDF form fields.');
    }
  }
  final p.PDFium api;
  final p.FPDF_DOCUMENT document;
  final info = calloc<p.FPDF_FORMFILLINFO>();
  final pages = <int, p.FPDF_PAGE>{};
  p.FPDF_FORMHANDLE handle = ffi.nullptr;
  late final ffi.NativeCallable<
    ffi.Pointer<p.fpdf_page_t__> Function(
      ffi.Pointer<p.FPDF_FORMFILLINFO>,
      ffi.Pointer<p.fpdf_document_t__>,
      ffi.Int,
    )
  >
  getPage;
  late final ffi.NativeCallable<
    ffi.Pointer<p.fpdf_page_t__> Function(
      ffi.Pointer<p.FPDF_FORMFILLINFO>,
      ffi.Pointer<p.fpdf_document_t__>,
    )
  >
  currentPage;
  late final ffi.NativeCallable<
    ffi.Int Function(
      ffi.Pointer<p.FPDF_FORMFILLINFO>,
      ffi.Pointer<p.fpdf_page_t__>,
    )
  >
  rotation;
  late final ffi.NativeCallable<
    ffi.Void Function(
      ffi.Pointer<p.FPDF_FORMFILLINFO>,
      ffi.Pointer<p.fpdf_page_t__>,
      ffi.Double,
      ffi.Double,
      ffi.Double,
      ffi.Double,
    )
  >
  invalidate;
  late final ffi.NativeCallable<
    ffi.Void Function(ffi.Pointer<p.FPDF_FORMFILLINFO>, ffi.Int)
  >
  cursor;
  late final ffi.NativeCallable<
    ffi.Void Function(ffi.Pointer<p.FPDF_FORMFILLINFO>)
  >
  change;
  p.FPDF_PAGE page(int index) {
    if (index < 0 || index >= api.FPDF_GetPageCount(document)) {
      return ffi.nullptr;
    }
    if (pages.containsKey(index)) return pages[index]!;
    final pg = api.FPDF_LoadPage(document, index);
    if (pg == ffi.nullptr) return pg;
    pages[index] = pg;
    if (handle != ffi.nullptr) api.FORM_OnAfterLoadPage(pg, handle);
    return pg;
  }

  String _string(p.FPDF_ANNOTATION annot, {bool name = false}) {
    final count = name
        ? api.FPDFAnnot_GetFormFieldName(handle, annot, ffi.nullptr, 0)
        : api.FPDFAnnot_GetFormFieldValue(handle, annot, ffi.nullptr, 0);
    if (count < 2 || count > 65536) return '';
    final buffer = calloc<ffi.Uint16>(count ~/ 2);
    try {
      if (name) {
        api.FPDFAnnot_GetFormFieldName(handle, annot, buffer.cast(), count);
      } else {
        api.FPDFAnnot_GetFormFieldValue(handle, annot, buffer.cast(), count);
      }
      return String.fromCharCodes(
        buffer.asTypedList(count ~/ 2).takeWhile((c) => c != 0),
      );
    } finally {
      calloc.free(buffer);
    }
  }

  List<PdfFormField> fields() {
    final output = <PdfFormField>[];
    for (var number = 0; number < api.FPDF_GetPageCount(document); number++) {
      final pg = page(number);
      if (pg == ffi.nullptr) continue;
      for (var i = 0; i < api.FPDFPage_GetAnnotCount(pg); i++) {
        final annot = api.FPDFPage_GetAnnot(pg, i);
        if (annot == ffi.nullptr) continue;
        try {
          final type = api.FPDFAnnot_GetFormFieldType(handle, annot);
          if (type <= 0) continue;
          output.add(
            PdfFormField(
              page: number + 1,
              index: i,
              name: _string(annot, name: true),
              type: type,
              value: _string(annot),
              checked: api.FPDFAnnot_IsChecked(handle, annot) != 0,
              readOnly:
                  (api.FPDFAnnot_GetFormFieldFlags(handle, annot) & 1) != 0,
            ),
          );
        } finally {
          api.FPDFPage_CloseAnnot(annot);
        }
      }
    }
    return output;
  }

  void fill(int number, int index, {String? text, bool? checked}) {
    final pg = page(number - 1);
    if (pg == ffi.nullptr ||
        index < 0 ||
        index >= api.FPDFPage_GetAnnotCount(pg)) {
      throw RangeError('Invalid form field.');
    }
    final annot = api.FPDFPage_GetAnnot(pg, index);
    try {
      if ((api.FPDFAnnot_GetFormFieldFlags(handle, annot) & 1) != 0) {
        throw StateError('This field is read-only.');
      }
      final type = api.FPDFAnnot_GetFormFieldType(handle, annot);
      if (type == p.FPDF_FORMFIELD_TEXTFIELD) {
        if (text == null || text.length > 4000) {
          throw ArgumentError('Enter at most 4000 characters.');
        }
        if (api.FORM_SetFocusedAnnot(handle, annot) == 0) {
          throw StateError('Could not focus this form field.');
        }
        api.FORM_SelectAllText(handle, pg);
        final wide = calloc<ffi.Uint16>(text.codeUnits.length + 1)
          ..asTypedList(text.codeUnits.length + 1)
              .setRange(0, text.codeUnits.length, text.codeUnits);
        try {
          api.FORM_ReplaceSelection(handle, pg, wide.cast());
        } finally {
          calloc.free(wide);
        }
        api.FORM_ForceToKillFocus(handle);
        if (_string(annot) != text) {
          throw StateError('The field rejected this text.');
        }
      } else if (type == p.FPDF_FORMFIELD_CHECKBOX) {
        if (checked == null) throw ArgumentError('Choose a checkbox state.');
        if ((api.FPDFAnnot_IsChecked(handle, annot) != 0) != checked) {
          final rect = calloc<p.FS_RECTF>();
          try {
            if (api.FPDFAnnot_GetRect(annot, rect) == 0) {
              throw StateError('Could not locate checkbox.');
            }
            final x = (rect.ref.left + rect.ref.right) / 2,
                y = (rect.ref.bottom + rect.ref.top) / 2;
            api.FORM_OnLButtonDown(handle, pg, 0, x, y);
            api.FORM_OnLButtonUp(handle, pg, 0, x, y);
            api.FORM_ForceToKillFocus(handle);
          } finally {
            calloc.free(rect);
          }
        }
        if ((api.FPDFAnnot_IsChecked(handle, annot) != 0) != checked) {
          throw StateError('The checkbox rejected this change.');
        }
      } else {
        throw UnsupportedError(
          'Only standard text fields and checkboxes are editable here.',
        );
      }
    } finally {
      api.FPDFPage_CloseAnnot(annot);
    }
  }

  void dispose() {
    if (handle != ffi.nullptr) {
      api.FORM_ForceToKillFocus(handle);
      for (final pg in pages.values) {
        api.FORM_OnBeforeClosePage(pg, handle);
      }
      api.FPDFDOC_ExitFormFillEnvironment(handle);
    }
    for (final pg in pages.values) {
      api.FPDF_ClosePage(pg);
    }
    pages.clear();
    handle = ffi.nullptr;
    getPage.close();
    currentPage.close();
    rotation.close();
    invalidate.close();
    cursor.close();
    change.close();
    calloc.free(info);
  }
}
