// Eligibility for TASK_KEEPING only. No permission request or background task is created.
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';

export function backgroundComputePermission(accessTokenId: number): string {
  if (!canIUse('SystemCapability.Security.AccessToken')) return 'unknown';
  try {
    const grant = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
      accessTokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING');
    if (grant === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) return 'denied';
    if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ||
        !canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask')) return 'unknown';
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
    return request.isModeSupported() ? 'granted' : 'denied';
  } catch (_) {
    // 9800005 combines mode/ACL/configuration failures; it is not a user denial.
    return 'unknown';
  }
}
