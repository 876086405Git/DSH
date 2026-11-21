// Synthetic fixtures: image date is drawn as pixels, not hidden PDF text.
import { deflateSync } from 'node:zlib';
import { createHash } from 'node:crypto';
const latin = (text) => Buffer.from(text, 'latin1');
function stream(body, extra = '') {
  const bytes = Buffer.isBuffer(body) ? body : latin(body);
  return Buffer.concat([latin(`<< /Length ${bytes.length} ${extra} >>\nstream\n`), bytes, latin('\nendstream')]);
}
function pdf(objects, trailer = '') {
  const chunks = [latin('%PDF-1.7\n%\xE2\xE3\xCF\xD3\n')];
  const offsets = [0]; let length = chunks[0].length;
  objects.forEach((body, i) => {
    offsets.push(length);
    const chunk = Buffer.concat([latin(`${i + 1} 0 obj\n`), Buffer.isBuffer(body) ? body : latin(body), latin('\nendobj\n')]);
    chunks.push(chunk); length += chunk.length;
  });
  chunks.push(latin(`xref\n0 ${objects.length + 1}\n0000000000 65535 f \n${offsets.slice(1).map(x => `${String(x).padStart(10, '0')} 00000 n \n`).join('')}trailer\n<< /Size ${objects.length + 1} /Root 1 0 R ${trailer} >>\nstartxref\n${length}\n%%EOF\n`));
  return Buffer.concat(chunks);
}

const glyphs = {
  '0': ['01110','10001','10011','10101','11001','10001','01110'],
  '1': ['00100','01100','00100','00100','00100','00100','01110'],
  '2': ['01110','10001','00001','00010','00100','01000','11111'],
  '3': ['11110','00001','00001','01110','00001','00001','11110'],
  '4': ['00010','00110','01010','10010','11111','00010','00010'],
  '5': ['11111','10000','10000','11110','00001','00001','11110'],
  '6': ['01110','10000','10000','11110','10001','10001','01110'],
  '7': ['11111','00001','00010','00100','01000','01000','01000'],
  '8': ['01110','10001','10001','01110','10001','10001','01110'],
  '9': ['01110','10001','10001','01111','00001','00001','01110'],
  '-': ['00000','00000','00000','11111','00000','00000','00000'],
};
const imageDate = '2026-11-20';
const imageWidth = imageDate.length * 6;
const pixels = Buffer.alloc(imageWidth * 7, 255);
for (const [index, character] of [...imageDate].entries()) {
  for (let y = 0; y < 7; y++) for (let x = 0; x < 5; x++) {
    if (glyphs[character][y][x] === '1') pixels[y * imageWidth + index * 6 + x] = 0;
  }
}
const imageObject = stream(deflateSync(pixels), `/Type /XObject /Subtype /Image /Width ${imageWidth} /Height 7 /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode`);
const paintImage = `q ${imageWidth * 3} 0 0 21 20 130 cm /Im0 Do Q`;
const textLines = (lines) => lines.map((s, i) => `BT /F1 12 Tf 20 ${190 - 18 * i} Td (${s}) Tj ET`).join('\n');
function ordinary(pages, { action = false, compressed = false, pageHeight = 240 } = {}) {
  const kids = pages.map((_, i) => `${3 + i * 2} 0 R`).join(' ');
  const font = 3 + pages.length * 2;
  const image = font + 1;
  const objects = [
    `<< /Type /Catalog /Pages 2 0 R ${action ? '/OpenAction << /S /JavaScript /JS (process.exit(42)) >>' : ''} >>`,
    `<< /Type /Pages /Kids [${kids}] /Count ${pages.length} >>`,
  ];
  pages.forEach((body, i) => objects.push(
    `<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 ${pageHeight}] /Resources << /Font << /F1 ${font} 0 R >> /XObject << /Im0 ${image} 0 R >> >> /Contents ${4 + i * 2} 0 R >>`,
    compressed ? stream(deflateSync(latin(body)), '/Filter /FlateDecode') : stream(body),
  ));
  objects.push('<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>', imageObject);
  return pdf(objects);
}

