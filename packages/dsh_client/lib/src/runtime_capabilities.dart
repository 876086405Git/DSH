/// Optional engine capability protocol v1. This describes the connected Host,
/// not the operating system of the App or whether a native channel exists.
library;

import 'carrier.dart';
import 'errors.dart';
import 'json.dart';
import 'session_api.dart';

const runtimeCapabilitiesPath = '/dsh-go/v1/runtime-capabilities';

enum RuntimeSupport { supported, unsupported, unknown }

enum RuntimeShellKind { virtual, system, none, unknown }

enum RuntimeNodeScripts { worker, workerRebased, process, none, unknown }

enum RuntimeNativeModuleState { loaded, packaged, unavailable, unknown }

enum RuntimeSessionLock { kernel, mainThread, none, unknown }

enum RuntimeBackgroundPolicy { mayFreeze, unrestricted, unknown }

enum RuntimeComputePermission { granted, denied, unknown }

enum RuntimeResume { reconcile, none, unknown }

enum RuntimePublicationAtomic { untried, trying, available, unsupported, disabledAfterCrash, unknown }

T _enum<T extends Enum>(Object? value, List<T> values, T unknown) =>
    values.where((entry) => entry.name == value).firstOrNull ?? unknown;
RuntimeSupport _support(Object? value) => _enum(value, RuntimeSupport.values, RuntimeSupport.unknown);
String? _text(Object? value) => value is String && value.trim().isNotEmpty ? value : null;

List<String>? _commands(Object? value) {
  if (value is! List || value.any((entry) => entry is! String)) return null;
  return List<String>.unmodifiable(value.cast<String>());
}

class RuntimeShellCapabilities {
  const RuntimeShellCapabilities({
    this.kind = RuntimeShellKind.unknown,
    this.commands,
    this.pty = RuntimeSupport.unknown,
  });

  factory RuntimeShellCapabilities.fromJson(Object? value) {
    final map = asMapOrEmpty(value);
    return RuntimeShellCapabilities(
      kind: _enum(map['kind'], RuntimeShellKind.values, RuntimeShellKind.unknown),
      commands: _commands(map['commands']),
      pty: _support(map['pty']),
    );
  }

  final RuntimeShellKind kind;

  /// Null means unknown; an empty list means the Host reported no commands.
  final List<String>? commands;
  final RuntimeSupport pty;
}

class RuntimePluginCapabilities {
  const RuntimePluginCapabilities({this.bundled = RuntimeSupport.unknown, this.marketInstall = RuntimeSupport.unknown});

  factory RuntimePluginCapabilities.fromJson(Object? value) {
    final map = asMapOrEmpty(value);
    return RuntimePluginCapabilities(bundled: _support(map['bundled']), marketInstall: _support(map['marketInstall']));
  }

  final RuntimeSupport bundled;
  final RuntimeSupport marketInstall;
}

class RuntimeNativeModule {
  const RuntimeNativeModule({required this.name, this.version, this.state = RuntimeNativeModuleState.unknown});

  final String name;
  final String? version;
  final RuntimeNativeModuleState state;
}

List<RuntimeNativeModule>? _nativeModules(Object? value) {
  if (value is! List) return null;
  final modules = <String, RuntimeNativeModule>{};
  for (final row in value) {
    final map = asMap(row);
    final name = _text(map?['name']);
    // An unnamed row cannot safely be turned into a known empty inventory.
    if (map == null || name == null) return null;
    modules[name] = modules.containsKey(name)
        ? RuntimeNativeModule(name: name)
        : RuntimeNativeModule(
            name: name,
            version: _text(map['version']),
            state: _enum(map['state'], RuntimeNativeModuleState.values, RuntimeNativeModuleState.unknown),
          );
  }
  return List.unmodifiable(modules.values);
}

class RuntimeStorageCapabilities {
  const RuntimeStorageCapabilities({this.sessionLock = RuntimeSessionLock.unknown});

  factory RuntimeStorageCapabilities.fromJson(Object? value) => RuntimeStorageCapabilities(
    sessionLock: switch (asMap(value)?['sessionLock']) {
      'kernel' => RuntimeSessionLock.kernel,
      'main-thread' => RuntimeSessionLock.mainThread,
      'none' => RuntimeSessionLock.none,
      _ => RuntimeSessionLock.unknown,
    },
  );

  final RuntimeSessionLock sessionLock;
}

class RuntimeBackgroundCapabilities {
  const RuntimeBackgroundCapabilities({
    this.policy = RuntimeBackgroundPolicy.unknown,
    this.computePermission = RuntimeComputePermission.unknown,
    this.resume = RuntimeResume.unknown,
  });

  factory RuntimeBackgroundCapabilities.fromJson(Object? value) {
    final map = asMapOrEmpty(value);
    return RuntimeBackgroundCapabilities(
      policy: switch (map['policy']) {
        'may-freeze' => RuntimeBackgroundPolicy.mayFreeze,
        'unrestricted' => RuntimeBackgroundPolicy.unrestricted,
        _ => RuntimeBackgroundPolicy.unknown,
      },
      computePermission: _enum(
        map['computePermission'],
        RuntimeComputePermission.values,
        RuntimeComputePermission.unknown,
      ),
      resume: _enum(map['resume'], RuntimeResume.values, RuntimeResume.unknown),
    );
  }

  final RuntimeBackgroundPolicy policy;
  final RuntimeComputePermission computePermission;
  final RuntimeResume resume;
}

class RuntimePublicationCapabilities {
  const RuntimePublicationCapabilities({this.atomic = RuntimePublicationAtomic.unknown, this.systemVersion});

