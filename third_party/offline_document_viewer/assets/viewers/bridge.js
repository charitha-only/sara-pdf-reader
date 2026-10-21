/* Dart ↔ JS köprüsü — tüm görüntüleyici kabukları bunu paylaşır.
 *
 * Belge byte'larını almanın iki yolu var ve hangisinin çalıştığı platforma
 * bağlı:
 *
 *   1. `fetch('./doc.bin')` — Android'de WebViewAssetLoader gerçek bir https
 *      origin verdiği için sorunsuz.
 *   2. Dart'ın parça parça gönderdiği base64 — iOS'ta `file://` origin'inden
 *      `fetch` CORS tarafından engelleniyor. `allowFileAccessFromFileURLs`
 *      açmak yerine byte'ları köprüden geçiriyoruz: güvenlik ayarını
 *      gevşetmeden aynı sonuç.
 *
 * Kabuk hangisinin kullanıldığını bilmez; yalnızca `Bridge.start(render)`
 * çağırır ve byte'lar geldiğinde render eder.
 */
(function (global) {
  'use strict';

  const handlers = Object.create(null);
  let onBytes = null;
  const chunks = [];
  let expectedBytes = 0;

  function toDart(type, payload) {
    const message = JSON.stringify({ type: type, payload: payload || {} });
    if (global.flutter_inappwebview && global.flutter_inappwebview.callHandler) {
      global.flutter_inappwebview.callHandler('evrak', message);
    }
  }

  function fail(code, detail) {
    toDart('error', { code: code, detail: String(detail || '') });
  }

  /* base64 → Uint8Array. atob tek seferde büyük dizgede yavaş; parçalar
     zaten küçük geldiği için parça başına dönüştürüyoruz. */
  function decodeChunk(base64) {
    const binary = global.atob(base64);
    const out = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) {
      out[i] = binary.charCodeAt(i);
    }
    return out;
  }

  function assemble() {
    let total = 0;
    for (let i = 0; i < chunks.length; i++) {
      total += chunks[i].length;
    }
    const merged = new Uint8Array(total);
    let offset = 0;
    for (let i = 0; i < chunks.length; i++) {
      merged.set(chunks[i], offset);
      offset += chunks[i].length;
    }
    chunks.length = 0;
    return merged;
  }

  async function deliver(bytes) {
    try {
      await onBytes(bytes);
    } catch (e) {
      fail('render_failed', (e && e.stack) || e);
    }
  }

  const Bridge = {
    /** Dart'tan gelen mesaj tipine dinleyici bağlar. */
    on: function (type, handler) {
      handlers[type] = handler;
    },

    /** Dart'a mesaj gönderir. */
    send: toDart,

    /** Dart'ın çağırdığı tek giriş noktası. */
    receive: function (raw) {
      let message;
      try {
        message = typeof raw === 'string' ? JSON.parse(raw) : raw;
      } catch (e) {
        return fail('bad_message', e);
      }

      switch (message.type) {
        case 'bytesBegin':
          chunks.length = 0;
          expectedBytes = message.payload.total || 0;
          return;

        case 'bytesChunk':
          chunks.push(decodeChunk(message.payload.data));
          return;

        case 'bytesEnd': {
          const bytes = assemble();
          if (expectedBytes && bytes.length !== expectedBytes) {
            return fail(
              'transfer_incomplete',
              bytes.length + ' / ' + expectedBytes
            );
          }
          return void deliver(bytes);
        }

        default: {
          if (message.type === 'search') { activeHit = -1; toDart('searchIndex', {index:-1}); }
          const handler = handlers[message.type];
          if (handler) {
            try {
              handler(message.payload || {});
            } catch (e) {
              fail('handler_failed', (e && e.stack) || e);
            }
          }
        }
      }
    },

    /**
     * Kabuk hazır olduğunda çağrılır.
     *
     * Önce doğrudan `fetch` denenir (Android yolu); engellenirse Dart'a
     * "byte'ları sen gönder" denir (iOS yolu). Hangi yolun kullanıldığı
     * Dart tarafında ölçülüyor.
     */
    start: function (render) {
      onBytes = render;
      global.fetch('./doc.bin')
        .then(function (response) {
          if (!response.ok) {
            throw new Error('HTTP ' + response.status);
          }
          return response.arrayBuffer();
        })
        .then(function (buffer) {
          toDart('transport', { mode: 'fetch' });
          return deliver(new Uint8Array(buffer));
        })
        .catch(function () {
          // file:// origin'inde fetch engelli — köprüden bekle.
          toDart('transport', { mode: 'bridge' });
          toDart('needBytes', {});
        });

      /* Belgeye dokunmak kabuğu açıp kapatıyor — okurken metin kahraman,
         gerektiğinde kontroller geri geliyor. Seçim yapılıyorsa sinyal
         gönderilmiyor; kullanıcı metin seçerken kabuk zıplamamalı. */
      global.document.addEventListener('click', function () {
        const selection = global.getSelection();
        if (selection && String(selection).length > 0) {
          return;
        }
        toDart('toggleChrome', {});
      });

      toDart('ready', {});
    }
  };


  // Reader v1.02: shared position reporting and result navigation.
  let viewportTimer = 0;
  function viewport() {
    clearTimeout(viewportTimer);
    viewportTimer = setTimeout(function () {
      const stage = document.getElementById('stage');
      const max = Math.max(0, document.documentElement.scrollHeight - innerHeight);
      toDart('viewport', {fraction: max ? scrollY / max : 0, horizontal: stage ? stage.scrollLeft : 0});
    }, 180);
  }
  global.addEventListener('scroll', viewport, {passive:true, capture:true});
  Bridge.on('restoreViewport', function (payload) {
    requestAnimationFrame(function () { requestAnimationFrame(function () {
      const fraction = Math.max(0, Math.min(1, Number(payload.fraction) || 0));
      scrollTo(0, fraction * Math.max(0, document.documentElement.scrollHeight - innerHeight));
      const stage = document.getElementById('stage');
      if (stage) stage.scrollLeft = Math.max(0, Number(payload.horizontal) || 0);
    }); });
  });
  let activeHit = -1;
  Bridge.on('searchMove', function (payload) {
    const hits = Array.from(document.querySelectorAll('#stage .hit'));
    if (!hits.length) return;
    if (activeHit < 0 && payload.direction < 0) activeHit = 0;
    activeHit = (activeHit + (payload.direction < 0 ? -1 : 1) + hits.length) % hits.length;
    hits.forEach(function(node) {node.style.outline = '';});
    hits[activeHit].style.outline = '3px solid #d85b00';
    hits[activeHit].scrollIntoView({block:'center', inline:'nearest'});
    toDart('searchIndex', {index: activeHit});
  });

  global.Bridge = Bridge;
  // Dart tarafı bu adı çağırıyor; adı değiştirmek köprüyü kırar.
  global.__evrakReceive = Bridge.receive;
})(window);
