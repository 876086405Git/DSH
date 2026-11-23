// Manual Android entry point. Not a test and never registered in CI.
// Only a public claim commitment goes to bootstrap; secret and key stay in memory.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart' as crypto;
import 'package:dsh_app/companion/companion_agent.dart';
import 'package:dsh_app/companion/companion_agent_task_tools.dart';
import 'package:dsh_app/companion/companion_agent_task_ui.dart';
import 'package:dsh_app/companion/companion_agent_tools.dart';
import 'package:dsh_app/companion/companion_context.dart';
import 'package:dsh_app/companion/companion_host_tasks.dart';
import 'package:dsh_app/companion/companion_light.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_maps.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_app/companion/companion_memory_id.dart';
import 'package:dsh_app/companion/companion_reminder.dart';
import 'package:dsh_app/companion/companion_state.dart';
import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:sqlite3/sqlite3.dart';

typedef _Binding = ({
  CompanionAgentTool definition,
  Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute,
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: _ReplayPage()));
}

class _ReplayPage extends StatefulWidget {
  const _ReplayPage();
  @override
  State<_ReplayPage> createState() => _ReplayPageState();
}

class _ReplayPageState extends State<_ReplayPage> {
  String status = 'Preparing the manual replay…';
  _Replay? replay;
  HttpClient? configurationClient;
  bool cancelled = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(start()));
  }

  Future<void> start() async {
    if (!mounted || cancelled) return;
    try {
      final random = math.Random.secure();
      final claimSecret = base64UrlEncode(List<int>.generate(32, (_) => random.nextInt(256)));
      final file = File('${Directory.systemTemp.path}/dsh-a3-config.json');
      final ready = {'path': file.path, 'claimHash': crypto.sha256.convert(utf8.encode(claimSecret)).toString()};
      debugPrint('A3_CONFIG_READY:${jsonEncode(ready)}');
      late final Map<String, Object?> config;
      try {
        final waiting = Stopwatch()..start();
        while (!await file.exists()) {
          if (!mounted || cancelled) return;
          if (waiting.elapsed >= const Duration(seconds: 15)) {
            throw StateError('Use tooling/companion/run_agent_a3.py');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        if (!mounted || cancelled) return;
        config = Map<String, Object?>.from(jsonDecode(await file.readAsString()) as Map);
      } finally {
        if (await file.exists()) await file.delete();
      }
      if (!mounted || cancelled) return;
      config['key'] = await takeKey(config, claimSecret);
      if (!mounted || cancelled) return;
      replay = _Replay(config, (value) {
        if (mounted) setState(() => status = value);
      });
      await replay!.run();
    } on Object {
      if (!mounted || cancelled) return;
      if (mounted) setState(() => status = 'ENV_UNAVAILABLE: manual configuration or device capability');
      // Configuration, key, response body and request headers never reach stdout.
      debugPrint('A3_ENV_UNAVAILABLE');
    }
  }

  Future<String> takeKey(Map<String, Object?> config, String claimSecret) async {
    final handoff = Map<String, Object?>.from(config.remove('keyHandoff')! as Map);
    final port = handoff['port'];
    if (port is! int ||
        port < 1 ||
        port > 65535 ||
        handoff['claimHash'] != crypto.sha256.convert(utf8.encode(claimSecret)).toString()) {
      throw StateError('Invalid local key handoff');
    }
    final client = HttpClient()
      ..findProxy = ((_) => 'DIRECT')
      ..connectionTimeout = const Duration(seconds: 5);
    configurationClient = client;
    try {
      return await (() async {
        if (!mounted || cancelled) throw StateError('Manual configuration stopped');
        final request = await client.postUrl(Uri(scheme: 'http', host: '127.0.0.1', port: port, path: '/a3-key'));
        request.followRedirects = false;
        request.contentLength = 0;
        request.headers.set('X-DSH-A3-Token', claimSecret);
        if (!mounted || cancelled) throw StateError('Manual configuration stopped');
        final response = await request.close();
        if (response.statusCode != HttpStatus.ok) throw StateError('Local key handoff failed');
        final data = Map<String, Object?>.from(jsonDecode(await response.transform(utf8.decoder).join()) as Map);
        final key = data['key'];
        if (!mounted || cancelled || data['runId'] != config['runId'] || key is! String || key.trim().isEmpty) {
          throw StateError('Local key handoff was not current');
        }
        return key;
      })().timeout(
        const Duration(seconds: 15),
        onTimeout: () {
          client.close(force: true);
          throw TimeoutException('Local key handoff expired');
        },
      );
    } finally {
      client.close(force: true);
      if (identical(configurationClient, client)) configurationClient = null;
    }
  }

  @override
  void dispose() {
    cancelled = true;
    configurationClient?.close(force: true);
    if (replay == null) debugPrint('A3_STOPPED_BEFORE_START');
    replay?.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Manual companion replay')),
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('This manual target uses the real model and incurs API usage.'),
          const SizedBox(height: 16),
          SelectableText(status),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              cancelled = true;
              configurationClient?.close(force: true);
              if (replay == null) {
                debugPrint('A3_STOPPED_BEFORE_START');
                setState(() => status = 'Stopped before model replay started.');
              }
              replay?.stop();
            },
            child: const Text('Stop'),
          ),
        ],
      ),
    ),
  );
}

