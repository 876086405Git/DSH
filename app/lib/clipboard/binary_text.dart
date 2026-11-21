/// Bytes read as if they were text: a NUL, which no typed or copied text has
/// and every picture's header does. Android can hand a copied picture to
/// Flutter's text paste this way (the system reads the clip's content URI as
/// text, and some providers return the image whatever type is asked).
bool looksLikeBytes(String text) => text.contains('\u0000');

/// What was typed in front of such bytes: the text up to them, without the
/// undecodable characters a picture's header starts with.
String typedBeforeBytes(String text) {
  final at = text.indexOf('\u0000');
  final head = at < 0 ? text : text.substring(0, at);
  return head.replaceFirst(RegExp(r'[\ufffd\x01-\x1f\x7f-\xff]+$'), '').trimRight();
}
