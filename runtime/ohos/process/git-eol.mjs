// Byte-level autocrlf behavior, checked against Git 2.51.1 native oracles and
// its convert.c rules. This is not a text decoder or a .gitattributes engine.
function automaticText(bytes) {
  let linePairs = 0, ordinary = 0, controls = 0;
  for (let index = 0; index < bytes.length; index++) {
    const value = bytes[index];
    if (value === 0) return { text: false, linePairs };
    if (value === 13) {
      if (bytes[index + 1] !== 10) return { text: false, linePairs };
      linePairs++; index++; continue;
    }
    if (value === 10 || (value === 26 && index === bytes.length - 1)) continue;
    if (value === 127 || (value < 32 && ![8, 9, 12, 27].includes(value))) controls++;
    else ordinary++;
  }
  return { text: controls <= Math.floor(ordinary / 128), linePairs };
}

/** Preserve binary, existing index CRLF and every non-newline byte verbatim. */
export function normalizeAutoCrlf(bytes, indexBytes) {
  const work = automaticText(bytes);
  if (!work.text || !work.linePairs) return bytes;
  const staged = automaticText(indexBytes);
  if (staged.text && staged.linePairs) return bytes;
  const result = Buffer.allocUnsafe(bytes.length - work.linePairs);
  let target = 0;
  for (let index = 0; index < bytes.length; index++) {
    if (bytes[index] === 13 && bytes[index + 1] === 10) continue;
    result[target++] = bytes[index];
  }
  return result;
}
