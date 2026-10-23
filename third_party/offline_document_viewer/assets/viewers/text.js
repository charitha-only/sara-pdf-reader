/* Shell for formats converted to HTML on the Dart side (RTF, and the legacy
 * binary formats shown as text).
 *
 * There is no rendering engine here: the markup is already in the page. This
 * script only reports readiness, builds an outline and implements search, so
 * the host application gets the same controller surface as every other format.
 */
(function () {
  'use strict';

  const stage = document.getElementById('stage');
  let viewMode = 'width';
  Bridge.on('viewMode', function(payload) { viewMode = payload.mode; fitLegacy(); });

  /* PAGEFLOW PATCH: fit legacy Word paper without altering table widths. */
  function fitLegacy() {
    const paper = stage.querySelector('.word-paper');
    if (!paper) { stage.style.zoom = viewMode === 'actual' || viewMode === 'width' ? '1' : String(Math.max(.5, Math.min(3, Number(viewMode) || 1))); return; }
    const content = paper.querySelector('[data-word-content]');
    if (content && content.dataset.pageWidth) paper.style.width = content.dataset.pageWidth + 'px';
    paper.style.transform = ''; paper.style.position = ''; paper.style.zoom = '1'; stage.style.height = '';
    const scale = viewMode === 'actual' ? 1 : Number(viewMode) > 0 ? Math.max(.5, Math.min(3, Number(viewMode))) : Math.min(1, document.documentElement.clientWidth / paper.offsetWidth);
    paper.style.zoom = String(scale); stage.style.height = Math.ceil(paper.getBoundingClientRect().height) + 'px';
    stage.style.overflowX = 'auto'; stage.style.overflowY = 'hidden';
  }
  fitLegacy();
  document.fonts.ready.then(fitLegacy);
  window.addEventListener('resize', fitLegacy);

  function collectOutline() {
    const labels = [];
    stage.querySelectorAll('h1, h2, h3').forEach(function (node, index) {
      const text = (node.textContent || '').trim();
      if (text) {
        node.setAttribute('data-outline', String(index));
        labels.push(text);
      }
    });
    return labels;
  }

  Bridge.on('goto', function (payload) {
    const target = stage.querySelector('[data-outline="' + payload.index + '"]');
    if (target) {
      target.scrollIntoView({ behavior: 'smooth', block: 'start' });
    }
  });

  Bridge.on('search', function (payload) {
    const query = (payload.query || '').toLowerCase();

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
      if (walker.currentNode.nodeValue.toLowerCase().indexOf(query) >= 0) {
        targets.push(walker.currentNode);
      }
    }

    targets.forEach(function (node) {
      const value = node.nodeValue;
      const lower = value.toLowerCase();
      const fragment = document.createDocumentFragment();
      let cursor = 0;
      let found = lower.indexOf(query, cursor);
      while (found >= 0) {
        fragment.appendChild(document.createTextNode(value.slice(cursor, found)));
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

  /* The markup is already present, so the bytes handshake is skipped: report
     immediately rather than waiting for a transfer that will never come. */
  Bridge.on('noop', function () {});
  Bridge.send('ready', {});
  Bridge.send('rendered', {
    ms: 0,
    units: stage.querySelectorAll('p, li').length,
    styled: true,
    outline: collectOutline()
  });

  document.addEventListener('click', function () {
    const selection = window.getSelection();
    if (selection && String(selection).length > 0) {
      return;
    }
    Bridge.send('toggleChrome', {});
  });
})();
