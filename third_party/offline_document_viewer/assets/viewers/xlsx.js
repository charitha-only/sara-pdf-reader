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

  /* Spreadsheets are authored for paper, not phones: official forms in
     particular use dozens of narrow columns, so the used range is often three
     or four times the viewport. Left unscaled the sheet reads as broken —
     content pushed off to the right, columns apparently misaligned, borders
     and fills technically present but impossible to take in.

     Scaling preserves every relationship in the sheet and keeps pinch-zoom
     available. The floor stops a very wide sheet from becoming unreadably
     small; past that it scrolls. */
  const MIN_SCALE = 0.4;

  function fitToWidth() {
    const table = stage.querySelector('table.sheet');
    if (!table) {
      return;
    }
    table.style.transform = '';
    table.style.transformOrigin = 'top left';
    stage.style.height = '';

    const available = stage.clientWidth;
    const natural = table.scrollWidth;
    if (!natural || !available || natural <= available) {
      return;
    }

    const scale = Math.max(MIN_SCALE, available / natural);
    table.style.transform = 'scale(' + scale + ')';
    // A transformed element keeps its layout box, so the container would
    // otherwise reserve the unscaled height.
    stage.style.height = table.offsetHeight * scale + 'px';
  }

  function show(index) {
    const sheet = sheets[index];
    if (!sheet) {
      return;
    }
    stage.innerHTML = sheet.html;
    fitToWidth();
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

  Bridge.on('search', function (payload) {
    // Türkçe'de büyük/küçük harf eşlemesi İ/ı yüzünden yerel ayara duyarlı.
    const query = (payload.query || '').toLocaleLowerCase('tr');
    let hits = 0;
    stage.querySelectorAll('td').forEach(function (cell) {
      cell.classList.remove('hit');
      if (query && cell.textContent.toLocaleLowerCase('tr').indexOf(query) >= 0) {
        cell.classList.add('hit');
        hits++;
      }
    });
    Bridge.send('searchResult', { hits: hits });
  });

  Bridge.start(render);
})();
