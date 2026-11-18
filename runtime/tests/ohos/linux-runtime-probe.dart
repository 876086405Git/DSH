import 'dart:convert';

import 'package:flutter/services.dart';

import 'ohos_linux_runtime.dart';

final checks = <String>[];
void check(String name, bool passed) {
  if (!passed) throw StateError(name);
  checks.add(name);
}

Map<String, Object?> status([Map<String, Object?> extra = const {}]) => {
  'v': 1,
  'instanceId': 'service-930',
  'attemptId': 'attempt-930',
  'state': 'enabled',
  'enabled': true,
  'admission': true,
  'guestOpened': true,
  'ownerRetained': true,
  'workspaceLease': false,
  'restartRequired': false,
  'shutdownComplete': false,
  'nextRequestId': 4,
  'ownerState': 'active',
  'backendState': 'opened',
  'progress': null,
  'lastErrorCode': null,
  'job': null,
  'retirement': null,
  ...extra,
};
Map<String, Object?> output(
  List<int> bytes, {
  int? total,
  bool truncated = false,
}) => {
  'encoding': 'base64',
  'data': base64Encode(bytes),
  'totalBytes': total ?? bytes.length,
  'retainedBytes': bytes.length,
  'truncated': truncated,
};
Map<String, Object?> job([Map<String, Object?> extra = const {}]) => {
  'id': 3,
  'state': 'running',
  'started': true,
  'cancelRequested': false,
  'outcome': null,
  'errorCode': null,
  'stdout': output([0, 255, 226, 130]),
  'stderr': output([]),
  ...extra,
};
Map<String, Object?> retirement([Map<String, Object?> extra = const {}]) => {
  'resourcesRetired': true,
  'filesRemoved': false,
  'dataRetained': true,
  'ownerQuarantined': true,
  'native': {'joined': true, 'retirementError': false, 'apiResult': -4},
  'releaseErrorCode': null,
  ...extra,
};
bool rejects(Map<String, Object?> value) {
  try {
    OhosLinuxSnapshot.fromWire(jsonEncode(value));
    return false;
  } on FormatException {
    return true;
  }
}

