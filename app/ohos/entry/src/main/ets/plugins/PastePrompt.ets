import { BusinessError } from '@ohos.base';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import { ComponentContent } from '@ohos.arkui.node';
import { PromptAction } from '@ohos.arkui.UIContext';

class PasteActions {
  readonly click: (granted: boolean) => void;
  readonly cancel: () => void;
  constructor(click: (granted: boolean) => void, cancel: () => void) {
    this.click = click;
    this.cancel = cancel;
  }
}

@Builder
function pasteContent(actions: PasteActions) {
  Column({ space: 16 }) {
    Text($r('app.string.dsh_paste_prompt'))
    // Genuine system security component: no synthetic clicks, opacity or overlay.
    PasteButton()
      .onClick((_event: ClickEvent, result: PasteButtonOnClickResult): void => {
        actions.click(result === PasteButtonOnClickResult.SUCCESS);
      })
    Button($r('app.string.dsh_paste_cancel')).onClick((): void => actions.cancel())
  }.padding(24)
}

// This is the only UI boundary replaced by the Linux contract fixture. The
// fixture cannot establish that a device granted PasteButton authorization.
export class PastePrompt {
  private win: window.Window | null = null;
  private prompt: PromptAction | null = null;
  private content: ComponentContent<PasteActions> | null = null;
  private opening: Promise<void> | null = null;
  private closing: Promise<void> | null = null;
  private closed: boolean = false;
  private dialogClosed: boolean = false;
  private readonly cancel: () => void;
  private readonly event: (value: window.WindowEventType) => void;
  constructor(cancel: () => void) {
    this.cancel = cancel;
    this.event = (value: window.WindowEventType): void => {
      if (value === window.WindowEventType.WINDOW_HIDDEN || value === window.WindowEventType.WINDOW_DESTROYED) {
        this.cancel();
      }
    };
  }
  open(context: common.UIAbilityContext, click: (granted: boolean) => void): Promise<void> {
    this.opening = this.show(context, click);
    return this.opening;
  }
  private async show(context: common.UIAbilityContext, click: (granted: boolean) => void): Promise<void> {
    const win = await window.getLastWindow(context);
    if (this.closed) return;
    this.win = win;
    win.on('windowEvent', this.event);
    const ui = win.getUIContext();
    this.prompt = ui.getPromptAction();
    const content = new ComponentContent<PasteActions>(ui, wrapBuilder(pasteContent), new PasteActions(click, this.cancel));
    this.content = content;
    await this.prompt.openCustomDialog(content, {
      isModal: true, showInSubWindow: false, autoCancel: true,
      onWillDismiss: (): void => this.cancel(),
    });
  }
  // Whether it went up. The result also carries a stable status. Never include clipboard text.
  feedback(resource: Resource): boolean {
    if (this.prompt === null) return false;
    this.prompt.showToast({ message: resource });
    return true;
  }
  close(): Promise<void> {
    if (this.closing !== null) return this.closing;
    this.closed = true;
    this.closing = this.dismiss().catch((error: Error): void => {
      this.closing = null;
      throw error;
    });
    return this.closing;
  }
  private async dismiss(): Promise<void> {
    try { await this.opening; } catch (_) { /* Failed opens still release the content below. */ }
    const content = this.content;
    if (content !== null && this.prompt !== null && !this.dialogClosed) {
      try { await this.prompt.closeCustomDialog(content); }
      catch (error) {
        // SDK documents this exact content as no longer present. Other errors
        // leave the content and owner intact for an explicit cleanup retry.
        if ((error as BusinessError).code !== 103303) throw error as Error;
      }
      this.dialogClosed = true;
    }
    if (this.win !== null) this.win.off('windowEvent', this.event);
    content?.dispose();
    this.win = null; this.content = null; this.prompt = null;
  }
}
