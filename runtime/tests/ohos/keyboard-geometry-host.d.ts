// NONOFFICIAL Window/hilog additions to diagnostic-evidence-host.d.ts; not target SDK.
declare module '@ohos.window' {
  namespace window {
    interface Rect { left: number; top: number; width: number; height: number; }
    interface WindowAnimationConfig { curve: number; duration?: number; param?: Array<number>; }
    interface KeyboardInfo { beginRect: Rect; endRect: Rect; animated?: boolean; config?: WindowAnimationConfig; }
    // SDK contract includes visible, even though it has no supported display semantics.
    interface AvoidArea { visible: boolean; leftRect: Rect; topRect: Rect; rightRect: Rect; bottomRect: Rect; }
    interface AvoidAreaOptions { type: AvoidAreaType; area: AvoidArea; }
    enum AvoidAreaType { TYPE_SYSTEM = 0, TYPE_KEYBOARD = 3 }
    interface Window {
      on(event: 'keyboardWillShow' | 'keyboardWillHide' | 'keyboardDidShow' | 'keyboardDidHide', callback: (info: KeyboardInfo) => void): void;
      on(event: 'keyboardHeightChange', callback: (height: number) => void): void;
      on(event: 'avoidAreaChange', callback: (data: AvoidAreaOptions) => void): void;
      off(event: 'keyboardWillShow' | 'keyboardWillHide' | 'keyboardDidShow' | 'keyboardDidHide', callback: (info: KeyboardInfo) => void): void;
      off(event: 'keyboardHeightChange', callback: (height: number) => void): void;
      off(event: 'avoidAreaChange', callback: (data: AvoidAreaOptions) => void): void;
    }
    interface WindowStage { getMainWindowSync(): Window; }
  }
  export default window;
}
declare module '@ohos.hilog' {
  const hilog: { info(domain: number, tag: string, format: string, ...args: Array<string>): void;
    warn(domain: number, tag: string, format: string, ...args: Array<string>): void; };
  export default hilog;
}