const chinese = '日期2026-11-20 项目交通 金额CNY80.00';
const characters = [...new Set([...chinese])];
const cid = new Map(characters.map((c, i) => [c, i + 1]));
const cmap = `/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n/CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n/CMapName /ResearchTextUnicode def\n/CMapType 2 def\n1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n${characters.length} beginbfchar\n${characters.map(c => `<${cid.get(c).toString(16).padStart(4, '0')}> <${c.codePointAt(0).toString(16).padStart(4, '0')}>`).join('\n')}\nendbfchar\nendcmap\nCMapName currentdict /CMap defineresource pop\nend\nend`;
const chinesePdf = pdf([
  '<< /Type /Catalog /Pages 2 0 R >>',
  '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
  '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 500 240] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
  stream(`BT /F1 12 Tf 20 190 Td <${[...chinese].map(c => cid.get(c).toString(16).padStart(4, '0')).join('')}> Tj ET`),
  '<< /Type /Font /Subtype /Type0 /BaseFont /HeiseiMin-W3 /Encoding /Identity-H /DescendantFonts [6 0 R] /ToUnicode 8 0 R >>',
  '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /HeiseiMin-W3 /CIDSystemInfo << /Registry (Adobe) /Ordering (Japan1) /Supplement 0 >> /FontDescriptor 7 0 R /DW 1000 >>',
  '<< /Type /FontDescriptor /FontName /HeiseiMin-W3 /Flags 4 /FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 /Descent -200 /CapHeight 700 /StemV 80 >>',
  stream(cmap),
]);


// Genuine PDF Standard Security revision 2, used only as a synthetic rejection
// fixture. The test reader does not accept or guess a document password.
function encryptedPdf() {
  const padding = Buffer.from('28bf4e5e4e758a4164004e56fffa01082e2e00b6d0683e802f0ca9fe6453697a', 'hex');
  const padded = password => Buffer.concat([latin(password), padding]).subarray(0, 32);
  const md5 = bytes => createHash('md5').update(bytes).digest();
  const rc4 = (key, input) => {
    const state = Array.from({ length: 256 }, (_, i) => i);
    let j = 0;
    for (let i = 0; i < 256; i++) {
      j = (j + state[i] + key[i % key.length]) & 255;
      [state[i], state[j]] = [state[j], state[i]];
    }
    let i = 0; j = 0;
    return Buffer.from([...input].map(byte => {
      i = (i + 1) & 255; j = (j + state[i]) & 255;
      [state[i], state[j]] = [state[j], state[i]];
      return byte ^ state[(state[i] + state[j]) & 255];
    }));
  };
  const id = md5(latin('companion-receipt-test'));
  const owner = rc4(md5(padded('owner')).subarray(0, 5), padded('secret'));
  const permissions = Buffer.alloc(4); permissions.writeInt32LE(-4);
  const key = md5(Buffer.concat([padded('secret'), owner, permissions, id])).subarray(0, 5);
  const user = rc4(key, padding);
  const objectKey = md5(Buffer.concat([key, Buffer.from([4, 0, 0, 0, 0])])).subarray(0, 10);
  return pdf([
    '<< /Type /Catalog /Pages 2 0 R >>',
    '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
    '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 240] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>',
    stream(rc4(objectKey, latin(textLines(['AMOUNT CNY 80.00'])))),
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
    `<< /Filter /Standard /V 1 /R 2 /O <${owner.toString('hex')}> /U <${user.toString('hex')}> /P -4 >>`,
  ], `/Encrypt 6 0 R /ID [<${id.toString('hex')}> <${id.toString('hex')}>]`);
}

export { ordinary, textLines, paintImage, imageDate, chinese, chinesePdf, encryptedPdf, pdf, stream };