Future<void> main() async {
  final diagnostic = <String, Object>{
    'category': 'tls-interrupted',
    'evidence': 'stderr',
    'message': '命令输出提示 TLS 连接被中途断开。请检查网络或代理；仅凭此输出无法判断断开方。',
  };
  check(
    'an unfinished job cannot carry a failure diagnostic',
    rejects(
      status({
        'job': job({'diagnostic': diagnostic}),
      }),
    ),
  );
  final failedJob = job({
    'state': 'settled',
    'outcome': {'exitCode': 128, 'signal': null, 'cancelled': false},
    'diagnostic': diagnostic,
  });
  final dynamic failed = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'job': failedJob})),
  );
  check(
    'actual consumer retains the classified fixed message and original exit128',
    failed.job.diagnostic.category == 'tls-interrupted' &&
        failed.job.diagnostic.evidence == 'stderr' &&
        failed.job.diagnostic.message == diagnostic['message'] &&
        failed.job.outcome.exitCode == 128,
  );
  for (final invalid in <Map<String, Object?>>[
    {
      'diagnostic': {...diagnostic, 'category': 'provider-is-blocking'},
    },
    {
      'diagnostic': {...diagnostic, 'evidence': 'none'},
    },
    {
      'outcome': {'exitCode': 0, 'signal': null, 'cancelled': false},
    },
    {
      'outcome': {'exitCode': null, 'signal': 'SIGKILL', 'cancelled': true},
    },
    {
      'outcome': {
        'exitCode': 128,
        'signal': null,
        'cancelled': false,
        'notStarted': true,
      },
    },
  ]) {
    check(
      'contradictory diagnostic rejected: ${jsonEncode(invalid)}',
      rejects(
        status({
          'job': {...failedJob, ...invalid},
        }),
      ),
    );
  }
  final dynamic legacyJob = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'job': job()})),
  );
  check(
    'old job snapshots retain absent diagnostic',
    legacyJob.job.diagnostic == null,
  );

  check(
    'native memory cannot claim that join freed the heap',
    rejects(status({'nativeMemoryRelease': 'freed'})),
  );
  for (final bad in <Object>[false, 85, <String, Object>{}]) {
    check(
      'native memory release has a fixed protocol value: $bad',
      rejects(status({'nativeMemoryRelease': bad})),
    );
  }
  final dynamic memory = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'nativeMemoryRelease': 'process-exit'})),
  );
  check(
    'native memory release and Chinese explanation survive the actual consumer',
    memory.nativeMemoryRelease == 'process-exit' &&
        memory.nativeMemoryNotice.contains('整个 App 进程'),
  );
  final dynamic legacyMemory = OhosLinuxSnapshot.fromWire(jsonEncode(status()));
  check(
    'missing memory fact remains unknown, not a freed claim',
    legacyMemory.nativeMemoryRelease == null &&
        legacyMemory.nativeMemoryNotice == null,
  );

  check(
    'proxy status cannot carry private configuration strings',
    rejects(
      status({
        'proxy': {
          'source': 'manual',
          'revision': 1,
          'httpConfigured': true,
          'httpsConfigured': true,
          'httpProxy': 'http://private.invalid:3128',
        },
      }),
    ),
  );
  check(
    'clean checkpoint without guest sync is rejected',
    rejects(
      status({
        'retirement': retirement({'cleanCheckpoint': true}),
      }),
    ),
  );
  final guestClose = {
    'epoch': List.filled(64, 'b').join(),
    'rootfsSync': true,
    'syncMethod': 'syncfs',
    'syncScope': 'rootfs',
  };
  final persistent = {
    'persistentInstanceId': '2f887aa7-437e-49b6-bbde-4e30d899d3cc',
    'bootMode': 'resume',
    'shutdownComplete': true,
  };
  final clean = retirement({'guestClose': guestClose, 'cleanCheckpoint': true});
  final resumed = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({...persistent, 'retirement': clean})),
  );
  check(
    'persistent identity, resume and guest sync survive channel decoding',
    resumed.persistentInstanceId == persistent['persistentInstanceId'] &&
        resumed.bootMode == 'resume' &&
        resumed.retirement!.guestClose!.epoch == guestClose['epoch'] &&
        resumed.retirement!.cleanCheckpoint,
  );
  final uncommitted = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        ...persistent,
        'retirement': {
          ...clean,
          'cleanCheckpoint': false,
          'releaseErrorCode': 'EIO',
        },
      }),
    ),
  );
  check(
    'retired synchronized guest does not imply committed checkpoint',
    uncommitted.shutdownComplete &&
        uncommitted.retirement!.guestClose != null &&
        !uncommitted.retirement!.cleanCheckpoint &&
        uncommitted.retirement!.releaseErrorCode == 'EIO',
  );
  for (final extra in <Map<String, Object?>>[
    {
      'guestClose': {...guestClose, 'rootfsSync': false},
    },
    {
      'guestClose': {...guestClose, 'epoch': 'old'},
    },
    {
      'guestClose': {...guestClose, 'syncMethod': 'sync'},
    },
    {
      'guestClose': {...guestClose, 'syncScope': 'all'},
    },
    {'resourcesRetired': false},
    {'dataRetained': false},
    {'filesRemoved': true},
    {'native': null},
    {
      'native': {'joined': true, 'retirementError': false, 'apiResult': 0},
    },
  ]) {
    check(
      'inconsistent clean checkpoint rejected: ${jsonEncode(extra)}',
      rejects(
        status({
          ...persistent,
          'retirement': {...clean, ...extra},
        }),
      ),
    );
  }
  check(
    'clean checkpoint needs persistent identity',
    rejects(status({'retirement': clean})),
  );
  check(
    'boot mode cannot masquerade as a new install',
    rejects(status({...persistent, 'bootMode': 'unknown'})),
  );
  final scope = OhosLinuxSnapshot.fromWire(jsonEncode(status()));
  check('legacy proxy facts remain absent', scope.proxy == null);
  final proxyFacts = {
    'source': 'manual',
    'revision': 3,
    'httpConfigured': true,
    'httpsConfigured': true,
  };
  final proxyObservation = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'proxy': proxyFacts,
        'job': job({'proxyRevision': 2}),
      }),
    ),
  );
  check(
    'current proxy configuration and accepted job revision stay separate',
    proxyObservation.proxy!.source == OhosLinuxProxyMode.manual &&
        proxyObservation.proxy!.revision == 3 &&
        proxyObservation.job!.proxyRevision == 2,
  );
  for (final extra in <Map<String, Object?>>[
    {'source': 'future'},
    {'revision': -1},
    {'revision': 9007199254740992},
    {'httpConfigured': 'yes'},
    {'source': 'direct'},
    {'httpConfigured': false, 'httpsConfigured': false},
    {'noProxy': 'private.invalid'},
  ]) {
    check(
      'invalid or private proxy status rejected ${checks.length}',
      rejects(
        status({
          'proxy': {...proxyFacts, ...extra},
        }),
      ),
    );
  }
  check(
    'unsafe job proxy revision rejected',
    rejects(
      status({
        'job': job({'proxyRevision': 9007199254740992}),
      }),
    ),
  );
  check(
    'opened private guest admits explicit jobs without granting host workspace',
    scope.admission && !scope.workspaceLease,
  );
  final installing = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'state': 'installing', 'guestOpened': false})),
  );
  check('installation acceptance is not admission', !installing.admission);
  final future = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'state': 'future-state'})),
  );
  check(
    'future state fails closed',
    future.state == OhosLinuxState.unknown && !future.admission,
  );
  final running = OhosLinuxSnapshot.fromWire(
    jsonEncode(status({'job': job()})),
  );
  check(
    'binary tail retains NUL, non-UTF8 and partial UTF8 without replacing bytes',
    base64Encode(running.job!.stdout.bytes) ==
            base64Encode([0, 255, 226, 130]) &&
        !running.job!.settled,
  );
  bool immutable = false;
  try {
    running.job!.stdout.bytes[0] = 1;
  } on UnsupportedError {
    immutable = true;
  }
  check('output observation is immutable', immutable);
  final cancelled = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'job': job({
          'state': 'settled',
          'cancelRequested': true,
          'outcome': {
            'exitCode': null,
            'signal': 'SIGKILL',
            'cancelled': true,
            'requestedSignal': 'SIGTERM',
          },
        }),
      }),
    ),
  );
  check(
    'actual signal and requested signal remain separate',
    cancelled.job!.outcome!.signal == 'SIGKILL' &&
        cancelled.job!.outcome!.requestedSignal == 'SIGTERM' &&
        cancelled.job!.outcome!.exitCode == null,
  );
  final unknown = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'state': 'unknown',
        'job': job({'state': 'unknown'}),
        'shutdownComplete': true,
        'retirement': retirement(),
      }),
    ),
  );
  check(
    'historical job unknown survives proven resource retirement',
    unknown.job!.state == 'unknown' &&
        unknown.job!.outcome == null &&
        unknown.shutdownComplete &&
        unknown.retirement!.dataRetained &&
        !unknown.retirement!.filesRemoved,
  );
  check(
    'false join cannot confirm shutdown',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {'joined': false, 'retirementError': false, 'apiResult': 0},
        }),
      }),
    ),
  );
  check(
    'retirement error cannot confirm shutdown',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {'joined': true, 'retirementError': true, 'apiResult': -8},
        }),
      }),
    ),
  );
  check(
    'unobserved retirement cannot confirm shutdown',
    rejects(status({'shutdownComplete': true})),
  );
  final unjoined = OhosLinuxSnapshot.fromWire(
    jsonEncode(
      status({
        'state': 'unknown',
        'retirement': retirement({
          'resourcesRetired': false,
          'native': {
            'joined': false,
            'retirementError': null,
            'apiResult': null,
          },
        }),
      }),
    ),
  );
  check(
    'actual unjoined native null facts remain visible',
    unjoined.retirement!.nativeJoined == false &&
        unjoined.retirement!.nativeRetirementError == null &&
        unjoined.retirement!.nativeApiResult == null &&
        !unjoined.shutdownComplete,
  );
  check(
    'missing retirement error fact cannot confirm even a joined native',
    rejects(
      status({
        'shutdownComplete': true,
        'retirement': retirement({
          'native': {
            'joined': true,
            'retirementError': null,
            'apiResult': null,
          },
        }),
      }),
    ),
  );
  check(
    'unknown protocol version cannot grant admission',
    rejects(status({'v': 2})),
  );
  check(
    'host workspace grant cannot be inferred',
    rejects(status({'workspaceLease': true})),
  );
  check(
    'unsafe request integer rejected',
    rejects(status({'nextRequestId': 9007199254740992})),
  );
  check(
    'output metadata mismatch rejected',
    rejects(
      status({
        'job': job({
          'stdout': {
            ...output([1]),
            'retainedBytes': 2,
          },
        }),
      }),
    ),
  );
  check(
    'unknown job cannot carry fabricated success',
    rejects(
      status({
        'job': job({
          'state': 'unknown',
          'outcome': {'exitCode': 0, 'signal': null, 'cancelled': false},
        }),
      }),
    ),
  );

  final calls = <Map<String, Object?>>[];
  MethodChannel.handler = (channel, method, arguments) async {
    calls.add({'channel': channel, 'method': method, 'arguments': arguments});
    return jsonEncode(status());
  };
  const client = OhosLinuxRuntime();
  await client.getStatus();
  await client.setEnabled(false);
  final argv = ['python3', '-c', 'print("中文")'];
  await client.runPrivateGuest(
    scope: scope,
    argv: argv,
    cwd: '/workspace',
    environment: {'TEST_VALUE': 'a b'},
    stdin: 'input\n',
  );
  await client.runPrivateGuest(
    scope: scope,
    argv: argv,
    cwd: '/workspace',
    environment: {'TEST_VALUE': 'a b'},
    stdin: 'input\n',
  );
  check(
    'uses existing OH runtime MethodChannel with no host URL or token argument',
    calls.every((row) => row['channel'] == 'dsh/runtime') &&
        calls.first['method'] == 'getLinuxStatus' &&
        calls.first['arguments'] == null,
  );
  check(
    'switch false is explicit',
    (calls[1]['arguments'] as Map)['enabled'] == false,
  );
  check(
    'retry keeps the original identity, argv and private cwd',
    jsonEncode(calls[2]) == jsonEncode(calls[3]) &&
        (calls[2]['arguments'] as Map)['requestId'] == 4 &&
        (calls[2]['arguments'] as Map)['cwd'] == '/workspace',
  );
  await client.setProxy(
    const OhosLinuxProxyConfiguration.manual(
      httpProxy: 'http://127.0.0.1:3128',
      noProxy: 'fixture.invalid',
    ),
  );
  await client.setProxy(const OhosLinuxProxyConfiguration.direct());
  await client.setProxy(const OhosLinuxProxyConfiguration.inherit());
  check(
    'typed proxy configuration uses the existing channel without host endpoint overrides',
    calls[4]['method'] == 'setLinuxProxy' &&
        jsonEncode(calls[4]['arguments']) ==
            jsonEncode({
              'proxy': {
                'mode': 'manual',
                'httpProxy': 'http://127.0.0.1:3128',
                'noProxy': 'fixture.invalid',
              },
            }) &&
        jsonEncode(calls[5]['arguments']) ==
            jsonEncode({
              'proxy': {'mode': 'direct'},
            }) &&
        jsonEncode(calls[6]['arguments']) ==
            jsonEncode({
              'proxy': {'mode': 'inherit'},
            }),
  );
  await client.discardRetained();
  check(
    'reinstall sends no identity, path or switch: the engine reads its own',
    calls[7]['method'] == 'discardLinuxRetained' &&
        calls[7]['channel'] == 'dsh/runtime' &&
        calls[7]['arguments'] == null,
  );
  MethodChannel.handler = (_, __, ___) async =>
      throw PlatformException(code: 'ERR_OHOS_LINUX_RESTART_REQUIRED');
  String? refused;
  try {
    await client.discardRetained();
  } on PlatformException catch (error) {
    refused = error.code;
  }
  check('a refused reinstall keeps the engine code', refused == 'ERR_OHOS_LINUX_RESTART_REQUIRED');
  MethodChannel.handler = (_, __, ___) async =>
      throw PlatformException(code: 'ERR_OHOS_LINUX_STALE');
  bool preserved = false;
  try {
    await client.getStatus();
  } on PlatformException catch (error) {
    preserved = error.code == 'ERR_OHOS_LINUX_STALE';
  }
  check('platform failure code remains inspectable', preserved);
  print(
    jsonEncode({
      'status': 'PASS',
      'checks': checks,
      'calls': calls.length,
      'scope': 'actual Dart model and channel client; explicit Flutter services boundary, not Flutter engine or OH device',
    }),
  );
}
