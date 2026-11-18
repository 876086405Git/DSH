// Eligibility only; ContinuousTaskOwner separately waits for OS task acceptance.
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
    if (abilityAccessCtrl.createAtManager().checkAccessTokenSync(accessTokenId,
      'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM') !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) return 'denied';
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
    return request.isModeSupported() ? 'granted' : 'denied';
  } catch (_) {
    // 9800005 combines mode/ACL/configuration failures; it is not a user denial.
    return 'unknown';
  }
}

// Whether this build may schedule system reminders at all. Plain builds don't ask for
// the permission (hap-distribution.py). The service can still say no at publish time.
export function agentReminderAccess(accessTokenId: number): string {
  if (!canIUse('SystemCapability.Notification.ReminderAgent')) return 'unsupported';
  try {
    const grant = abilityAccessCtrl.createAtManager().checkAccessTokenSync(
      accessTokenId, 'ohos.permission.PUBLISH_AGENT_REMINDER');
    return grant === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED ? 'granted' : 'denied';
  } catch (_) {
    return 'denied';
  }
}
