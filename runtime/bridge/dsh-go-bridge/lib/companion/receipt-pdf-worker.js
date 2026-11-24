import { parentPort, workerData } from 'node:worker_threads';
import { registerHooks } from 'node:module';
import { readFile } from 'node:fs/promises';

const root = new URL('./', import.meta.resolve('pdfjs-dist/package.json'));
const MAX_ITEMS = 50000;
// Closed names from pdfjs-dist 6.5.438, resolved only inside that installed package.
const assets = new Set(`cmaps/78-EUC-H.bcmap
cmaps/78-EUC-V.bcmap
cmaps/78-H.bcmap
cmaps/78-RKSJ-H.bcmap
cmaps/78-RKSJ-V.bcmap
cmaps/78-V.bcmap
cmaps/78ms-RKSJ-H.bcmap
cmaps/78ms-RKSJ-V.bcmap
cmaps/83pv-RKSJ-H.bcmap
cmaps/90ms-RKSJ-H.bcmap
cmaps/90ms-RKSJ-V.bcmap
cmaps/90msp-RKSJ-H.bcmap
cmaps/90msp-RKSJ-V.bcmap
cmaps/90pv-RKSJ-H.bcmap
cmaps/90pv-RKSJ-V.bcmap
cmaps/Add-H.bcmap
cmaps/Add-RKSJ-H.bcmap
cmaps/Add-RKSJ-V.bcmap
cmaps/Add-V.bcmap
cmaps/Adobe-CNS1-0.bcmap
cmaps/Adobe-CNS1-1.bcmap
cmaps/Adobe-CNS1-2.bcmap
cmaps/Adobe-CNS1-3.bcmap
cmaps/Adobe-CNS1-4.bcmap
cmaps/Adobe-CNS1-5.bcmap
cmaps/Adobe-CNS1-6.bcmap
cmaps/Adobe-CNS1-UCS2.bcmap
cmaps/Adobe-GB1-0.bcmap
cmaps/Adobe-GB1-1.bcmap
cmaps/Adobe-GB1-2.bcmap
cmaps/Adobe-GB1-3.bcmap
cmaps/Adobe-GB1-4.bcmap
cmaps/Adobe-GB1-5.bcmap
cmaps/Adobe-GB1-UCS2.bcmap
cmaps/Adobe-Japan1-0.bcmap
cmaps/Adobe-Japan1-1.bcmap
cmaps/Adobe-Japan1-2.bcmap
cmaps/Adobe-Japan1-3.bcmap
cmaps/Adobe-Japan1-4.bcmap
cmaps/Adobe-Japan1-5.bcmap
cmaps/Adobe-Japan1-6.bcmap
cmaps/Adobe-Japan1-UCS2.bcmap
cmaps/Adobe-Korea1-0.bcmap
cmaps/Adobe-Korea1-1.bcmap
cmaps/Adobe-Korea1-2.bcmap
cmaps/Adobe-Korea1-UCS2.bcmap
cmaps/B5-H.bcmap
cmaps/B5-V.bcmap
cmaps/B5pc-H.bcmap
cmaps/B5pc-V.bcmap
cmaps/CNS-EUC-H.bcmap
cmaps/CNS-EUC-V.bcmap
cmaps/CNS1-H.bcmap
cmaps/CNS1-V.bcmap
cmaps/CNS2-H.bcmap
cmaps/CNS2-V.bcmap
cmaps/ETen-B5-H.bcmap
cmaps/ETen-B5-V.bcmap
cmaps/ETenms-B5-H.bcmap
cmaps/ETenms-B5-V.bcmap
cmaps/ETHK-B5-H.bcmap
cmaps/ETHK-B5-V.bcmap
cmaps/EUC-H.bcmap
cmaps/EUC-V.bcmap
cmaps/Ext-H.bcmap
cmaps/Ext-RKSJ-H.bcmap
cmaps/Ext-RKSJ-V.bcmap
cmaps/Ext-V.bcmap
cmaps/GB-EUC-H.bcmap
cmaps/GB-EUC-V.bcmap
cmaps/GB-H.bcmap
cmaps/GB-V.bcmap
cmaps/GBK-EUC-H.bcmap
cmaps/GBK-EUC-V.bcmap
cmaps/GBK2K-H.bcmap
cmaps/GBK2K-V.bcmap
cmaps/GBKp-EUC-H.bcmap
cmaps/GBKp-EUC-V.bcmap
cmaps/GBpc-EUC-H.bcmap
cmaps/GBpc-EUC-V.bcmap
cmaps/GBT-EUC-H.bcmap
cmaps/GBT-EUC-V.bcmap
cmaps/GBT-H.bcmap
cmaps/GBT-V.bcmap
cmaps/GBTpc-EUC-H.bcmap
cmaps/GBTpc-EUC-V.bcmap
cmaps/H.bcmap
cmaps/Hankaku.bcmap
cmaps/Hiragana.bcmap
cmaps/HKdla-B5-H.bcmap
cmaps/HKdla-B5-V.bcmap
cmaps/HKdlb-B5-H.bcmap
cmaps/HKdlb-B5-V.bcmap
cmaps/HKgccs-B5-H.bcmap
cmaps/HKgccs-B5-V.bcmap
cmaps/HKm314-B5-H.bcmap
cmaps/HKm314-B5-V.bcmap
cmaps/HKm471-B5-H.bcmap
cmaps/HKm471-B5-V.bcmap
cmaps/HKscs-B5-H.bcmap
cmaps/HKscs-B5-V.bcmap
cmaps/Katakana.bcmap
cmaps/KSC-EUC-H.bcmap
cmaps/KSC-EUC-V.bcmap
cmaps/KSC-H.bcmap
cmaps/KSC-Johab-H.bcmap
cmaps/KSC-Johab-V.bcmap
cmaps/KSC-V.bcmap
cmaps/KSCms-UHC-H.bcmap
cmaps/KSCms-UHC-HW-H.bcmap
cmaps/KSCms-UHC-HW-V.bcmap
cmaps/KSCms-UHC-V.bcmap
cmaps/KSCpc-EUC-H.bcmap
cmaps/KSCpc-EUC-V.bcmap
cmaps/NWP-H.bcmap
cmaps/NWP-V.bcmap
cmaps/RKSJ-H.bcmap
cmaps/RKSJ-V.bcmap
cmaps/Roman.bcmap
cmaps/UniCNS-UCS2-H.bcmap
cmaps/UniCNS-UCS2-V.bcmap
cmaps/UniCNS-UTF16-H.bcmap
cmaps/UniCNS-UTF16-V.bcmap
cmaps/UniCNS-UTF32-H.bcmap
cmaps/UniCNS-UTF32-V.bcmap
cmaps/UniCNS-UTF8-H.bcmap
cmaps/UniCNS-UTF8-V.bcmap
cmaps/UniGB-UCS2-H.bcmap
cmaps/UniGB-UCS2-V.bcmap
cmaps/UniGB-UTF16-H.bcmap
cmaps/UniGB-UTF16-V.bcmap
cmaps/UniGB-UTF32-H.bcmap
cmaps/UniGB-UTF32-V.bcmap
cmaps/UniGB-UTF8-H.bcmap
cmaps/UniGB-UTF8-V.bcmap
cmaps/UniJIS-UCS2-H.bcmap
cmaps/UniJIS-UCS2-HW-H.bcmap
cmaps/UniJIS-UCS2-HW-V.bcmap
cmaps/UniJIS-UCS2-V.bcmap
cmaps/UniJIS-UTF16-H.bcmap
cmaps/UniJIS-UTF16-V.bcmap
cmaps/UniJIS-UTF32-H.bcmap
cmaps/UniJIS-UTF32-V.bcmap
cmaps/UniJIS-UTF8-H.bcmap
cmaps/UniJIS-UTF8-V.bcmap
cmaps/UniJIS2004-UTF16-H.bcmap
cmaps/UniJIS2004-UTF16-V.bcmap
cmaps/UniJIS2004-UTF32-H.bcmap
cmaps/UniJIS2004-UTF32-V.bcmap
cmaps/UniJIS2004-UTF8-H.bcmap
cmaps/UniJIS2004-UTF8-V.bcmap
cmaps/UniJISPro-UCS2-HW-V.bcmap
cmaps/UniJISPro-UCS2-V.bcmap
cmaps/UniJISPro-UTF8-V.bcmap
cmaps/UniJISX0213-UTF32-H.bcmap
cmaps/UniJISX0213-UTF32-V.bcmap
cmaps/UniJISX02132004-UTF32-H.bcmap
cmaps/UniJISX02132004-UTF32-V.bcmap
cmaps/UniKS-UCS2-H.bcmap
cmaps/UniKS-UCS2-V.bcmap
cmaps/UniKS-UTF16-H.bcmap
cmaps/UniKS-UTF16-V.bcmap
cmaps/UniKS-UTF32-H.bcmap
cmaps/UniKS-UTF32-V.bcmap
cmaps/UniKS-UTF8-H.bcmap
cmaps/UniKS-UTF8-V.bcmap
cmaps/V.bcmap
cmaps/WP-Symbol.bcmap
standard_fonts/FoxitDingbats.pfb
standard_fonts/FoxitFixed.pfb
standard_fonts/FoxitFixedBold.pfb
standard_fonts/FoxitFixedBoldItalic.pfb
standard_fonts/FoxitFixedItalic.pfb
standard_fonts/FoxitSerif.pfb
standard_fonts/FoxitSerifBold.pfb
standard_fonts/FoxitSerifBoldItalic.pfb
standard_fonts/FoxitSerifItalic.pfb
standard_fonts/FoxitSymbol.pfb
standard_fonts/LiberationSans-Bold.ttf
standard_fonts/LiberationSans-BoldItalic.ttf
standard_fonts/LiberationSans-Italic.ttf
standard_fonts/LiberationSans-Regular.ttf`.split('\n'));

