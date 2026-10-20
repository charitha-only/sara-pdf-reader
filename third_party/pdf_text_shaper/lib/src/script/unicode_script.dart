enum UnicodeScript {
  common,
  inherited,
  latin,
  bengali,
  devanagari,
  tamil,
  telugu,
  malayalam,
  kannada,
  gujarati,
  gurmukhi,
  odia,
  sinhala,
  thai,
  lao,
  khmer,
  myanmar,
  tibetan,
  arabic,
  hebrew,
  unknown;

  bool get isRightToLeft => this == arabic || this == hebrew;

  bool get isStrong => switch (this) {
    common || inherited || unknown => false,
    _ => true,
  };
}
