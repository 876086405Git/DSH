/// Native preferences and actual grants are deliberately separate.
class BackgroundProtection {
  const BackgroundProtection({
    required this.supported,
    this.audioEnabled = false,
    this.locationEnabled = false,
    this.audioActive = false,
    this.locationActive = false,
    this.locationAuthorization,
    this.taskEnabled = false,
    this.taskActive = false,
    this.permissionStatus,
    this.error,
    this.actionRequired,
    this.cleanupPending = false,
  });

  static BackgroundProtection? fromMap(Map<Object?, Object?>? map) => map == null
      ? null
      : BackgroundProtection(
          supported: map['supported'] == true,
          audioEnabled: map['audioEnabled'] == true,
          locationEnabled: map['locationEnabled'] == true,
          audioActive: map['audioActive'] == true,
          locationActive: map['locationActive'] == true,
          locationAuthorization: map['locationAuthorization'] as String?,
          taskEnabled: map['taskEnabled'] == true,
          taskActive: map['taskActive'] == true,
          permissionStatus: map['permissionStatus'] as String?,
          error: map['error'] as String?,
          actionRequired: map['actionRequired'] as String?,
          cleanupPending: map['cleanupPending'] == true,
        );

  final bool supported;
  final bool audioEnabled;
  final bool locationEnabled;
  final bool audioActive;
  final bool locationActive;
  final String? locationAuthorization;
  final bool taskEnabled;
  final bool taskActive;
  final String? permissionStatus;
  final String? error;
  final String? actionRequired;
  final bool cleanupPending;

  bool get hasError => error != null && error!.isNotEmpty;
}
