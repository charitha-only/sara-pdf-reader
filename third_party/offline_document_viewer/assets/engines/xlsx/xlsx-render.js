/* xlsx-render — stilli Excel → HTML.
 *
 * SheetJS Community Edition hücrelerden yalnızca DOLGUYU okuyor: kenarlık,
 * font ve hizalama `.s` içine hiç gelmiyor (bunlar Pro özelliği). `sheet_to_html`
 * ise okunan dolguyu bile atıp çıplak tablo basıyor.
 *
 * Bu modül işi bölüyor:
 *   - DEĞER tarafı SheetJS'te kalıyor — sayı biçimi motoru (SSF) ve formül
 *     sonucu okuma konusunda kendi yazacağımdan iyi.
 *   - STİL tarafını doğrudan OOXML'den çıkarıyoruz: xl/styles.xml (cellXfs →
 *     font/fill/border/alignment), xl/theme/theme1.xml (tema renkleri) ve her
 *     sayfanın kendi XML'indeki hücre `s=` indeksleri.
 *
 * Bağımlılık: JSZip v3 + SheetJS (ikisi de sayfada global).
 */
(function (global) {
  'use strict';

  const EMU_PER_PT = 96 / 72;

  /* Excel'in eski 56 renklik indeksli paleti. Modern dosyalar tema renklerini
     kullanıyor ama indexed= hâlâ karşımıza çıkıyor (özellikle .xls kökenli). */
  const INDEXED = [
    '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF',
    '000000', 'FFFFFF', 'FF0000', '00FF00', '0000FF', 'FFFF00', 'FF00FF', '00FFFF',
    '800000', '008000', '000080', '808000', '800080', '008080', 'C0C0C0', '808080',
    '9999FF', '993366', 'FFFFCC', 'CCFFFF', '660066', 'FF8080', '0066CC', 'CCCCFF',
    '000080', 'FF00FF', 'FFFF00', '00FFFF', '800080', '800000', '008080', '0000FF',
    '00CCFF', 'CCFFFF', 'CCFFCC', 'FFFF99', '99CCFF', 'FF99CC', 'CC99FF', 'FFCC99',
    '3366FF', '33CCCC', '99CC00', 'FFCC00', 'FF9900', 'FF6600', '666699', '969696',
    '003366', '339966', '003300', '333300', '993300', '993366', '333399', '333333',
  ];

  /* theme="N" indeksleri clrScheme'deki XML sırasıyla AYNI DEĞİL:
     dosyada dk1,lt1,dk2,lt2,... sırası var ama indeks 0=lt1, 1=dk1 diye başlıyor. */
  const THEME_ORDER = ['lt1', 'dk1', 'lt2', 'dk2', 'accent1', 'accent2',
    'accent3', 'accent4', 'accent5', 'accent6', 'hlink', 'folHlink'];

  const BORDER_CSS = {
    thin: '1px solid', medium: '2px solid', thick: '3px solid',
    dashed: '1px dashed', dotted: '1px dotted', double: '3px double',
    hair: '1px solid', mediumDashed: '2px dashed', dashDot: '1px dashed',
    mediumDashDot: '2px dashed', dashDotDot: '1px dotted',
    mediumDashDotDot: '2px dotted', slantDashDot: '2px dashed',
  };

  const H_ALIGN = {
    left: 'left', center: 'center', right: 'right', justify: 'justify',
    centerContinuous: 'center', distributed: 'justify', fill: 'left',
  };

  const V_ALIGN = { top: 'top', center: 'middle', bottom: 'bottom', justify: 'middle', distributed: 'middle' };

  const parseXml = (text) => new DOMParser().parseFromString(text, 'application/xml');

  const kids = (node, name) =>
    node ? Array.from(node.children).filter((c) => c.localName === name) : [];

  const kid = (node, name) => kids(node, name)[0];

  /* ---- renk çözümleme ------------------------------------------------- */

  function rgbToHsl(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const max = Math.max(r, g, b), min = Math.min(r, g, b);
    const l = (max + min) / 2;
    if (max === min) return [0, 0, l];
    const d = max - min;
    const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    let h;
    if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
    else if (max === g) h = ((b - r) / d + 2) / 6;
    else h = ((r - g) / d + 4) / 6;
    return [h, s, l];
  }

  function hslToRgb(h, s, l) {
    if (s === 0) { const v = Math.round(l * 255); return [v, v, v]; }
    const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
    const p = 2 * l - q;
    const f = (t) => {
      if (t < 0) t += 1;
      if (t > 1) t -= 1;
      if (t < 1 / 6) return p + (q - p) * 6 * t;
      if (t < 1 / 2) return q;
      if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
      return p;
    };
    return [f(h + 1 / 3), f(h), f(h - 1 / 3)].map((v) => Math.round(v * 255));
  }

  /* ECMA-376'nın tint algoritması: negatif tint koyulaştırır, pozitif açar. */
  function applyTint(hex, tint) {
    if (!tint) return hex;
    const n = parseInt(hex, 16);
    const [h, s, l] = rgbToHsl((n >> 16) & 255, (n >> 8) & 255, n & 255);
    const nl = tint < 0 ? l * (1 + tint) : l * (1 - tint) + tint;
    return hslToRgb(h, s, Math.min(1, Math.max(0, nl)))
      .map((v) => v.toString(16).padStart(2, '0')).join('');
  }

  function resolveColor(node, theme) {
    if (!node) return null;
    const rgb = node.getAttribute('rgb');
    const tint = parseFloat(node.getAttribute('tint') || '0');
    if (rgb) {
      // ARGB gelir; alfa kanalını atıyoruz (Excel hücre renginde şeffaflık yok)
      return '#' + applyTint(rgb.length === 8 ? rgb.slice(2) : rgb, tint);
    }
    const themeIdx = node.getAttribute('theme');
    if (themeIdx !== null && theme[+themeIdx]) {
      return '#' + applyTint(theme[+themeIdx], tint);
    }
    const idx = node.getAttribute('indexed');
    if (idx !== null && INDEXED[+idx]) return '#' + applyTint(INDEXED[+idx], tint);
    return null;
  }

  /* ---- theme1.xml ------------------------------------------------------ */

  async function parseTheme(zip) {
    const file = zip.file('xl/theme/theme1.xml');
    if (!file) return [];
    const doc = parseXml(await file.async('string'));
    const scheme = doc.getElementsByTagNameNS('*', 'clrScheme')[0];
    if (!scheme) return [];

    const byName = {};
    Array.from(scheme.children).forEach((c) => {
      const srgb = kid(c, 'srgbClr');
      const sys = kid(c, 'sysClr');
      byName[c.localName] = srgb
        ? srgb.getAttribute('val')
        : (sys ? sys.getAttribute('lastClr') : null);
    });
    return THEME_ORDER.map((n) => byName[n] || '000000');
  }

  /* ---- styles.xml ------------------------------------------------------ */

  async function parseStyles(zip, theme) {
    const file = zip.file('xl/styles.xml');
    if (!file) return { xfs: [] };
    const doc = parseXml(await file.async('string'));
    const root = doc.documentElement;

    const fonts = kids(kid(root, 'fonts'), 'font').map((f) => ({
      bold: !!kid(f, 'b'),
      italic: !!kid(f, 'i'),
      underline: !!kid(f, 'u'),
      strike: !!kid(f, 'strike'),
      size: kid(f, 'sz') ? parseFloat(kid(f, 'sz').getAttribute('val')) : null,
      color: resolveColor(kid(f, 'color'), theme),
      name: kid(f, 'name') ? kid(f, 'name').getAttribute('val') : null,
      vertAlign: kid(f, 'vertAlign') ? kid(f, 'vertAlign').getAttribute('val') : null,
    }));

    const fills = kids(kid(root, 'fills'), 'fill').map((f) => {
      const pf = kid(f, 'patternFill');
      if (!pf) return null;
      const type = pf.getAttribute('patternType');
      if (!type || type === 'none') return null;
      // gray125 gibi desenler için fgColor'u yaklaşık bir zemin olarak kullanıyoruz
      return resolveColor(kid(pf, 'fgColor'), theme) ||
        resolveColor(kid(pf, 'bgColor'), theme);
    });

    const borders = kids(kid(root, 'borders'), 'border').map((b) => {
      const side = (name) => {
        const el = kid(b, name);
        if (!el) return null;
        const style = el.getAttribute('style');
        if (!style || style === 'none') return null;
        const css = BORDER_CSS[style] || '1px solid';
        const color = resolveColor(kid(el, 'color'), theme) || '#000';
        return `${css} ${color}`;
      };
      return {
        left: side('left'), right: side('right'),
        top: side('top'), bottom: side('bottom'),
      };
    });

    const xfs = kids(kid(root, 'cellXfs'), 'xf').map((xf) => {
      const al = kid(xf, 'alignment');
      const on = (attr) => xf.getAttribute(attr) === '1' || xf.getAttribute(attr) === 'true';
      return {
        font: on('applyFont') || xf.getAttribute('fontId') ? fonts[+xf.getAttribute('fontId') || 0] : null,
        fill: fills[+xf.getAttribute('fillId') || 0] || null,
        border: borders[+xf.getAttribute('borderId') || 0] || null,
        align: al ? {
          h: al.getAttribute('horizontal'),
          v: al.getAttribute('vertical'),
          wrap: al.getAttribute('wrapText') === '1',
          indent: parseInt(al.getAttribute('indent') || '0', 10),
          rotation: parseInt(al.getAttribute('textRotation') || '0', 10),
        } : null,
      };
    });

    return { xfs };
  }

  /* ---- sayfa XML'i: hücre stil indeksleri, satırlar, donmuş bölme ------- */

  async function parseSheetLayout(zip, path) {
    const file = zip.file(path);
    if (!file) return { styleAt: {}, rows: {}, freeze: null, gridlines: true };
    const doc = parseXml(await file.async('string'));
    const root = doc.documentElement;

    const styleAt = {};
    const rows = {};
    kids(kid(root, 'sheetData'), 'row').forEach((r) => {
      const idx = r.getAttribute('r');
      const ht = r.getAttribute('ht');
      const hidden = r.getAttribute('hidden') === '1';
      if (ht || hidden) rows[idx] = { height: ht ? parseFloat(ht) * EMU_PER_PT : null, hidden };
      kids(r, 'c').forEach((c) => {
        const s = c.getAttribute('s');
        if (s) styleAt[c.getAttribute('r')] = +s;
      });
    });

    const view = kid(kid(root, 'sheetViews'), 'sheetView');
    const pane = view ? kid(view, 'pane') : null;
    const freeze = pane && pane.getAttribute('state') === 'frozen'
      ? { x: +(pane.getAttribute('xSplit') || 0), y: +(pane.getAttribute('ySplit') || 0) }
      : null;
    const gridlines = !view || view.getAttribute('showGridLines') !== '0';

    return { styleAt, rows, freeze, gridlines };
  }

  /* workbook.xml + rels: sayfa adı → parça yolu */
  async function sheetPaths(zip) {
    const wbFile = zip.file('xl/workbook.xml');
    const relFile = zip.file('xl/_rels/workbook.xml.rels');
    if (!wbFile || !relFile) return {};

    const rels = {};
    Array.from(parseXml(await relFile.async('string'))
      .getElementsByTagNameNS('*', 'Relationship')).forEach((r) => {
        let t = r.getAttribute('Target');
        if (t.startsWith('/')) t = t.slice(1);
        else if (!t.startsWith('xl/')) t = 'xl/' + t;
        rels[r.getAttribute('Id')] = t.replace(/^xl\/\.\.\//, '');
      });

    const out = {};
    Array.from(parseXml(await wbFile.async('string'))
      .getElementsByTagNameNS('*', 'sheet')).forEach((s) => {
        const rid = s.getAttributeNS(
          'http://schemas.openxmlformats.org/officeDocument/2006/relationships', 'id'
        ) || s.getAttribute('r:id');
        if (rels[rid]) out[s.getAttribute('name')] = rels[rid];
      });
    return out;
  }

  /* ---- CSS üretimi ----------------------------------------------------- */

  function cellCss(xf, isNumber, gridlines) {
    if (!xf) return gridlines ? 'border:1px solid #dcdfe4;' : '';
    const p = [];

    if (xf.fill) p.push(`background:${xf.fill}`);

    const f = xf.font;
    if (f) {
      if (f.bold) p.push('font-weight:700');
      if (f.italic) p.push('font-style:italic');
      if (f.strike && f.underline) p.push('text-decoration:underline line-through');
      else if (f.strike) p.push('text-decoration:line-through');
      else if (f.underline) p.push('text-decoration:underline');
      if (f.size) p.push(`font-size:${f.size}pt`);
      if (f.color) p.push(`color:${f.color}`);
      // Tek tırnak şart: bu dizge style="..." içine giriyor, çift tırnak
      // attribute'u erkenden kapatıp arkasındaki her şeyi (kenarlık, hizalama) yutuyor.
      if (f.name) p.push(`font-family:'${f.name.replace(/['\\]/g, '')}',sans-serif`);
      if (f.vertAlign === 'superscript') p.push('vertical-align:super;font-size:smaller');
      if (f.vertAlign === 'subscript') p.push('vertical-align:sub;font-size:smaller');
    }

    const b = xf.border;
    let hasBorder = false;
    if (b) {
      ['top', 'right', 'bottom', 'left'].forEach((side) => {
        if (b[side]) { p.push(`border-${side}:${b[side]}`); hasBorder = true; }
      });
    }
    // Excel'de kenarlığı olmayan hücre, gridline açıksa ince gri çizgiyle görünür
    if (!hasBorder && gridlines) p.push('border:1px solid #dcdfe4');
    else if (!hasBorder) p.push('border:0');

    const a = xf.align;
    const h = a && a.h ? H_ALIGN[a.h] : null;
    // Excel varsayılanı: sayı sağa, metin sola
    p.push(`text-align:${h || (isNumber ? 'right' : 'left')}`);
    if (a) {
      if (a.v) p.push(`vertical-align:${V_ALIGN[a.v] || 'bottom'}`);
      p.push(a.wrap ? 'white-space:pre-wrap' : 'white-space:nowrap');
      if (a.indent) p.push(`padding-left:${4 + a.indent * 9}px`);
      if (a.rotation && a.rotation !== 255) {
        const deg = a.rotation > 90 ? 90 - a.rotation : -a.rotation;
        p.push(`transform:rotate(${deg}deg)`);
      }
    } else {
      p.push('white-space:nowrap');
    }

    return p.join(';') + ';';
  }

  /* ---- ana render ------------------------------------------------------ */

  const colName = (n) => {
    let s = '';
    for (n += 1; n > 0; n = Math.floor((n - 1) / 26)) {
      s = String.fromCharCode(65 + ((n - 1) % 26)) + s;
    }
    return s;
  };

  async function render(arrayBuffer, options) {
    const opts = Object.assign({ maxRows: 3000, maxCols: 200 }, options);
    const bytes = new Uint8Array(arrayBuffer);

    /* Plain-text spreadsheets (CSV/TSV) have no container signature. Handing
       SheetJS raw bytes makes it read them one byte at a time, so UTF-8 text
       arrives as mojibake ("Ürün" → "ÃrÃ¼n"). Decoding explicitly and passing
       a string is deterministic and avoids depending on codepage tables. */
    let isZip = bytes[0] === 0x50 && bytes[1] === 0x4b;
    const isOle = bytes[0] === 0xd0 && bytes[1] === 0xcf;
    let wb;
    if (!isZip && !isOle) {
      let text = new TextDecoder('utf-8').decode(bytes);
      // Strip a byte order mark; SheetJS would treat it as part of the first
      // column name.
      if (text.charCodeAt(0) === 0xfeff) {
        text = text.slice(1);
      }
      wb = XLSX.read(text, { type: 'string', cellDates: true, cellNF: true });
    } else {
      wb = XLSX.read(bytes, {
        type: 'array', cellDates: true, cellNF: true, cellStyles: true,
      });
    }

    // Legacy .xls / .csv zip değil — stil katmanı yok, düz tabloya düşüyoruz
    let styles = { xfs: [] };
    let paths = {};
    if (isZip && global.JSZip) {
      try {
        const zip = await JSZip.loadAsync(arrayBuffer);
        const theme = await parseTheme(zip);
        styles = await parseStyles(zip, theme);
        paths = await sheetPaths(zip);
        var zipRef = zip;
      } catch (e) {
        console.warn('stil katmanı okunamadı, düz tabloya düşülüyor:', e);
        isZip = false;
      }
    }

    const sheets = [];
    for (const name of wb.SheetNames) {
      const ws = wb.Sheets[name];
      const layout = (isZip && paths[name])
        ? await parseSheetLayout(zipRef, paths[name])
        : { styleAt: {}, rows: {}, freeze: null, gridlines: true };

      sheets.push(buildTable(ws, layout, styles, opts, name));
    }

    return {
      sheets,
      styled: isZip && styles.xfs.length > 0,
    };
  }

  function buildTable(ws, layout, styles, opts, name) {
    const ref = ws['!ref'];
    if (!ref) return { name, html: '<p class="empty">boş sayfa</p>', rows: 0, cols: 0, truncated: false };

    const range = XLSX.utils.decode_range(ref);
    const lastRow = Math.min(range.e.r, range.s.r + opts.maxRows - 1);
    const lastCol = Math.min(range.e.c, range.s.c + opts.maxCols - 1);
    const truncated = lastRow < range.e.r || lastCol < range.e.c;

    // birleştirilmiş hücreler: kapsanan hücreleri atla, köşeye span ver
    const spanAt = {};
    const covered = new Set();
    (ws['!merges'] || []).forEach((m) => {
      spanAt[`${m.s.r},${m.s.c}`] = {
        rowspan: m.e.r - m.s.r + 1, colspan: m.e.c - m.s.c + 1,
      };
      for (let r = m.s.r; r <= m.e.r; r++) {
        for (let c = m.s.c; c <= m.e.c; c++) {
          if (r !== m.s.r || c !== m.s.c) covered.add(`${r},${c}`);
        }
      }
    });

    const cols = ws['!cols'] || [];
    const out = ['<table class="sheet"><colgroup>'];
    for (let c = range.s.c; c <= lastCol; c++) {
      const info = cols[c];
      const hidden = info && info.hidden;
      const px = info && (info.wpx || (info.wch && info.wch * 7));
      out.push(`<col style="${hidden ? 'display:none' : (px ? `width:${Math.round(px)}px` : '')}">`);
    }
    out.push('</colgroup><tbody>');

    for (let r = range.s.r; r <= lastRow; r++) {
      const rowInfo = layout.rows[r + 1];
      if (rowInfo && rowInfo.hidden) continue;
      const rowStyle = rowInfo && rowInfo.height ? ` style="height:${Math.round(rowInfo.height)}px"` : '';
      const sticky = layout.freeze && r - range.s.r < layout.freeze.y ? ' class="freeze-row"' : '';
      out.push(`<tr${sticky}${rowStyle}>`);

      for (let c = range.s.c; c <= lastCol; c++) {
        if (covered.has(`${r},${c}`)) continue;
        const addr = colName(c) + (r + 1);
        const cell = ws[addr];
        const xf = styles.xfs[layout.styleAt[addr]];
        const isNumber = !!cell && (cell.t === 'n' || cell.t === 'd');
        const span = spanAt[`${r},${c}`];
        const stickyCol = layout.freeze && c - range.s.c < layout.freeze.x ? ' freeze-col' : '';

        const text = cell
          ? (cell.w != null ? cell.w : (cell.v != null ? String(cell.v) : ''))
          : '';

        out.push('<td');
        if (span) {
          if (span.rowspan > 1) out.push(` rowspan="${span.rowspan}"`);
          if (span.colspan > 1) out.push(` colspan="${span.colspan}"`);
        }
        if (stickyCol) out.push(` class="${stickyCol.trim()}"`);
        if (cell && cell.f) out.push(` title="=${escapeAttr(cell.f)}"`);
        out.push(` style="${cellCss(xf, isNumber, layout.gridlines)}">`);
        out.push(escapeHtml(text));
        out.push('</td>');
      }
      out.push('</tr>');
    }
    out.push('</tbody></table>');

    return {
      name,
      html: out.join(''),
      rows: lastRow - range.s.r + 1,
      cols: lastCol - range.s.c + 1,
      totalRows: range.e.r - range.s.r + 1,
      totalCols: range.e.c - range.s.c + 1,
      truncated,
      frozen: layout.freeze,
    };
  }

  const escapeHtml = (s) => String(s)
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  const escapeAttr = (s) => escapeHtml(s).replace(/"/g, '&quot;');

  global.XlsxRender = { render };
})(window);
