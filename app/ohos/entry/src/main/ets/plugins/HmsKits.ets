// UNCOMPILED_HMS: public Kit names follow hms-contracts.md; device loading remains unverified.
// Type imports do not load a Kit. Each feature loads only at its first actual use.
import type { pdfService } from '@kit.PDFKit';
import type { systemShare } from '@kit.ShareKit';
import type { speechRecognizer } from '@kit.CoreSpeechKit';
import type Want from '@ohos.app.ability.Want';

export class PdfKit {
  createDocument: () => pdfService.PdfDocument;
  createMatrix: () => pdfService.PdfMatrix;
  createPixelOptions: () => pdfService.PixelOptions;
  success: pdfService.ParseResult;
  password: pdfService.ParseResult;
  constructor(api: ESObject) {
    this.createDocument = (): pdfService.PdfDocument => new api.PdfDocument();
    this.createMatrix = (): pdfService.PdfMatrix => new api.PdfMatrix();
    this.createPixelOptions = (): pdfService.PixelOptions => new api.PixelOptions();
    this.success = api.ParseResult.PARSE_SUCCESS;
    this.password = api.ParseResult.PARSE_ERROR_PASSWORD;
  }
}

export class ShareKit {
  createData: (record: systemShare.SharedRecord) => systemShare.SharedData;
  createController: (data: systemShare.SharedData) => systemShare.ShareController;
  getSharedData: (want: Want) => Promise<systemShare.SharedData>;
  single: systemShare.SelectionMode;
  batch: systemShare.SelectionMode;
  preview: systemShare.SharePreviewMode;
  constructor(api: ESObject) {
    this.createData = (record: systemShare.SharedRecord): systemShare.SharedData => new api.SharedData(record);
    this.createController = (data: systemShare.SharedData): systemShare.ShareController => new api.ShareController(data);
    this.getSharedData = (want: Want): Promise<systemShare.SharedData> => api.getSharedData(want);
    this.single = api.SelectionMode.SINGLE;
    this.batch = api.SelectionMode.BATCH;
    this.preview = api.SharePreviewMode.DEFAULT;
  }
}

export class SpeechKit {
  createEngine: (params: speechRecognizer.CreateEngineParams) => Promise<speechRecognizer.SpeechRecognitionEngine>;
  constructor(api: ESObject) {
    this.createEngine = (params: speechRecognizer.CreateEngineParams): Promise<speechRecognizer.SpeechRecognitionEngine> => api.createEngine(params);
  }
}

let pdfLoading: Promise<PdfKit> | null = null;
let shareLoading: Promise<ShareKit> | null = null;
let speechLoading: Promise<SpeechKit> | null = null;

export function loadPdfKit(): Promise<PdfKit> {
  if (pdfLoading === null) {
    pdfLoading = import('./HmsPdfKit').then((module: ESObject): PdfKit => {
      const api: ESObject = module.pdfService;
      if (api === undefined) throw new Error('PDF Kit is unavailable');
      return new PdfKit(api);
    }).catch((error: Error): PdfKit => {
      pdfLoading = null;
      throw error as Error;
    });
  }
  return pdfLoading;
}

export function loadShareKit(): Promise<ShareKit> {
  if (shareLoading === null) {
    shareLoading = import('./HmsShareKit').then((module: ESObject): ShareKit => {
      const api: ESObject = module.systemShare;
      if (api === undefined) throw new Error('Share Kit is unavailable');
      return new ShareKit(api);
    }).catch((error: Error): ShareKit => {
      shareLoading = null;
      throw error as Error;
    });
  }
  return shareLoading;
}

export function loadSpeechKit(): Promise<SpeechKit> {
  if (speechLoading === null) {
    speechLoading = import('./HmsSpeechKit').then((module: ESObject): SpeechKit => {
      const api: ESObject = module.speechRecognizer;
      if (api === undefined) throw new Error('Core Speech Kit is unavailable');
      return new SpeechKit(api);
    }).catch((error: Error): SpeechKit => {
      speechLoading = null;
      throw error as Error;
    });
  }
  return speechLoading;
}