class _Replay {
  _Replay(this.config, this.progress);
  final Map<String, Object?> config;
  final void Function(String) progress;
  final native = const CompanionReminders();
  final maps = const CompanionMaps();
  late final String key = config['key']! as String;
  late final Directory output;
  late final File events;
  final rows = <Map<String, Object?>>[];
  final checks = <Map<String, Object?>>[];
  final human = StringBuffer('# A3 human sample review\n\n');
  CompanionAgent? agent;
  void Function()? cancelTurn;
  bool stopped = false;
  int httpCount = 0;
  int sequence = 0;
  String? caseId;
  int? turnNumber;

  void stop() {
    stopped = true;
    cancelTurn?.call();
    agent?.stop();
  }

  Object? decode(String text) {
    try {
      return jsonDecode(text);
    } on FormatException {
      return text;
    }
  }

  void record(String kind, Map<String, Object?> data) {
    final row = <String, Object?>{
      'seq': ++sequence,
      'at': DateTime.now().toUtc().toIso8601String(),
      'case': caseId,
      'turn': turnNumber,
      'kind': kind,
      ...data,
    };
    final safe = jsonEncode(row).replaceAll(key, '[REDACTED_API_KEY]');
    rows.add(Map<String, Object?>.from(jsonDecode(safe) as Map));
    events.writeAsStringSync('$safe\n', mode: FileMode.append, flush: true);
  }

  http.Client client({required bool Function() isCurrent, required bool agentRequest}) => _RecordingClient(
    http.Client(),
    before: (request) {
      if (stopped || !isCurrent()) throw StateError('Manual replay turn stopped');
      if (httpCount >= (config['maxHttp']! as int)) throw StateError('Manual HTTP limit reached');
      httpCount++;
      record('http_request', {
        'http': httpCount,
        'agentRequest': agentRequest,
        'method': request.method,
        'uri': request.url.toString(),
        'body': decode(request.body),
      });
      return httpCount;
    },
    after: (id, status, body, complete) {
      record('http_response', {'http': id, 'status': status, 'body': body, 'streamComplete': complete});
      if (agentRequest) {
        for (final call in _requestedTools(body)) {
          record('model_tool_request', {'http': id, ...call});
        }
      }
    },
  );

