import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { WidgetValues, widgetView } from './CompanionWidgetData';

export async function publishCompanionWidgets(bundleName: string, values: WidgetValues): Promise<void> {
  const forms: formInfo.RunningFormInfo[] = await formProvider.getPublishedRunningFormInfos();
  let failed: boolean = false;
  for (let index: number = 0; index < forms.length; index++) {
    const form: formInfo.RunningFormInfo = forms[index];
    if (form.bundleName !== bundleName || form.moduleName !== 'entry' ||
      form.abilityName !== 'CompanionFormAbility' || form.formName !== 'companion_room') continue;
    try {
      const data: formBindingData.FormBindingData = formBindingData.createFormBindingData(widgetView(values, new Date()));
      await formProvider.updateForm(form.formId, data);
    }
    catch (_error) { failed = true; }
  }
  if (failed) throw new Error('One or more companion widgets could not be updated');
}
