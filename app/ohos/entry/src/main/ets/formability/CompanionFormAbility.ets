// 数据扩展；配套卡片页面、图片与 profile 由本机接线。没有常驻任务/定时器。
import Want from '@ohos.app.ability.Want';
import common from '@ohos.app.ability.common';
import { FormExtensionAbility, formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { WidgetValues, widgetView } from '../companion/CompanionWidgetData';
import { CompanionWidgetStore } from '../companion/CompanionWidgetStore';

export default class CompanionFormAbility extends FormExtensionAbility {
  private tickets: Map<string, number> = new Map<string, number>();
  private serial: number = 0;
  private stopped: boolean = false;

  onAddForm(want: Want): formBindingData.FormBindingData {
    const identity: Object | undefined = want.parameters?.[formInfo.FormParam.IDENTITY_KEY];
    if (typeof identity === 'string' && identity.length > 0) this.refresh(identity);
    // Documented asynchronous-add path: no disk state is invented here.
    return formBindingData.createFormBindingData(widgetView(new WidgetValues(), new Date(), false));
  }

  onUpdateForm(formId: string): void { this.refresh(formId); }
  onCastToNormalForm(formId: string): void { this.refresh(formId); }
  onRemoveForm(formId: string): void { this.tickets.delete(formId); }
  onStop(): void { this.stopped = true; this.tickets.clear(); }

  private refresh(formId: string): void {
    if (this.stopped || formId.length === 0) return;
    const ticket: number = ++this.serial;
    this.tickets.set(formId, ticket);
    const context: common.ApplicationContext = this.context.getApplicationContext();
    CompanionWidgetStore.at(context.filesDir).transact(undefined, async (values: WidgetValues): Promise<void> => {
      if (this.stopped || this.tickets.get(formId) !== ticket) return;
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(widgetView(values, new Date())));
    }).catch((): void => {
      // Keep the last displayed value; surface the failure without logging private text.
      console.error('Companion form data refresh failed');
    }).finally((): void => {
      if (this.tickets.get(formId) === ticket) this.tickets.delete(formId);
    });
  }
}