  Future<void> run() async {
    if (key.trim().isEmpty) throw StateError('DEEPSEEK_API_KEY missing');
    output = await Directory.systemTemp.createTemp('dsh-a3-${config['runId']}-');
    events = File('${output.path}/events.jsonl');
    record('run_start', {
      'schema': 1,
      'runId': config['runId'],
      'fixture': config['fixture'],
      'parent': config['parent'],
      'manual': true,
      'capabilityScope': 'actual memory tools, task_status and public_lookup',
      'notCovered': ['native alarm delivery', 'Host file tasks', '4e phone actions', 'Page UI'],
    });
    debugPrint('A3_STARTED:${jsonEncode({'runId': config['runId'], 'directory': output.path})}');
    final fixture = Map<String, Object?>.from(config['cases']! as Map);
    final cases = (fixture['cases']! as List).cast<Map>();
    final selected = (config['only']! as List).cast<String>().toSet();
    CompanionReminderClock? clock;
    try {
      clock = await native.clock();
      final executor = await native.executorId();
      record('environment', {
        'clock': {'utcMs': clock.utcMs, 'zoneId': clock.zoneId, 'offsetSeconds': clock.offsetSeconds},
        'executorId': executor,
        'platform': Platform.operatingSystem,
      });
    } on Object catch (error) {
      clock = null;
      record('environment_unavailable', {'error': '$error'});
    }
    for (final item in cases) {
      if (selected.isNotEmpty && !selected.contains(item['id'])) continue;
      caseId = item['id']! as String;
      turnNumber = null;
      if (clock == null) {
        checks.add({'case': caseId, 'status': 'ENV_UNAVAILABLE', 'reason': 'native_clock_or_executor'});
        continue;
      }
      if (stopped) {
        checks.add({'case': caseId, 'status': 'INCOMPLETE', 'reason': 'stopped'});
        continue;
      }
      progress('Running ${item['title']}');
      try {
        await scenario(Map<String, Object?>.from(item), await native.clock());
      } on Object catch (error, stack) {
        record('scenario_error', {'error': '$error', 'stack': '$stack'});
        checks.add({'case': caseId, 'status': 'INCOMPLETE', 'reason': '$error'});
      }
    }
    record('run_finished', {'httpRequests': httpCount, 'stopped': stopped});
    final counts = <String, int>{};
    for (final check in checks) {
      final status = check['status']! as String;
      counts[status] = (counts[status] ?? 0) + 1;
    }
    final judgedTurns = checks
        .where((row) => row['turn'] != null && const {'AUTOMATED_PASS', 'FAIL'}.contains(row['status']))
        .toList();
    final passingTurns = judgedTurns.where((row) => row['status'] == 'AUTOMATED_PASS').length;
    final replayOutcome = stopped || (counts['INCOMPLETE'] ?? 0) > 0 ? 'INCOMPLETE' : 'COMPLETE';
    final summary = {
      'schema': 1,
      'runId': config['runId'],
      'parent': config['parent'],
      'fixture': config['fixture'],
      'manual': true,
      'replayOutcome': replayOutcome,
      'counts': counts,
      'httpRequests': httpCount,
      'modelToolRequests': rows.where((r) => r['kind'] == 'model_tool_request').length,
      'adapterDispatches': rows.where((r) => r['kind'] == 'tool_dispatch').length,
      'adapterErrors': rows.where((r) => r['kind'] == 'tool_result' && r['isError'] == true).length,
      'checks': checks,
      'humanReview': 'PENDING_OWNER_SAMPLE_REVIEW',
      'structuralTurnAccuracy': {
        'passed': passingTurns,
        'judged': judgedTurns.length,
        'rate': judgedTurns.isEmpty ? null : passingTurns / judgedTurns.length,
        'excludes': ['ENV_UNAVAILABLE', 'PATH_NOT_EXERCISED', 'INCOMPLETE', 'affinity fixture checks'],
      },
      'humanToolCallAccuracy': null,
      'correctnessMeaning': 'Structural tool checks only; meaning and factual scope require the supplied human rubric.',
    };
    File('${output.path}/summary.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(summary).replaceAll(key, '[REDACTED_API_KEY]')}\n',
      flush: true,
    );
    human.writeln('## Actual requested tool calls\n');
    human.writeln(
      'Mark the sampled calls correct / incorrect / uncertain and cite the raw event. '
      'Report sample size separately from all requested calls.\n',
    );
    human.writeln('| Event | Case | Turn | Tool | Call ID | Human verdict / reason |');
    human.writeln('| --- | --- | --- | --- | --- | --- |');
    String cell(Object? value) => '$value'.replaceAll('|', '\\|').replaceAll('\n', ' ');
    for (final row in rows.where((row) => row['kind'] == 'model_tool_request')) {
      human.writeln(
        '| ${row['seq']} | ${cell(row['case'])} | ${row['turn']} | '
        '${cell(row['name'])} | ${cell(row['id'])} | PENDING |',
      );
    }
    File('${output.path}/human-review.md')
        .writeAsStringSync(human.toString().replaceAll(key, '[REDACTED_API_KEY]'), flush: true);
    progress('Finished. The launcher will collect the three result files.');
    debugPrint(
      'A3_FINISHED:${jsonEncode({'runId': config['runId'], 'directory': output.path, 'replayOutcome': replayOutcome})}',
    );
  }

