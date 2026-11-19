// Eligibility only; ContinuousTaskOwner separately waits for OS task acceptance.
import abilityAccessCtrl from '@ohos.abilityAccessCtrl';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';

function computeStatus(supported: boolean, permission: string, status: string, error: string | null,
  action: string | null): Map<string, Object | null> {
  return new Map<string, Object | null>([['supported', supported], ['computePermission', permission],
    ['permissionStatus', status], ['error', error], ['actionRequired', action]]);
}

export function backgroundComputeStatus(accessTokenId: number): Map<string, Object | null> {
  const supported = canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.ContinuousTask');
  if (!canIUse('SystemCapability.Security.AccessToken')) {
    return computeStatus(supported, 'unknown', 'unknown', 'ohos_background_permission_unknown', 'retry_on_supported_device');
  }
  try {
    const manager = abilityAccessCtrl.createAtManager();
    const grant = manager.checkAccessTokenSync(accessTokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING');
    if (grant === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
      return computeStatus(supported, 'denied', 'permission_required', 'ohos_background_permission_required', 'install_background_entitled_build');
    }
    if (grant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return computeStatus(supported, 'unknown', 'unknown', 'ohos_background_permission_unknown', 'retry_permission_check');
    }
    if (!supported) return computeStatus(false, 'unknown', 'unsupported', 'ohos_background_unsupported', 'keep_app_foreground_or_use_remote_host');
    const systemGrant = manager.checkAccessTokenSync(accessTokenId, 'ohos.permission.KEEP_BACKGROUND_RUNNING_SYSTEM');
    if (systemGrant === abilityAccessCtrl.GrantStatus.PERMISSION_DENIED) {
      // TASK_KEEPING needs a restricted entitlement in the signed distribution,
      // not a runtime permission dialog that the user can approve here.
      return computeStatus(true, 'denied', 'eligibility_required', 'ohos_background_eligibility_required', 'obtain_task_keeping_acl_and_install_entitled_build');
    }
    if (systemGrant !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
      return computeStatus(true, 'unknown', 'unknown', 'ohos_background_permission_unknown', 'retry_permission_check');
    }
    const request = new backgroundTaskManager.ContinuousTaskRequest();
    request.backgroundTaskModes = [backgroundTaskManager.BackgroundTaskMode.MODE_TASK_KEEPING];
    const modeSupported = request.isModeSupported();
    if (modeSupported === true) return computeStatus(true, 'granted', 'eligible', null, null);
    if (modeSupported === false) {
      return computeStatus(true, 'denied', 'mode_unsupported', 'ohos_background_mode_unsupported', 'verify_task_keeping_acl_and_ability_configuration');
    }
  } catch (_) {
    // 9800005 combines mode/ACL/configuration failures; it is not a user denial.
  }
  return computeStatus(supported, 'unknown', 'unknown', 'ohos_background_permission_unknown', 'retry_permission_check');
}

// Legacy lifecycle protocol: granted means eligibility only, never an OS lease.
export function backgroundComputePermission(accessTokenId: number): string {
  return backgroundComputeStatus(accessTokenId).get('computePermission') as string;
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
