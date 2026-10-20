# docx-preview yamaları

Upstream: https://github.com/VolodymyrBaydalka/docxjs @ 0.3.5 (Apache-2.0)
Dokunulmamış kopya: `docx-preview.js.orig`. Minified sürüm (`docx-preview.min.js`)
artık kullanılmıyor — yamalar okunabilir olsun diye unminified sürüme geçildi.

Her iki yama da `Xml.colorAttr` içinde, `/* PATCH: ... */` yorumuyla işaretli.

## 1. `themeFill` hiç okunmuyordu

**Belirti:** Tablo hücrelerinin tema tabanlı gölgelendirmesi kayboluyor,
hücreler beyaz kalıyor.

**Kök neden:** `colorAttr` yalnızca `themeColor` niteliğine bakıyordu:

```js
var themeColor = globalXmlParser.attr(node, "themeColor");
```

Word tablo gölgelendirmesini `<w:shd w:themeFill="accent1"/>` diye yazıyor.
`themeFill` hiçbir yerde aranmadığı için sonuç `defValue` (yani yok) oluyordu.

**Yama:** `themeColor || themeFill`.

## 2. `themeTint` / `themeShade` uygulanmıyordu

**Belirti:** "accent1, %60 daha açık" düz accent1 olarak çiziliyor. Word'de
açık mavi başlık satırı olan tablo, koyu mavi çıkıyor.

**Kök neden:** Tint ve shade nitelikleri hiç okunmuyordu.

**Yama:** Tint/shade 0–255 arası HEX; tint beyaza, shade siyaha karıştırma
oranı. CSS değişkeninin kendisini bozmadan `color-mix()` ile uygulanıyor:

```js
color-mix(in srgb, var(--docx-accent1-color) 60%, white)
```

`color-mix()` Chrome 111+ ve Safari 16.2+ gerektiriyor — Android WebView ve
iOS WKWebView'ın güncel sürümlerinde sorun yok, daha eskisinde renk ham temaya
düşer (bozulmaz, sadece tonlama kaybolur).

## 3. `w:val="auto"` tema rengini eziyordu

**Belirti:** Tema tabanlı **metin** renklerinin hepsi siyah.

**Kök neden:** Word tema metin rengini şöyle yazıyor:

```xml
<w:color w:val="auto" w:themeColor="accent1"/>
```

`colorAttr` `"auto"` görünce hemen `autoColor` (siyah) döndürüyor ve tema
dalına hiç ulaşmıyordu. Oysa tema referansı varken `"auto"` bir renk değeri
değil, "rengi temadan al" demektir.

**Yama:** `"auto"` erken dönüşü yalnızca tema referansı **yokken** çalışıyor.

## Etki

Bu üçü kapatılmadan, modern Word şablonlarının neredeyse tamamı renksiz
çıkıyor — kurumsal belgeler tema renklerini yoğun kullanıyor. Test dosyası
`samples/sample.docx` dördünü de içeriyor (düz tema rengi, tint, shade,
tablo `themeFill`).

## Bakım maliyeti

docx-preview güncellenirse üç yama yeniden uygulanmalı. `colorAttr` küçük ve
kararlı bir fonksiyon, yeniden uygulaması kolay. Yamalar upstream'e PR olarak
gönderilmeye değer — üçü de spec'e uygunluk düzeltmesi, davranış tercihi değil.
