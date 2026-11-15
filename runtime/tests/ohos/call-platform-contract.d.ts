// Explicit host type surface only. These declarations are not SDK headers and
// cannot establish ArkTS/API-26/HAP compatibility or phone audio behavior.
declare module '@ohos.app.ability.common' {
  namespace common { interface UIAbilityContext { applicationInfo: { accessTokenId: number; }; } }
  export default common;
}
declare module '@ohos.abilityAccessCtrl' {
  namespace abilityAccessCtrl {
    enum GrantStatus { PERMISSION_GRANTED = 0 }
    interface AtManager { checkAccessToken(token: number, permission: string): Promise<GrantStatus>; }
    function createAtManager(): AtManager;
  }
  export default abilityAccessCtrl;
}
declare module '@ohos.systemDateTime' {
  namespace systemDateTime {
    enum TimeType { STARTUP = 0 }
    function getUptime(type: TimeType, isNanoseconds: boolean): number;
  }
  export default systemDateTime;
}
declare module '@ohos.window' {
  import common from '@ohos.app.ability.common';
  namespace window {
    interface WindowProperties { isKeepScreenOn: boolean; }
    interface Window {
      getWindowProperties(): WindowProperties;
      setWindowKeepScreenOn(on: boolean): Promise<void>;
    }
    function getLastWindow(context: common.UIAbilityContext): Promise<Window>;
  }
  export default window;
}
declare module '@kit.BasicServicesKit' {
  export interface BusinessError extends Error { code: number; }
}
