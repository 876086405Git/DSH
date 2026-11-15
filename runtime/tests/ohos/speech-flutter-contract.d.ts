// Explicit host type surface, not a replacement for the pinned OH Flutter SDK.
declare module '@ohos.app.ability.UIAbility' {
  import common from '@ohos.app.ability.common';
  export default class UIAbility { context: common.UIAbilityContext; }
}
declare module '@ohos/flutter_ohos' {
  import UIAbility from '@ohos.app.ability.UIAbility';
  export type Any = unknown;
  export interface FlutterPluginBinding { getBinaryMessenger(): object; }
  export interface AbilityPluginBinding { getAbility(): UIAbility; }
  export interface FlutterPlugin {
    getUniqueClassName(): string;
    onAttachedToEngine(binding: FlutterPluginBinding): void;
    onDetachedFromEngine(binding: FlutterPluginBinding): void;
  }
  export interface AbilityAware {
    onAttachedToAbility(binding: AbilityPluginBinding): void;
    onDetachedFromAbility(): void;
  }
  export interface MethodCall { method: string; argument(name: string): Any; }
  export interface MethodResult {
    success(value: Any): void;
    error(code: string, message: string, details: Any): void;
    notImplemented(): void;
  }
  export interface MethodCallHandler { onMethodCall(call: MethodCall, result: MethodResult): void; }
  export class MethodChannel {
    constructor(messenger: object, name: string);
    setMethodCallHandler(handler: MethodCallHandler | null): void;
    invokeMethod(method: string, arguments_: Any): void;
  }
}