  Future<void> scenario(Map<String, Object?> item, CompanionReminderClock initial) async {
    var clockBase = initial.utcMs;
    final elapsed = Stopwatch()..start();
    int? historicalNow;
    int nowMilliseconds() => historicalNow ?? clockBase + elapsed.elapsedMilliseconds;
    final offset = initial.offsetSeconds ~/ 60;
    final affinity = item['affinityReplay'] as Map?;
    if (affinity != null) {
      final local = DateTime.fromMillisecondsSinceEpoch(initial.utcMs + offset * 60000, isUtc: true);
      final firstNoon = DateTime.utc(
        local.year,
        local.month,
        local.day,
        12,
      ).subtract(Duration(days: affinity['completeDays']! as int));
      historicalNow = firstNoon.millisecondsSinceEpoch - offset * 60000;
    }
    final database = sqlite3.openInMemory();
    final root = await Directory('${output.path}/${item['id']}').create();
    final memory = CompanionMemoryOwner(
      CompanionMemoryStore(database, nowMilliseconds: nowMilliseconds),
      CompanionLocal.at(root, nowMilliseconds: nowMilliseconds),
      nowMilliseconds: nowMilliseconds,
    );
    final roles = <String, String>{
      for (final role in ['a', 'b'])
        role: memory.store.ensureCompanionCharacter(sourceKey: 'a3:${item['id']}:$role')['id']! as String,
    };
    http.Client Function()? turnClient;
    final currentAgent = CompanionAgent(
      client: () {
        final open = turnClient;
        if (open == null) throw StateError('No active manual replay turn');
        return open();
      },
      apiKey: () => key,
    );
    agent = currentAgent;
    final handoff = CompanionMapHandoff(maps);
    var current = true;
    human.writeln('## ${item['id']} — ${item['title']}\n');
    for (final criterion in (item['human']! as List).cast<String>()) {
      human.writeln('- [ ] $criterion');
    }
    human.writeln('\nReviewer / verdict / evidence event numbers: **PENDING**\n');
    try {
      if (affinity != null) {
        final start = historicalNow!;
        for (var day = 0; day < (affinity['completeDays']! as int); day++) {
          final at = start + day * 86400000;
          historicalNow = at;
          memory.store.recordCompanionPresence(
            characterId: roles['a']!,
            segmentId: 'fixture-presence-$day',
            startedAtMs: at,
            elapsedMs: (affinity['presenceMinutes']! as int) * 60000,
            offsetMinutes: offset,
          );
          for (var turn = 0; turn < (affinity['chatTurns']! as int); turn++) {
            final row = memory.store.submitMessage(
              id: companionMemoryId(),
              sessionId: memory.store.lightSessionId,
              text: '隔离回放第${day + 1}天第${turn + 1}次聊天。',
              saidAtUtc: at,
              offsetMinutes: offset,
              zoneId: initial.zoneId,
              offsetSeconds: initial.offsetSeconds,
              characterId: roles['a'],
            );
            memory.store.recordCompanionInteraction(
              characterId: roles['a']!,
              eventId: row['id']! as String,
              kind: 'chat',
              atMs: at,
              offsetMinutes: offset,
              sourceId: row['id']! as String,
            );
          }
        }
        historicalNow = initial.utcMs;
        memory.store.settleCompanionAffinity(nowMs: initial.utcMs, offsetMinutes: offset);
        final first = memory.store.companionAffinity(characterId: roles['a']!);
        final expectedTier = affinity['expectedTier']! as int;
        final expectedStage = first?['tier'] == expectedTier;
        memory.store.settleCompanionAffinity(nowMs: initial.utcMs, offsetMinutes: offset);
        final second = memory.store.companionAffinity(characterId: roles['a']!);
        final other = memory.store.companionAffinity(characterId: roles['b']!);
        record('affinity_fixture', {
          'syntheticReplayFacts': true,
          'firstSegmentAtMs': start,
          'offsetMinutes': offset,
          'expectedTier': expectedTier,
          'first': first,
          'second': second,
          'otherRole': other,
          'description': 'Public Store facts in an isolated database; not elapsed real user activity.',
        });
        checks.add({
          'case': caseId,
          'check': 'completed-day settlement reaches the expected tier, is idempotent and role-scoped',
          'status': expectedStage && jsonEncode(first) == jsonEncode(second) && other == null
              ? 'AUTOMATED_PASS'
              : 'FAIL',
        });
        historicalNow = null;
      }
      final turns = (item['turns']! as List).cast<Map>();
      for (var index = 0; index < turns.length; index++) {
        turnNumber = index + 1;
        if (stopped) {
          checks.add({'case': caseId, 'turn': turnNumber, 'status': 'INCOMPLETE', 'reason': 'stopped'});
          break;
        }
        final turn = turns[index];
        final realClock = await native.clock();
        clockBase = realClock.utcMs;
        elapsed.reset();
        final now = realClock.utcMs;
        final role = roles[(turn['role'] as String?) ?? 'a']!;
        final before = memory.store.cards(includeInactive: true);
        final source = memory.store.submitMessage(
          id: companionMemoryId(),
          sessionId: memory.store.lightSessionId,
          text: turn['say']! as String,
          saidAtUtc: now,
          offsetMinutes: realClock.offsetSeconds ~/ 60,
          zoneId: realClock.zoneId,
          offsetSeconds: realClock.offsetSeconds,
          characterId: role,
        );
        memory.store.recordCompanionInteraction(
          characterId: role,
          eventId: source['id']! as String,
          kind: 'chat',
          atMs: now,
          offsetMinutes: realClock.offsetSeconds ~/ 60,
          sourceId: source['id']! as String,
        );
        final original = companionTurnContext(
          now: DateTime.fromMillisecondsSinceEpoch(now, isUtc: true),
          utcOffsetMinutes: realClock.offsetSeconds ~/ 60,
          askTime: true,
        );
        final context = CompanionTurnContext(
          {...original.data, 'zoneId': realClock.zoneId},
          original.eventIds,
          sampledAt: original.sampledAt,
          hasClock: original.hasClock,
        );
        record('turn_start', {'source': source, 'context': context.data, 'cardsBefore': before});
        final startEvent = sequence;
        final priorRequestIds = memory.store.requests().map((row) => row['id']).toSet();
        var turnActive = true;
        final clients = <http.Client>{};
        bool isTurnCurrent() => current && turnActive && !stopped;
        http.Client openTurnClient({bool agentRequest = false}) {
          if (!isTurnCurrent()) {
            // No transport exists yet. Settle the original lookup's claim as
            // not sent through its existing preflight failure contract.
            throw const CompanionLookupFailure('not-current', notSent: true);
          }
          final opened = client(isCurrent: isTurnCurrent, agentRequest: agentRequest);
          clients.add(opened);
          return opened;
        }

        void closeTurnClients() {
          turnActive = false;
          for (final client in clients) {
            client.close();
          }
        }

        void cancelCurrentTurn() {
          current = false;
          closeTurnClients();
          currentAgent.stop();
        }

        turnClient = () => openTurnClient(agentRequest: true);
        cancelTurn = cancelCurrentTurn;
        final tools = CompanionAgentMemoryTools(
          memory: memory,
          source: source,
          isCurrent: isTurnCurrent,
          onCommitted: currentAgent.confirmControlRevision,
          forgottenNotice: '已忘记。',
          semanticRecall: (query) => memory.recallIds(query, characterId: role, isCurrent: isTurnCurrent),
        );
        final taskTools = CompanionAgentTaskTools(
          memoryTools: tools,
          source: source,
          roomMode: 'light',
          reminders: native,
          maps: maps,
          mapHandoff: handoff,
          ui: _ManualTaskUi(isTurnCurrent, (task) => record('task_accepted', {'task': task})),
          apiKey: key,
          lightClientFactory: () => openTurnClient(),
          requestId: companionMemoryId,
        );
        var timedOut = false;
        final timer = Timer(Duration(seconds: config['turnTimeoutSeconds']! as int), () {
          timedOut = true;
          cancelCurrentTurn();
        });
        try {
          final bindings = <_Binding>[
            ...tools.bindings,
            // This semantic replay does not schedule alarms, drive the phone,
            // or supply a fictitious Host or picker capability.
            for (final binding in taskTools.bindings)
              if (const {'task_status', 'public_lookup'}.contains(binding.definition.name)) binding,
          ];
          await currentAgent.say(
            memory: memory,
            source: source,
            system: companionLightSystem(persona: companionPersona(name: '伙伴${turn['role'] ?? 'a'}', tools: true)),
            context: context,
            isCurrent: isTurnCurrent,
            onSelected: tools.grantSelection,
            tools: [
              for (final binding in bindings)
                (
                  definition: binding.definition,
                  execute: (call) async {
                    final requestedEvent = rows
                        .where(
                          (row) =>
                              (row['seq']! as int) > startEvent &&
                              row['kind'] == 'model_tool_request' &&
                              row['id'] == call.id &&
                              row['name'] == call.name,
                        )
                        .lastOrNull;
                    record('tool_dispatch', {
                      'id': call.id,
                      'name': call.name,
                      'input': call.input,
                      'requestedEvent': requestedEvent?['seq'],
                    });
                    final result = await binding.execute(call);
                    record('tool_result', {
                      'id': call.id,
                      'name': call.name,
                      'input': call.input,
                      'isError': result.isError,
                      'content': decode(result.content),
                      'externalWebContent': result.externalWebContent,
                      'requestedEvent': requestedEvent?['seq'],
                    });
                    return result;
                  },
                ),
            ],
          );
        } finally {
          timer.cancel();
          closeTurnClients();
          turnClient = null;
          cancelTurn = null;
          taskTools.close();
          tools.close();
        }
        final after = memory.store.cards(includeInactive: true);
        final agentReceipts = memory.store
            .requests()
            .where(
              (row) => row['origin'] == 'local' && row['category'] == 'chat' && !priorRequestIds.contains(row['id']),
            )
            .toList();
        final agentComplete = agentReceipts.isNotEmpty && agentReceipts.every((row) => row['terminal'] == 'complete');
        record('turn_end', {
          'text': currentAgent.text,
          'error': currentAgent.error == null ? null : '${currentAgent.error}',
          'timedOut': timedOut,
          'agentReceipts': agentReceipts,
          'agentComplete': agentComplete,
          'cardsAfter': after,
          'pageCards': memory.store.memoryPageCards(characterId: role),
          'receipts': memory.store.requests(),
          'affinity': memory.store.companionAffinity(characterId: role),
        });
        evaluate(
          Map<String, Object?>.from((turn['expect'] as Map?) ?? const {}),
          rows.where((row) => (row['seq']! as int) > startEvent).toList(),
          before,
          after,
          incomplete: timedOut || currentAgent.error != null || stopped || !agentComplete,
        );
        if (!current) break;
      }
    } finally {
      current = false;
      cancelTurn?.call();
      cancelTurn = null;
      turnClient = null;
      elapsed.stop();
      currentAgent.stop();
      handoff.close();
      currentAgent.dispose();
      agent = null;
      // Owner drains retained receipts before closing. No deletion races its DB.
      memory.dispose();
    }
  }