  factory RuntimePublicationCapabilities.fromJson(Object? value) {
    final map = asMapOrEmpty(value);
    return RuntimePublicationCapabilities(
      atomic: switch (map['atomic']) {
        'untried' => RuntimePublicationAtomic.untried,
        'trying' => RuntimePublicationAtomic.trying,
        'available' => RuntimePublicationAtomic.available,
        'unsupported' => RuntimePublicationAtomic.unsupported,
        'disabled-after-crash' => RuntimePublicationAtomic.disabledAfterCrash,
        _ => RuntimePublicationAtomic.unknown,
      },
      systemVersion: _text(map['systemVersion']),
    );
  }

  /// A fuse observation, not a guarantee that the next write will be atomic.
  /// disabledAfterCrash records an unfinished attempt, not its cause of death.
  final RuntimePublicationAtomic atomic;
  final String? systemVersion;
}

class RuntimeCapabilities {
  const RuntimeCapabilities({
    this.bootId,
    this.platform,
    this.arch,
    this.nodeVersion,
    this.simulated,
    this.shell = const RuntimeShellCapabilities(),
    this.processSpawn = RuntimeSupport.unknown,
    this.nodeScripts = RuntimeNodeScripts.unknown,
    this.python = RuntimeSupport.unknown,
    this.wasm = RuntimeSupport.unknown,
    this.plugins = const RuntimePluginCapabilities(),
    this.nativeModules,
    this.storage = const RuntimeStorageCapabilities(),
    this.background = const RuntimeBackgroundCapabilities(),
    this.publication = const RuntimePublicationCapabilities(),
  });

  /// Only v1 is understood. Missing, malformed or future versions return null;
  /// malformed optional fields become unknown without discarding valid fields.
  static RuntimeCapabilities? fromJson(Object? value) {
    final map = asMap(value);
    if (map == null || map['v'] is! int || map['v'] != 1) return null;
    return RuntimeCapabilities(
      bootId: _text(map['bootId']),
      platform: _text(map['platform']),
      arch: _text(map['arch']),
      nodeVersion: _text(map['nodeVersion']),
      simulated: asBool(map['simulated']),
      shell: RuntimeShellCapabilities.fromJson(map['shell']),
      processSpawn: _support(map['processSpawn']),
      nodeScripts: switch (map['nodeScripts']) {
        'worker' => RuntimeNodeScripts.worker,
        'worker-rebased' => RuntimeNodeScripts.workerRebased,
        'process' => RuntimeNodeScripts.process,
        'none' => RuntimeNodeScripts.none,
        _ => RuntimeNodeScripts.unknown,
      },
      python: _support(map['python']),
      wasm: _support(map['wasm']),
      plugins: RuntimePluginCapabilities.fromJson(map['plugins']),
      nativeModules: _nativeModules(map['nativeModules']),
      storage: RuntimeStorageCapabilities.fromJson(map['storage']),
      background: RuntimeBackgroundCapabilities.fromJson(map['background']),
      publication: RuntimePublicationCapabilities.fromJson(map['publication']),
    );
  }

  /// Identifies this engine instance, scoped to this connection. Do not reuse a
  /// snapshot after reconnect or across Hosts, even if their platform matches.
  final String? bootId;
  final String? platform;
  final String? arch;
  final String? nodeVersion;
  final bool? simulated;
  final RuntimeShellCapabilities shell;
  final RuntimeSupport processSpawn;
  final RuntimeNodeScripts nodeScripts;
  final RuntimeSupport python;
  final RuntimeSupport wasm;
  final RuntimePluginCapabilities plugins;
  final List<RuntimeNativeModule>? nativeModules;
  final RuntimeStorageCapabilities storage;
  final RuntimeBackgroundCapabilities background;
  final RuntimePublicationCapabilities publication;
}

extension RuntimeCapabilitiesApi on DshClient {
  /// The relay carrier has no arbitrary HTTP routes. It must not be confused
  /// with an old Host that answers 404 or an absent native App channel.
  bool get canReadRuntimeCapabilities => carrier is DshHttpCarrier;

  /// Read after authentication/$events readiness, reconnect, or foreground
  /// connection revalidation. This method has no cache and changes no existing
  /// connection/host-availability state. Unknown never means unsupported.
  ///
  /// Returns null on 404/405/501 or a future major version. Authentication,
  /// server, transport and malformed-response failures remain typed errors.
  Future<RuntimeCapabilities?> readRuntimeCapabilities({Duration timeout = const Duration(seconds: 10)}) async {
    final carrier = this.carrier;
    if (carrier is! DshHttpCarrier) {
      throw const DshRemoteException(
        'runtime-capabilities/transport-unavailable',
        'This carrier cannot read Host HTTP routes',
      );
    }
    final response = await carrier.connection.get(
      runtimeCapabilitiesPath,
      maxResponseBytes: 128 * 1024,
      followRedirects: false,
      timeout: timeout,
    );
    if ({404, 405, 501}.contains(response.statusCode)) return null;
    if (response.statusCode != 200) {
      throw DshHttpException(response.statusCode, '$runtimeCapabilitiesPath: HTTP ${response.statusCode}');
    }
    final map = asMap(tryDecodeJson(response.text));
    if (response.contentType != 'application/json' || map == null || map['v'] is! int || (map['v'] as int) < 1) {
      throw const DshProtocolException('$runtimeCapabilitiesPath: not a versioned capability object');
    }
    return RuntimeCapabilities.fromJson(map);
  }
}
