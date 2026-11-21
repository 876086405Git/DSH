/// Bytes read as if they were text: a NUL, which no typed or copied text has
/// and every picture's header does. Android can hand a copied picture to
/// Flutter's text paste this way (the system reads the clip's content URI as
/// text, and some providers return the image whatever type is asked).
bool looksLikeBytes(String text) => text.contains('\u0000');

/// What was typed in front of such bytes. A picture starts with a byte UTF-8
/// cannot decode (JPEG 0xFF, PNG 0x89), read as U+FFFD: the text ends there,
/// less the control characters before it.
String typedBeforeBytes(String text) {
  final nul = text.indexOf('\u0000');
  var head = nul < 0 ? text : text.substring(0, nul);
  final undecodable = head.indexOf('\ufffd');
  if (undecodable >= 0) head = head.substring(0, undecodable);
  return head.replaceFirst(RegExp(r'[\x00-\x1f]+$'), '').trimRight();
}
