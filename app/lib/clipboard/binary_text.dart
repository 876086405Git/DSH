/// Bytes read as if they were text: a NUL, or replacement characters in a
/// share no typed or copied text has. Android can hand a copied picture to
/// Flutter's text paste this way (the system reads the clip's content URI as
/// text, and some providers return the image whatever type is asked), and
/// such a "text" is not something anyone wrote.
bool looksLikeBytes(String text) {
  if (text.contains('\u0000')) return true;
  var replaced = 0;
  for (final unit in text.codeUnits) {
    if (unit == 0xFFFD) replaced++;
  }
  return replaced >= 16 && replaced * 20 > text.length;
}