const fail = code => { throw Object.assign(new Error(code), { code }); };

// This one worker never renders; keep optional native canvas out even when an
// unrelated Host installation has it. Other inherited module hooks remain intact.
registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier === '@napi-rs/canvas') fail('MODULE_NOT_FOUND');
    return nextResolve(specifier, context);
  },
});
globalThis.fetch = async () => fail('pdf_network_unavailable');

let loading;
try {
  const manifest = JSON.parse(await readFile(new URL('package.json', root), 'utf8'));
  if (manifest.name !== 'pdfjs-dist' || manifest.version !== '6.5.438') fail('pdf_dependency_unavailable');
  class BinaryDataFactory {
    async fetch({ kind, filename }) {
      const directory = { cMapUrl: 'cmaps', standardFontDataUrl: 'standard_fonts' }[kind];
      const relative = `${directory}/${filename}`;
      if (!directory || !assets.has(relative)) fail('pdf_asset_unavailable');
      return new Uint8Array(await readFile(new URL(relative, root)));
    }
  }
  const { getDocument, GlobalWorkerOptions } = await import('pdfjs-dist/legacy/build/pdf.min.mjs');
  GlobalWorkerOptions.workerSrc = './pdf.worker.min.mjs';
  loading = getDocument({
    data: workerData.data,
    BinaryDataFactory, useWorkerFetch: false, useSystemFonts: false,
    useWasm: false, isOffscreenCanvasSupported: false, isImageDecoderSupported: false,
    disableFontFace: true, enableXfa: false, stopAtErrors: true, verbosity: 0,
  });
  const document = await loading.promise;
  if (document.numPages > workerData.maxPages) fail('pdf_page_limit');
  const pages = [];
  let textBytes = 0, itemCount = 0;
  for (let pageNumber = 1; pageNumber <= document.numPages; pageNumber++) {
    const page = await document.getPage(pageNumber);
    const reader = page.streamTextContent({ disableNormalization: true }).getReader();
    const lines = [];
    let text = '';
    const flush = () => {
      if (text.length) lines.push({ line: lines.length + 1, text });
      text = '';
    };
    try {
      for (;;) {
        const chunk = await reader.read();
        if (chunk.done) break;
        for (const item of chunk.value.items) {
          if (++itemCount > MAX_ITEMS) fail('pdf_item_limit');
          if (typeof item.str !== 'string') continue;
          textBytes += Buffer.byteLength(item.str, 'utf8');
          if (textBytes > workerData.maxTextBytes) fail('pdf_text_limit');
          text += item.str;
          if (item.hasEOL) flush();
        }
      }
      flush();
    } finally {
      await reader.cancel(new Error('pdf_extraction_stopped'));
      reader.releaseLock();
      page.cleanup();
    }
    pages.push({ page: pageNumber, lines });
  }
  await loading.destroy();
  loading = null;
  parentPort.postMessage({ value: {
    pageCount: document.numPages, pages, textLayerOnly: true, fullTextExtraction: true,
  } });
} catch (error) {
  const code = error?.name === 'PasswordException' ? 'pdf_password_required' :
    error?.name === 'InvalidPDFException' ? 'pdf_invalid' :
      typeof error?.code === 'string' && error.code.startsWith('pdf_') ? error.code : 'pdf_parse_failed';
  parentPort.postMessage({ error: code });
} finally {
  await loading?.destroy();
  parentPort.close();
}
