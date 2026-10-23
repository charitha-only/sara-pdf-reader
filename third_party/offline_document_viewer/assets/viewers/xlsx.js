/* xlsx kabuğunun mantığı.
 *
 * Bilerek ayrı bir dosya: satır içi `<script>` blokları sıkı CSP altında
 * (`script-src 'self'`, `'unsafe-inline'` yok) çalışmıyor. CSP'yi gevşetmek
 * yerine kodu dışarı aldık — hem politika sıkı kalıyor hem kabuk okunur
 * oluyor. Harici scriptler yükleniyor ama satır içi olan sessizce
 * bloklanıyordu; teşhisi zor bir hataydı, tekrar etmemesi için bu not burada.
 */
(function () {
  'use strict';

  const stage = document.getElementById('stage');
  const tabs = document.getElementById('tabs');
  let sheets = [];
  let currentSheet = 0;
  let fullSheet = false;
  let viewMode = 'width';
  Bridge.on('viewMode', function(payload) { viewMode = payload.mode; fitToWidth(); });

  /* Spreadsheets are authored for paper, not phones: official forms in
     particular use dozens of narrow columns, so the used range is often three
     or four times the viewport. Left unscaled the sheet reads as broken —
     content pushed off to the right, columns apparently misaligned, borders
     and fills technically present but impossible to take in.

     Scaling preserves every relationship in the sheet and keeps pinch-zoom
     available. The floor stops a very wide sheet from becoming unreadably
     small; past that it scrolls. */
  const MIN_SCALE = 0.0001;

  function fitToWidth() {
    const content = stage.querySelector('.sheet-content');
    if (!content) return;
    content.style.transform = ''; content.style.zoom = '1'; stage.style.height = '';
    const available = stage.clientWidth, natural = content.scrollWidth;
    if (!available || !natural) return;
    const requested = viewMode === 'actual' ? 1 : Number(viewMode);
    const scale = requested > 0 ? Math.max(.5, Math.min(3, requested)) : Math.min(1, available / natural);
    content.style.zoom = String(scale);
    stage.style.height = Math.ceil(content.getBoundingClientRect().height) + 'px';
    stage.style.overflowX = 'auto'; stage.style.overflowY = 'hidden';
  }

  function show(index) {
    const sheet = sheets[index];
    if (!sheet) {
      return;
    }
    currentSheet = index;
    stage.innerHTML = '<div class="sheet-content">' + (!fullSheet && sheet.printHtml ? sheet.printHtml : sheet.html) + '</div>';
    rangeToggle.hidden = !sheet.printHtml;
    rangeToggle.textContent = fullSheet ? 'Show print range (' + sheet.printArea + ')' : 'Show full sheet';
    const table = stage.querySelector('table.sheet');
    const content = stage.querySelector('.sheet-content');
    if (table && content) content.style.width = Math.max(table.offsetWidth, sheet.html.includes('reader-chart') ? 640 : 0) + 'px';
    if (sheet.unsupportedCharts) {
      const note = document.createElement('p'); note.textContent = 'Some chart types are not supported.'; content.appendChild(note);
    }
    fitToWidth();
    highlightCells();
    Array.prototype.forEach.call(tabs.children, function (button, i) {
      button.setAttribute('aria-selected', String(i === index));
    });
    Bridge.send('located', { index: index, label: sheet.name });
  }

  function buildTabs() {
    tabs.innerHTML = '';
    if (sheets.length < 2) {
      return;
    }
    sheets.forEach(function (sheet, i) {
      const button = document.createElement('button');
      button.type = 'button';
      button.setAttribute('role', 'tab');
      button.textContent = sheet.name;
      button.addEventListener('click', function () {
        show(i);
      });
      tabs.appendChild(button);
    });
  }

  async function render(bytes) {
    const started = performance.now();
    const result = await XlsxRender.render(
      bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)
    );

    await document.fonts.ready;
    sheets = result.sheets;
    buildTabs();
    show(0);

    // Rotation and split-view change the available width.
    window.addEventListener('resize', fitToWidth);

    Bridge.send('rendered', {
      ms: Math.round(performance.now() - started),
      units: sheets.length,
      styled: result.styled,
      truncated: sheets.some(function (sheet) {
        return sheet.truncated;
      }),
      outline: sheets.map(function (sheet) {
        return sheet.name;
      })
    });
  }

  Bridge.on('goto', function (payload) {
    show(payload.index);
  });

  let results = [], searchQuery = '', resultIndex = -1;
  function highlightCells() {
    stage.querySelectorAll('td').forEach(function(cell) {
      cell.classList.toggle('hit', !!searchQuery && cell.textContent.toLowerCase().includes(searchQuery));
    });
  }
  Bridge.on('search', function(payload) {
    searchQuery = (payload.query || '').toLowerCase();
    if (searchQuery && !fullSheet) { fullSheet = true; show(currentSheet); }
    results = []; resultIndex = -1;
    if (searchQuery) sheets.forEach(function(sheet, sheetIndex) {
      const template = document.createElement('template'); template.innerHTML = sheet.html;
      template.content.querySelectorAll('td').forEach(function(cell, cellIndex) {
        if (results.length < 2000 && cell.textContent.toLowerCase().includes(searchQuery)) results.push({sheet:sheetIndex, cell:cellIndex});
      });
    });
    highlightCells();
    Bridge.send('searchResult', {hits:results.length});
    Bridge.send('searchIndex', {index:-1});
  });
  Bridge.on('searchMove', function(payload) {
    if (!results.length) return;
    if (resultIndex < 0 && payload.direction < 0) resultIndex = 0;
    resultIndex = (resultIndex + (payload.direction < 0 ? -1 : 1) + results.length) % results.length;
    const result = results[resultIndex];
    if (currentSheet !== result.sheet || !fullSheet) { fullSheet = true; show(result.sheet); }
    highlightCells();
    const cell = stage.querySelectorAll('td')[result.cell];
    if (cell) { cell.style.outline = '3px solid #d85b00'; cell.scrollIntoView({block:'center', inline:'center'}); }
    Bridge.send('searchIndex', {index:resultIndex});
  });

  const rangeToggle = document.createElement('button'); rangeToggle.type = 'button'; rangeToggle.hidden = true;
  rangeToggle.addEventListener('click', function() { fullSheet = !fullSheet; show(currentSheet); });
  const navigation = document.createElement('form');
  navigation.className = 'cell-navigation';
  const address = document.createElement('input'); address.placeholder = 'Cell address, e.g. A25'; address.maxLength = 12; address.setAttribute('aria-label','Go to cell');
  const go = document.createElement('button'); go.type = 'submit'; go.textContent = 'Go';
  const status = document.createElement('span'); status.setAttribute('role','status');
  navigation.append(address,go,rangeToggle,status); tabs.after(navigation);
  navigation.addEventListener('submit', function(event) {
    event.preventDefault(); const ref=address.value.trim().toUpperCase();
    if(!/^[A-Z]{1,3}[1-9][0-9]{0,5}$/.test(ref)){status.textContent='Enter a cell such as A25.';return;}
    if (!fullSheet) { fullSheet = true; show(currentSheet); }
    const cell=stage.querySelector('[data-cell="'+ref+'"]');
    if(cell){cell.scrollIntoView({block:'center',inline:'center'});cell.style.outline='3px solid #d85b00';status.textContent=ref;}
    else status.textContent='Cell is empty, merged, or outside the preview limit.';
  });
  Bridge.start(render);
})();
