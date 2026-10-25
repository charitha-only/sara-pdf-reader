/* docx kabuğunun mantığı.
 *
 * docx-preview bu kopyada üç yama taşıyor (themeFill, themeTint/Shade,
 * `w:val="auto"` tema rengini ezme) — ayrıntı vendor/PATCHES-docx-preview.md.
 */
(function () {
  'use strict';

  const stage = document.getElementById('stage');
  let viewMode = 'width';
  Bridge.on('viewMode', function(payload) { viewMode = payload.mode; fitToWidth(); });

  /* Word sayfası sabit genişlikte (A4 ≈ 794 px); telefon ekranı ~390 px.
     Ölçekleyerek sığdırıyoruz — yatay kaydırma bir belge okuyucuda kabul
     edilemez. Ölçek düzeni bozmuyor, yalnızca küçültüyor; kullanıcı
     yakınlaştırma jestiyle büyütebiliyor. */
  function fitToWidth() {
    const wrapper = stage.querySelector('.docx-wrapper');
    const pages = Array.from(stage.querySelectorAll('.docx-wrapper > section'));
    if (!wrapper || !pages.length) return;
    wrapper.style.transform = ''; wrapper.style.position = ''; wrapper.style.height = ''; wrapper.style.zoom = '1';
    stage.style.height = ''; wrapper.style.width = '';
    const natural = Math.max.apply(null, pages.map(function(page) { return page.offsetWidth; }));
    if (!natural) return;
    const available = document.documentElement.clientWidth;
    const scale = Bridge.fitScale(viewMode, natural, pages[0].offsetHeight, available, Math.max(1, innerHeight - Math.max(0, stage.getBoundingClientRect().top) - 16));
    wrapper.style.width = natural + 'px'; wrapper.style.zoom = String(scale);
    stage.style.height = Math.ceil(wrapper.getBoundingClientRect().height) + 'px';
    stage.style.overflowX = 'auto'; stage.style.overflowY = 'hidden';
  }
  window.addEventListener('resize', fitToWidth);

  /** Anahat için başlıkları toplar — görüntüleyicideki "İçindekiler". */
  function collectOutline() {
    const headings = stage.querySelectorAll('h1, h2, h3');
    const labels = [];
    headings.forEach(function (node, index) {
      const text = (node.textContent || '').trim();
      if (text) {
        node.setAttribute('data-outline', String(index));
        labels.push(text);
      }
    });
    return labels;
  }

  async function render(bytes) {
    const started = performance.now();
    stage.innerHTML = '';

    await docx.renderAsync(bytes, stage, null, {
      className: 'docx',
      inWrapper: true,
      breakPages: true,
      ignoreLastRenderedPageBreak: false,
      experimental: true,
      // Görselleri data URI olarak göm: blob URL'leri sıkı CSP altında
      // engellenebiliyor, data: img-src'de açıkça izinli.
      useBase64URL: true,
      renderHeaders: true,
      renderFooters: true,
      renderEndnotes: true,
      renderFootnotes: true
    });

    // Keep the authored font first; add a Sinhala fallback without replacing
    // the document's Latin font metrics or embedded font faces.
    stage.querySelectorAll('[style]').forEach(function(node) {
      if (node.style.fontFamily && !node.style.fontFamily.includes('Sara Sinhala')) {
        node.style.fontFamily += ', "Sara Sinhala"';
      }
    });
    await document.fonts.ready;
    await Promise.all(Array.from(stage.querySelectorAll('img')).map(img => img.decode ? img.decode().catch(() => {}) : Promise.resolve()));
    stage.querySelectorAll('[data-word-vml-box]').forEach(function(box) {
      const paragraph = box.closest('p');
      if (paragraph) paragraph.style.marginLeft = '0';
    });
    stage.querySelectorAll('table').forEach(function(table) {
      const x = table.style.getPropertyValue('--pageflow-table-x');
      const page = table.closest('section');
      if (!x || !page) return;
      const pageStyle = getComputedStyle(page);
      const inPoints = /pt$/.test(x) ? parseFloat(x) * 96 / 72 : parseFloat(x);
      const anchor = table.style.getPropertyValue('--pageflow-table-anchor');
      const left = inPoints + (anchor.trim() === 'page' ? 0 : parseFloat(pageStyle.paddingLeft));
      table.style.marginRight = Math.max(0, page.offsetWidth - parseFloat(pageStyle.paddingRight) - left - table.offsetWidth) + 'px';
    });
    fitToWidth();
    const outline = collectOutline();

    Bridge.send('rendered', {
      ms: Math.round(performance.now() - started),
      units: stage.querySelectorAll('.docx-wrapper > section').length || 1,
      styled: true,
      outline: outline
    });
  }

  Bridge.on('goto', function (payload) {
    const target = stage.querySelector('[data-outline="' + payload.index + '"]');
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });

  Bridge.on('search', function (payload) {
    const query = (payload.query || '').toLowerCase();

    // Önceki vurguları temizle.
    stage.querySelectorAll('mark.hit').forEach(function (mark) {
      const parent = mark.parentNode;
      parent.replaceChild(document.createTextNode(mark.textContent), mark);
      parent.normalize();
    });

    if (!query) {
      Bridge.send('searchResult', { hits: 0 });
      return;
    }

    let hits = 0;
    const walker = document.createTreeWalker(stage, NodeFilter.SHOW_TEXT);
    const targets = [];
    while (walker.nextNode()) {
      const node = walker.currentNode;
      if (node.nodeValue.toLowerCase().indexOf(query) >= 0) {
        targets.push(node);
      }
    }

    targets.forEach(function (node) {
      const value = node.nodeValue;
      const lower = value.toLowerCase();
      const fragment = document.createDocumentFragment();
      let cursor = 0;
      let found = lower.indexOf(query, cursor);
      while (found >= 0) {
        fragment.appendChild(
          document.createTextNode(value.slice(cursor, found))
        );
        const mark = document.createElement('mark');
        mark.className = 'hit';
        mark.textContent = value.slice(found, found + query.length);
        fragment.appendChild(mark);
        hits++;
        cursor = found + query.length;
        found = lower.indexOf(query, cursor);
      }
      fragment.appendChild(document.createTextNode(value.slice(cursor)));
      node.parentNode.replaceChild(fragment, node);
    });

    const first = stage.querySelector('mark.hit');
    if (first) {
      first.scrollIntoView({ behavior: 'smooth', block: 'center' });
    }
    Bridge.send('searchResult', { hits: hits });
  });

  Bridge.start(render);
})();
