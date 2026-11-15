// Nonofficial host boundary declarations. Not an OHOS/HMS SDK or runtime implementation.
declare function canIUse(capability: string): boolean;
declare function setTimeout(callback: () => void, milliseconds: number): number;
declare function clearTimeout(id: number): void;
declare module '@ohos.base' { export interface BusinessError extends Error { code: number; } }
declare module '@ohos.app.ability.common' {
  namespace common { interface UIAbilityContext { applicationInfo: { accessTokenId: number; }; } }
  export default common;
}