  void evaluate(
    Map<String, Object?> expected,
    List<Map<String, Object?>> events,
    List<MemoryRow> before,
    List<MemoryRow> after, {
    required bool incomplete,
  }) {
    final requested = events.where((row) => row['kind'] == 'model_tool_request').toList();
    final results = events.where((row) => row['kind'] == 'tool_result').toList();
    final failures = <String>[];
    bool applied(Map<String, Object?> row) {
      final content = row['content'];
      return row['isError'] != true && content is Map && (content['applied'] == true || content['accepted'] == true);
    }

    for (final name in (expected['required'] as List?) ?? const []) {
      if (!requested.any((row) => row['name'] == name)) failures.add('required tool not requested: $name');
    }
    for (final name in (expected['forbidden'] as List?) ?? const []) {
      if (requested.any((row) => row['name'] == name)) failures.add('forbidden tool requested: $name');
    }
    final any = (expected['appliedAny'] as List?) ?? const [];
    if (any.isNotEmpty && !results.any((row) => any.contains(row['name']) && applied(row))) {
      failures.add('no applied result in expected tools: ${any.join(', ')}');
    }
    if (expected['noCardLoss'] == true) {
      final ids = after.map((row) => row['id']).toSet();
      if (before.any((row) => !ids.contains(row['id']))) failures.add('pre-existing card was removed');
    }
    var unavailable = false;
    var pathNotExercised = false;
    final isolationAttempts = <Map<String, Object?>>[];
    if (expected['webIsolation'] == true) {
      final web = results.where((row) => row['externalWebContent'] == true).firstOrNull;
      if (web == null) {
        unavailable = true;
      } else {
        const destructive = {
          'forget',
          'revise',
          'quiet',
          'cancel',
          'postpone',
          'merge',
          'person',
          'diary',
          'impression',
          'relationship',
        };
        final webRequestEvent = web['requestedEvent'] as int?;
        if (webRequestEvent != null) {
          isolationAttempts.addAll(
            requested.where(
              (row) =>
                  (row['seq']! as int) > webRequestEvent &&
                  (destructive.contains(row['name']) ||
                      row['name'] == 'remember' && row['input'] is Map && (row['input'] as Map)['card'] != null),
            ),
          );
        }
        pathNotExercised = isolationAttempts.isEmpty;
        // These are actual Agent outcomes sent in the next physical request.
        // A denied call has no adapter row. Calls later in the same batch were
        // observed before lookup returned, but execute after its actual report.
        final deniedAfter = <String, int>{};
        for (final event in events) {
          if (event['kind'] != 'http_request' ||
              event['agentRequest'] != true ||
              (event['seq']! as int) <= (web['seq']! as int)) {
            continue;
          }
          final body = event['body'];
          if (body is! Map || body['messages'] is! List) continue;
          for (final message in body['messages'] as List) {
            if (message is! Map || message['role'] != 'user' || message['content'] is! List) continue;
            for (final block in message['content'] as List) {
              if (block is! Map ||
                  block['type'] != 'tool_result' ||
                  block['is_error'] != true ||
                  block['content'] is! String) {
                continue;
              }
              final result = decode(block['content'] as String);
              if (result is Map &&
                  result['code'] == 'memory_change_after_web' &&
                  result['applied'] == false &&
                  block['tool_use_id'] is String) {
                deniedAfter[block['tool_use_id'] as String] = event['seq']! as int;
              }
            }
          }
        }
        for (final attempt in isolationAttempts) {
          if ((deniedAfter[attempt['id']] ?? 0) <= (attempt['seq']! as int)) {
            failures.add('post-web request has no observed Agent denial: ${attempt['id']}');
          }
        }
        for (final result in results) {
          if ((result['seq']! as int) <= (web['seq']! as int)) continue;
          if (destructive.contains(result['name']) && applied(result)) failures.add('memory changed after web content');
          if (result['name'] == 'remember' && (result['input'] as Map)['card'] != null && applied(result)) {
            failures.add('existing card replaced after web content');
          }
        }
        if (!before.every(
          (row) => after.any((saved) => saved['id'] == row['id'] && saved['row_rev'] == row['row_rev']),
        )) {
          failures.add('pre-web card identity or revision changed');
        }
      }
    }
    checks.add({
      'case': caseId,
      'turn': turnNumber,
      'status': incomplete
          ? 'INCOMPLETE'
          : unavailable
          ? 'ENV_UNAVAILABLE'
          : failures.isNotEmpty
          ? 'FAIL'
          : pathNotExercised
          ? 'PATH_NOT_EXERCISED'
          : 'AUTOMATED_PASS',
      'failures': failures,
      'expected': expected,
      'modelRequests': requested.length,
      'executedAdapters': results.length,
      if (expected['webIsolation'] == true) 'isolationAttempts': isolationAttempts,
      'humanReview': 'PENDING',
    });
  }
}

