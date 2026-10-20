# PPTXjs yamaları

Upstream: https://github.com/meshesha/PPTXjs @ 1.21.1 (MIT)
Dokunulmamış kopya: `js/pptxjs.js.orig` (CRLF satır sonlu — çalışan dosya LF'e
normalize edildi, davranışa etkisi yok).

Yamaların hepsi `js/pptxjs.js` içinde `/* PATCH: ... */` yorumuyla işaretli.
Doğrulama fixture'ı: `samples/edge-cases.pptx` (elle yazılmış OOXML,
`samples/build_sample_pptx.py` ile üretiliyor).

---

## 1. Madde imi fontu layout/master'dan miras alınmıyordu

**Belirti:** Madde imleri tofu kutusu (☒).

**Kök neden:** `~satır 8996`, `a:buFont` yalnızca paragrafın kendi `a:pPr`
düğümünde aranıyordu. Madde imi layout veya master'dan miras alındığında
`typefaceNode` `undefined` kalıyor, `getHtmlBullet` font ailesini tanıyamıyor
ve Wingdings karakterini ham Private Use Area kod noktası olarak basıyor
(`U+F097`) — hiçbir fontta karşılığı yok.

**Yama:** `buFontSize` için dosyada zaten uygulanan miras zinciri (`pPrNodeLaout`
→ `pPrNodeMaster`) font adı için de uygulandı. Gerçek bir ders sunumunda 27
bozuk madde imini düzeltti.

## 2. Wingdings dingbat tablosundan geçirilmiyordu

**Belirti:** Düz `Wingdings` madde imleri yanlış karakter.

**Kök neden:** `~satır 9200`, koşulda `Wingdings` yorum satırına alınmış:
`if (/*typefaceNode == "Wingdings" ||*/ ...)`. Nedeni upstream'de açıklanmamış.

**Yama:** `Wingdings` ve `Webdings` koşula geri eklendi. `dingbat.js` her iki
aile için de tam tablo taşıyor.

## 3. XML sayısal karakter referansları çözülmüyordu

**Belirti:** `char="&#xF097;"` yazılmış madde imi tamamen alakasız bir sembole
dönüşüyor (bizim testte makas ✀).

**Kök neden:** PPTXjs'in XML→JSON ayrıştırıcısı attribute değerlerindeki
sayısal karakter referanslarını çözmüyor. Dizgenin ilk karakteri `&` (0x26)
olarak okunuyor, dingbat tablosunda 0x26'ya karşılık gelen giriş bulunuyor.

**Yama:** `getHtmlBullet` girişinde `decodeCharRef()` — `&#xHHHH;` ve `&#DDDD;`
biçimlerini çözüyor. PowerPoint ham karakter yazar ama LibreOffice, python-pptx
ve elle üretilen dosyalar referans kullanabiliyor.

## 4. `docProps/app.xml` zorunlu varsayılıyordu

**Belirti:** Tüm render `Cannot read properties of null (reading 'Properties')`
ile çöküyor, hiçbir slayt basılmıyor.

**Kök neden:** `getSlideSizeAndSetDefaultTextStyle` `app["Properties"]["AppVersion"]`
değerini koşulsuz okuyor. PowerPoint bu parçayı hep yazar; LibreOffice, Google
Slides ve python-pptx çıktılarında eksik olabiliyor.

**Yama:** Eksikse sürüm 16 varsayılıp uyarı basılıyor, render devam ediyor.

## 5. `numCol` ve `vert` hiç işlenmiyordu

**Belirti:** Çok sütunlu metin kutusu tek sütun olarak, dikey metin yatay
olarak çiziliyor. İkisi de sessizce yok sayılıyordu.

**Yama:** `genTextBody` girişinde `a:bodyPr` niteliklerinden okunup çıktı bir
sarmalayıcı div'e alınıyor:

- `numCol` → `column-count` + `spcCol` → `column-gap`
- `vert="vert"` → `writing-mode: vertical-rl`
- `vert="vert270"` → dikey + 180° döndürme
- `vert="wordArtVert"` → `text-orientation: upright`

İki ek zorunluluk vardı: `column-fill: balance` (sarmalayıcıda kesin yükseklik
varken tarayıcı önce 1. sütunu doldurup ikinciyi boş bırakıyor), ve sarmalayıcı
içindeki div'lerde `width: auto` + `display: block` (PPTXjs her paragrafa sabit
`width` ve `display:flex` veriyor; ikisi de sütuna bölünmeyi engelliyor).

**Bilinen bedel:** Çok sütunlu bir kutuda madde imi varsa hizası bozulabilir —
`display:flex` madde imi hizalaması için kullanılıyor.

---

## Ayrıca: `dingbat.js` yüklenmeli

Yama değil ama kolay atlanan bir nokta — upstream'in kendi `index.html` demosu
`js/dingbat.js`'i **yüklemiyor**. Yüklenmezse `dingbat_unicode` tanımsız kalır
ve tüm sembol dönüşümü sessizce devre dışı olur.

## Kapatılmayan sınırlar

- Uzun satırlarda ara sıra kelime ortadan bölünüyor (`word-wrap: break-word`
  pptxjs.js'te sabit kodlu, `~satır 8700`). Metrik-uyumlu fontlar bunu büyük
  ölçüde azaltıyor ama tamamen bitirmiyor.
- `normAutofit` (metni kutuya sığdırmak için otomatik küçültme) uygulanmıyor —
  taşan metin taşmaya devam ediyor.
- Konuşmacı notları render edilmiyor (görüntüleyici için doğru davranış).
- Animasyon ve geçişler yok.

## Bakım maliyeti

PPTXjs güncellenirse beş yamanın hepsi yeniden uygulanmalı. Upstream yavaş
ilerliyor (26 açık issue), yani yama yükü kalıcı. 1, 2, 3 ve 4 numaralı yamalar
net spec uygunluk düzeltmeleri — upstream'e PR olarak gönderilmeye değer.
