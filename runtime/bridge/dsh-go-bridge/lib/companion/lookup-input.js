// Same batching heuristic as app/lib/companion/companion_context.dart.
// This estimate is neither exact tokenization nor provider-reported usage.
export function estimateLookupInputTokens(text) {
  let tenths = 0;
  for (const character of text) {
    const rune = character.codePointAt(0);
    if (rune <= 0x7f) tenths += 3;
    else if (rune >= 0x3400 && rune <= 0x9fff || rune >= 0xf900 && rune <= 0xfaff ||
      rune >= 0x3040 && rune <= 0x30ff || rune >= 0xac00 && rune <= 0xd7a3 ||
      rune >= 0x20000 && rune <= 0x3ffff) tenths += 6;
    else tenths += Buffer.byteLength(character) * 10;
  }
  return Math.ceil(tenths / 10);
}