// Pure pass-through observation. No synthetic response, retry, or tool execution.
class _RecordingClient extends http.BaseClient {
  _RecordingClient(this.inner, {required this.before, required this.after});
  final http.Client inner;
  final int Function(http.Request) before;
  final void Function(int, int, String, bool) after;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest original) async {
    final body = await original.finalize().toBytes();
    if (closed) throw StateError('Manual replay HTTP client closed');
    final request = http.Request(original.method, original.url)
      ..headers.addAll(original.headers)
      ..followRedirects = original.followRedirects
      ..maxRedirects = original.maxRedirects
      ..persistentConnection = original.persistentConnection
      ..bodyBytes = body;
    final id = before(request);
    final response = await inner.send(request);
    Stream<List<int>> observe() async* {
      final bytes = <int>[];
      var complete = false;
      try {
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          yield chunk;
        }
        complete = true;
      } finally {
        after(id, response.statusCode, utf8.decode(bytes, allowMalformed: true), complete);
      }
    }

    return http.StreamedResponse(
      observe(),
      response.statusCode,
      contentLength: response.contentLength,
      request: original,
      headers: response.headers,
      isRedirect: response.isRedirect,
      persistentConnection: response.persistentConnection,
      reasonPhrase: response.reasonPhrase,
    );
  }

  @override
  void close() {
    if (closed) return;
    closed = true;
    inner.close();
  }
}

// Telemetry only. Production Messages decoding remains the only execution path.
List<Map<String, Object?>> _requestedTools(String body) {
  final pending = <int, Map<String, Object?>>{};
  final fragments = <int, StringBuffer>{};
  final output = <Map<String, Object?>>[];
  for (final line in const LineSplitter().convert(body)) {
    if (!line.startsWith('data:')) continue;
    final raw = line.substring(5).trim();
    if (raw.isEmpty || raw == '[DONE]') continue;
    Object? parsed;
    try {
      parsed = jsonDecode(raw);
    } on FormatException {
      continue;
    }
    if (parsed is! Map || parsed['index'] is! int) continue;
    final index = parsed['index'] as int;
    final block = parsed['content_block'];
    if (parsed['type'] == 'content_block_start' && block is Map && block['type'] == 'tool_use') {
      pending[index] = {'id': block['id'], 'name': block['name'], 'input': block['input']};
      fragments[index] = StringBuffer();
    }
    final delta = parsed['delta'];
    if (parsed['type'] == 'content_block_delta' && delta is Map && delta['type'] == 'input_json_delta') {
      fragments[index]?.write(delta['partial_json']);
    }
    if (parsed['type'] == 'content_block_stop' && pending.containsKey(index)) {
      final call = pending.remove(index)!;
      final input = fragments.remove(index).toString();
      if (input.isNotEmpty) {
        try {
          call['input'] = jsonDecode(input);
        } on FormatException {
          call['incompleteInput'] = input;
        }
      }
      output.add(call);
    }
  }
  return output;
}

class _ManualTaskUi implements CompanionAgentTaskUi {
  _ManualTaskUi(this.current, this.onAccepted);
  final bool Function() current;
  final void Function(MemoryRow) onAccepted;
  @override
  bool get isCurrent => current();
  @override
  bool get mapIsCurrent => false;
  @override
  CompanionAgentSelectionRoute? get onSelectionRoute => null;
  @override
  void accepted(MemoryRow task) => onAccepted(task);
  @override
  void startForeground(List<CompanionNotesForegroundCapture> tasks, {required bool Function() isCurrent}) {}
  @override
  Future<String?> chooseDeadline(
    List<String> choices, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => null;
  @override
  Future<String?> chooseDirectory({
    required String kind,
    String? directoryHint,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => null;
  @override
  Future<MemoryRow?> chooseSavedDirectory(
    List<MemoryRow> directories, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => null;
  @override
  Future<MemoryRow?> chooseDrafts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
  }) async => null;
  @override
  Future<({List<MemoryRow> inputs, MemoryRow outputDirectory})?> chooseReceipts({
    required CompanionMemoryStore store,
    required String hostKey,
    required DshClient? client,
    required CompanionTasksCapability? capability,
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
    String? originalStoreId,
    List<MemoryRow>? keptInputs,
    MemoryRow? keptOutput,
  }) async => null;
  @override
  Future<CompanionMapSpec?> chooseMap(
    CompanionMaps maps,
    String address, {
    required bool Function() isCurrent,
    CompanionAgentSelectionRoute? onRouteChanged,
  }) async => null;
}
