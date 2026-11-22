import 'dart:async';
import 'dart:convert';

import 'package:dsh_client/dsh_client.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'companion_agent_task_ui.dart';
import 'companion_agent_tools.dart';
import 'companion_context.dart';
import 'companion_host_tasks.dart';
import 'companion_light.dart';
import 'companion_maps.dart';
import 'companion_public_lookup.dart';
import 'companion_reminder.dart';

/// Structured model calls use the original SQLite source and task executors.
/// No call is turned into a synthetic sentence for one of the old parsers.
class CompanionAgentTaskTools {
  CompanionAgentTaskTools({
    required this.memoryTools,
    required MemoryRow source,
    required this.roomMode,
    required this.reminders,
    required this.maps,
    required this.mapHandoff,
    required this.ui,
    required this.apiKey,
    required this.lightClientFactory,
    required this.requestId,
    this.host,
  }) : source = Map<String, Object?>.unmodifiable(source),
       _mapGeneration = mapHandoff.generation,
       _selectionRoute = ui.onSelectionRoute {
    if (source['id'] != memoryTools.sourceId || !const ['light', 'full'].contains(roomMode)) {
      throw ArgumentError('The task tools require the same original Agent source');
    }
  }

  final CompanionAgentMemoryTools memoryTools;
  final MemoryRow source;
  final String roomMode, apiKey;
  final CompanionReminders reminders;
  final CompanionMaps maps;
  final CompanionMapHandoff mapHandoff;
  final CompanionAgentTaskUi ui;
  final http.Client Function() lightClientFactory;
  final String Function() requestId;
  final CompanionAgentTaskHost? host;
  final int _mapGeneration;
  final CompanionAgentSelectionRoute? _selectionRoute;
  final _inFlight = <String, Future<CompanionAgentToolResult>>{};
  final _shownTasks = <String, int>{};
  final _foregrounds = <CompanionNotesForegroundCapture>[];
  bool _closed = false;
  bool _usingMap = false;

  CompanionMemoryStore get _store => memoryTools.memory.store;
  String get _sourceId => source['id']! as String;
  int get _sourceRevision => source['source_rev']! as int;
  String get _sessionId => source['session_id']! as String;
  bool get _current => !_closed && memoryTools.isCurrent;
  bool get _here => _current && ui.isCurrent;
  bool get _mapHere => _here && ui.mapIsCurrent && mapHandoff.generation == _mapGeneration;
  bool get _hasHost => host != null && host!.isCurrent() && (roomMode == 'full' || host!.client == null);
  bool get _connectedHost => _hasHost && host!.client != null;
  List<CompanionAgentTool> get _availableHostDefinitions => [
    if (_hasHost)
      for (final definition in hostDefinitions)
        if (host!.client != null ||
            const ['find_draft', 'compare_drafts', 'receipts_to_sheet'].contains(definition.name))
          definition,
  ];

  List<({CompanionAgentTool definition, Future<CompanionAgentToolResult> Function(CompanionAgentToolCall) execute})>
  get bindings => [
    for (final definition in [...phoneDefinitions, ..._availableHostDefinitions])
      (definition: definition, execute: execute),
  ];

  /// Call before closing the shared memory tools, after all model tools have
  /// settled. Only this fresh turn can hand these exact revisions to a detail.
  /// The Page checks its original opportunity again before the actual push.
  void close() {
    if (_closed) return;
    final canPresent = _here && _connectedHost;
    final captures = <CompanionNotesForegroundCapture>[];
    if (canPresent) {
      for (final capture in _foregrounds) {
        final original = capture.task;
        final current = _store.hostTask(original['task_id']! as String);
        final deadline = (original['agreement']! as MemoryRow)['deadlineAtMs'] as int?;
        if (current != null &&
            current['task_rev'] == original['task_rev'] &&
            current['cancel_requested'] == 0 &&
            current['host_key'] == host!.key &&
            current['host_store_id'] == capture.capability.hostStoreId &&
            current['host_execution_id'] == original['host_execution_id'] &&
            identical(capture.client, host!.client) &&
            !const ['done', 'partial', 'failed', 'cancelled'].contains(current['state']) &&
            (deadline == null || DateTime.now().millisecondsSinceEpoch < deadline)) {
          captures.add(capture);
        }
      }
    }
    _foregrounds.clear();
    // Retirement cannot cancel another visit's newer map scope.
    if (_usingMap && mapHandoff.generation == _mapGeneration) mapHandoff.close();
    _closed = true;
    if (captures.isNotEmpty) {
      // This callback deliberately does not use _current: closing the tool
      // registry consumes its opportunity, while the captured visit still owns
      // the new detail route and its existing foreground checks.
      ui.startForeground(captures, isCurrent: () => ui.isCurrent && host!.isCurrent());
    }
  }

  Future<CompanionAgentToolResult> execute(CompanionAgentToolCall call) {
    if (!_current) return Future.value(_failure('turn_not_current'));
    final definitions = [...phoneDefinitions, ..._availableHostDefinitions];
    final matching = definitions.where((entry) => entry.name == call.name).toList();
    if (matching.length != 1 || !_shape(call.input, matching.single.inputSchema)) {
      return Future.value(_failure('invalid_or_unavailable_tool'));
    }
    if (call.name == 'task_status') {
      final completed = Completer<CompanionAgentToolResult>();
      memoryTools.memory.retainReceipt(completed.future.then<void>((_) {}));
      unawaited(_status(call.input).then(completed.complete, onError: completed.completeError));
      return completed.future;
    }
    final CompanionAgentMemoryResult receipt;
    try {
      // The journal checks name + argument digest even if this same ID is
      // already in flight. Ordinals never restart at a model-round boundary.
      receipt = _store.reserveAgentTaskCall(
        turnId: memoryTools.turnId,
        callId: call.id,
        toolName: call.name,
        input: call.input,
      );
    } on DshRemoteException catch (error) {
      return Future.value(_failure(error.code));
    } on ArgumentError {
      return Future.value(_failure('invalid_arguments'));
    }
    final active = _inFlight[call.id];
    if (active != null) return active;
    if (receipt.replayed) {
      final accepted = _store.taskForCommand(_sourceId, receipt.itemNo);
      if (accepted != null) {
        _store.finishAgentTaskCall(turnId: memoryTools.turnId, callId: call.id, taskId: accepted['task_id']! as String);
        return Future.value(_result(_readTask(accepted), replayed: true));
      }
      // A pending identity after a crash is not permission to run a newly
      // generated call. There is no stored assistant/tool-result transcript.
      return Future.value(_failure(receipt.code ?? 'original_call_unresolved'));
    }
    if (receipt.state != 'pending') return Future.value(_failure(receipt.code ?? 'not_accepted'));
    final completed = Completer<CompanionAgentToolResult>();
    _inFlight[call.id] = completed.future;
    memoryTools.memory.retainReceipt(completed.future.then<void>((_) {}));
    unawaited(
      () async {
        try {
          _requireCurrent();
          final task = switch (call.name) {
            'reminder' => await _reminder(call, receipt.itemNo),
            'public_lookup' => await _lookup(call, receipt.itemNo),
            'map_open' => await _map(call, receipt.itemNo),
            _ => await _hostTask(call, receipt.itemNo),
          };
          completed.complete(_result(task));
        } on Object catch (error) {
          final accepted = _store.taskForCommand(_sourceId, receipt.itemNo);
          if (accepted == null) {
            final code = _errorCode(error);
            _store.finishAgentTaskCall(turnId: memoryTools.turnId, callId: call.id, ignoredCode: code);
            completed.complete(_failure(code));
          } else {
            // An executor/channel/HTTP error does not undo the durable command or
            // invent a successful stop. Return its current original receipt.
            _store.finishAgentTaskCall(
              turnId: memoryTools.turnId,
              callId: call.id,
              taskId: accepted['task_id']! as String,
            );
            completed.complete(_result(_readTask(accepted), error: _errorCode(error)));
          }
        } finally {
          _inFlight.remove(call.id);
        }
      }().catchError((Object error, StackTrace stack) {
        // A store failure while settling must still retire this real Future;
        // leaving its completer pending would prevent the owner from draining.
        if (!completed.isCompleted) completed.completeError(error, stack);
      }),
    );
    return completed.future;
  }

  Future<CompanionAgentToolResult> _status(MemoryRow input) async {
    try {
      final id = _optionalText(input, 'taskId');
      if (id == null) {
        final tasks = _store.tasks(sourceSessionId: _sessionId);
        for (final task in tasks) {
          _show(task);
        }
        final summaries = [for (final task in tasks) _summary(_readTask(task))];
        return CompanionAgentToolResult(
          externalWebContent: summaries.any(_hasExternalWebContent),
          content: jsonEncode({
            'readOnly': true,
            'sourceSessionId': _sessionId,
            'limited': tasks.length == 100,
            'tasks': summaries,
            'message': 'This is a bounded list of original receipts, not proof that no older matching task exists.',
          }),
        );
      }
      var task = _store.task(id);
      if (task == null || task['source_session_id'] != _sessionId) return _failure('task_not_in_this_room');
      task = _readTask(task);
      final client = host?.client;
      if (input['refresh'] == true && _connectedHost && client != null && task['host_key'] == host!.key) {
        if ((task['kind']! as String).startsWith('host.')) {
          task = await memoryTools.memory.hostTasks.run(task, client: client, hostKey: host!.key);
        } else if (task['kind'] == 'public.lookup') {
          await memoryTools.memory.lookups.readReceipts(task, host: client, hostKey: host!.key);
          task = _store.lookupTask(id)!;
        }
      }
      _requireCurrent();
      _show(task);
      final summary = _summary(task);
      return CompanionAgentToolResult(
        content: jsonEncode({'readOnly': true, 'task': summary}),
        externalWebContent: _hasExternalWebContent(summary),
      );
    } on Object catch (error) {
      return _failure(_errorCode(error));
    }
  }

  Future<MemoryRow> _reminder(CompanionAgentToolCall call, int itemNo) async {
    final input = call.input;
    final operation = _operation(input);
    final previous = operation == 'create' ? null : _target(input, 'phone.reminder');
    final executor = await reminders.executorId();
    _requireCurrent();
    if (previous != null && previous['executor_id'] != executor) throw const _TaskFailure('original_phone_required');
    final MemoryRow task;
    if (operation == 'cancel') {
      task = _store.cancelReminder(
        taskId: previous!['task_id']! as String,
        expectedTaskRev: previous['task_rev']! as int,
        messageId: _sourceId,
        expectedSourceRev: _sourceRevision,
        itemNo: itemNo,
      );
    } else {
      final spec = await _reminderSpec(input, previous);
      _requireCurrent();
      task = previous == null
          ? _store.createReminderFromMessage(
              messageId: _sourceId,
              expectedSourceRev: _sourceRevision,
              itemNo: itemNo,
              roomMode: 'light',
              executorId: executor,
              reminder: spec,
            )
          : _store.amendReminder(
              taskId: previous['task_id']! as String,
              expectedTaskRev: previous['task_rev']! as int,
              messageId: _sourceId,
              expectedSourceRev: _sourceRevision,
              itemNo: itemNo,
              reminder: spec,
            );
    }
    _accepted(call, task);
    if (task['state'] != 'done' &&
        task['state'] != 'cancelled' &&
        (task['epoch_ms'] != null || task['operation'] == 'amend' || task['cancel_requested'] == 1)) {
      await reminders.wake(task['task_id']! as String);
    }
    return _store.task(task['task_id']! as String)!;
  }

  Future<CompanionReminderSpec> _reminderSpec(MemoryRow input, MemoryRow? previous) async {
    final text = _optionalText(input, 'text') ?? previous?['reminder_text'] as String?;
    final date = _optionalText(input, 'localDate') ?? previous?['local_date'] as String?;
    final time = _optionalText(input, 'localTime') ?? previous?['local_time'] as String?;
    final zone = _optionalText(input, 'zoneId') ?? previous?['zone_id'] as String? ?? source['zone_id'] as String?;
    final missing = text == null
        ? 'text_missing'
        : date == null
        ? 'date_missing'
        : time == null
        ? 'time_missing'
        : zone == null
        ? 'zone_missing'
        : null;
    if (missing != null) {
      return CompanionReminderSpec(text: text, localDate: date, localTime: time, zoneId: zone, waitReason: missing);
    }
    _date(date!);
    _time(time!);
    final offset = input['selectedOffsetSeconds'];
    if (offset != null && offset is! int) throw const _TaskFailure('invalid_offset');
    if (previous != null &&
        date == previous['local_date'] &&
        time == previous['local_time'] &&
        zone == previous['zone_id'] &&
        (offset == null || offset == previous['offset_seconds']) &&
        previous['epoch_ms'] is int &&
        previous['offset_seconds'] is int) {
      // A wording edit keeps the already chosen occurrence of a repeated time.
      return CompanionReminderSpec(
        text: text,
        localDate: date,
        localTime: time,
        zoneId: zone,
        epochMs: previous['epoch_ms']! as int,
        offsetSeconds: previous['offset_seconds']! as int,
      );
    }
    final resolved = await reminders.resolve(date, time, zone!, selectedOffsetSeconds: offset as int?);
    if (resolved['kind'] != 'unique') {
      return CompanionReminderSpec(
        text: text,
        localDate: date,
        localTime: time,
        zoneId: zone,
        waitReason: resolved['kind'] == 'gap' ? 'time_gap' : 'time_overlap',
      );
    }
    final moment = (resolved['moments']! as List).single as Map;
    return CompanionReminderSpec(
      text: text,
      localDate: date,
      localTime: time,
      zoneId: zone,
      epochMs: moment['epochMs']! as int,
      offsetSeconds: moment['offsetSeconds']! as int,
    );
  }

  Future<MemoryRow> _lookup(CompanionAgentToolCall call, int itemNo) async {
    final input = call.input;
    final operation = _operation(input, allowed: const ['create', 'cancel']);
    final previous = operation == 'cancel' ? _target(input, 'public.lookup') : null;
    final executor = await reminders.executorId();
    _requireCurrent();
    if (previous != null && previous['executor_id'] != executor) throw const _TaskFailure('original_phone_required');
    MemoryRow task;
    if (previous != null) {
      task = _store.cancelLookup(
        taskId: previous['task_id']! as String,
        expectedTaskRev: previous['task_rev']! as int,
        messageId: _sourceId,
        expectedSourceRev: _sourceRevision,
        itemNo: itemNo,
      );
    } else {
      final city = _optionalText(input, 'city');
      final zone = _optionalText(input, 'zoneId') ?? (city == null ? source['zone_id'] as String? : null);
      if (zone == null) throw const _TaskFailure('zone_missing');
      final date = _text(input, 'localDate');
      _date(date);
      task = _store.createLookupFromMessage(
        messageId: _sourceId,
        expectedSourceRev: _sourceRevision,
        itemNo: itemNo,
        // This legacy field selects the real executor route. Both Agent modes
        // now make new public lookups on the phone; no Host identity is invented.
        roomMode: 'light',
        executorId: executor,
        lookup: CompanionLookupSpec(
          placeName: _text(input, 'placeName'),
          city: city,
          localDate: date,
          zoneId: zone,
          question: _text(input, 'question'),
          deadlineAtMs: (source['said_at_utc']! as int) + 120000,
        ),
      );
    }
    _accepted(call, task);
    if (task['cancel_requested'] == 1) {
      // Old full/Host tasks keep their original fences and pending receipts.
      await memoryTools.memory.lookups.stop(
        task,
        executorId: executor,
        host: _hasHost ? host!.client : null,
        hostKey: _hasHost ? host!.key : null,
      );
      task = _store.lookupTask(task['task_id']! as String)!;
    } else {
      task = await memoryTools.memory.lookups.run(
        task,
        executorId: executor,
        requestId: requestId,
        estimateTokens: estimateCompanionMemoryTokens,
        direct: CompanionLookupDirect(
          client: lightClientFactory,
          apiKey: () => apiKey,
          nowMilliseconds: memoryTools.memory.lookups.nowMilliseconds,
          estimateTokens: estimateCompanionMemoryTokens,
        ),
      );
    }
    memoryTools.memory.changed();
    return task;
  }

  Future<MemoryRow> _map(CompanionAgentToolCall call, int itemNo) async {
    final input = call.input;
    final operation = _operation(input, allowed: const ['create', 'amend', 'cancel', 'reopen']);
    final previous = operation == 'create' ? null : _target(input, 'phone.map_open');
    final executor = await maps.executorId();
    _requireMap();
    if (previous != null && operation != 'reopen' && previous['executor_id'] != executor) {
      throw const _TaskFailure('original_phone_required');
    }
    final MemoryRow task;
    if (operation == 'cancel') {
      task = _store.cancelMapOpen(
        taskId: previous!['task_id']! as String,
        expectedTaskRev: previous['task_rev']! as int,
        messageId: _sourceId,
        expectedSourceRev: _sourceRevision,
        itemNo: itemNo,
      );
    } else if (operation == 'reopen') {
      task = _store.reopenMapOpenFromMessage(
        oldTaskId: previous!['task_id']! as String,
        expectedTaskRev: previous['task_rev']! as int,
        messageId: _sourceId,
        expectedSourceRev: _sourceRevision,
        itemNo: itemNo,
        executorId: executor,
      );
    } else {
      final selected = await ui.chooseMap(
        maps,
        _text(input, 'address'),
        isCurrent: () => _mapHere,
        onRouteChanged: _selectionRoute,
      );
      _requireMap();
      if (selected == null) throw const _TaskFailure('selection_cancelled');
      task = previous == null
          ? _store.createMapOpenFromMessage(
              messageId: _sourceId,
              expectedSourceRev: _sourceRevision,
              itemNo: itemNo,
              roomMode: 'light',
              executorId: executor,
              map: selected,
            )
          : _store.amendMapOpen(
              taskId: previous['task_id']! as String,
              expectedTaskRev: previous['task_rev']! as int,
              messageId: _sourceId,
              expectedSourceRev: _sourceRevision,
              itemNo: itemNo,
              map: selected,
            );
    }
    // The command is durable before native work, but its room button belongs
    // only to the original opportunity after the handoff has finished.
    _accepted(call, task, present: operation == 'cancel');
    if (operation != 'cancel') {
      final id = task['task_id']! as String;
      final revision = task['task_rev'];
      _usingMap = true;
      try {
        await mapHandoff.execute(
          _store,
          task,
          isCurrent: () => _mapHere && _store.mapTask(id)?['task_rev'] == revision,
        );
      } finally {
        _usingMap = false;
        memoryTools.memory.changed();
      }
      final current = _store.mapTask(id)!;
      if (_mapHere && current['task_rev'] == revision) ui.accepted(current);
    }
    return _store.mapTask(task['task_id']! as String)!;
  }

  Future<MemoryRow> _hostTask(CompanionAgentToolCall call, int itemNo) async {
    final input = call.input;
    final operation = _operation(input);
    final kind = 'host.${call.name}';
    final previous = operation == 'create' ? null : _target(input, kind);
    _requireHost();
    final client = host!.client;
    if (previous != null && previous['host_key'] != host!.key) throw const _TaskFailure('original_host_required');
    CompanionTasksCapability? capability;
    MemoryRow task;
    if (operation == 'cancel') {
      task = _cancelHost(kind, previous!, itemNo);
    } else {
      if (client != null) {
        capability = await client.readCompanionTasksCapability();
        _requireHost();
        if (capability == null || !_supports(capability, kind)) throw const _TaskFailure('host_capability_unavailable');
      }
      final originalStore = previous?['host_store_id'] as String?;
      if (originalStore != null && capability != null && originalStore != capability.hostStoreId) {
        throw const _TaskFailure('original_host_store_required');
      }
      final oldAgreement = previous?['agreement'] as MemoryRow?;
      final oldArgs = oldAgreement?['args'] as MemoryRow?;
      final terms = await _terms(input, oldAgreement);
      _requireHost();
      MemoryRow labels;
      MemoryRow args;
      String? directoryStore;
      if (kind == 'host.notes_to_todo' || kind == 'host.find_draft') {
        final date = _optionalText(input, 'localDate') ?? oldArgs?['localDate'] as String?;
        final keepDateWindow = kind == 'host.find_draft' && previous != null && date == oldArgs?['localDate'];
        final zone = (keepDateWindow ? (oldArgs?['timeZone']) : source['zone_id']) as String?;
        if (date == null || zone == null || (!keepDateWindow && source['offset_seconds'] is! int)) {
          throw const _TaskFailure('original_date_zone_missing');
        }
        _date(date);
        final choose = previous == null || input['chooseDirectory'] == true;
        String folder;
        if (choose) {
          final MemoryRow bound;
          if (client == null) {
            final saved = _store
                .hostTaskDirectories(hostKey: host!.key)
                .where((row) => originalStore == null || row['hostStoreId'] == originalStore)
                .toList();
            if (saved.isEmpty) throw const _TaskFailure('saved_original_directory_required');
            final selected = await ui.chooseSavedDirectory(
              saved,
              isCurrent: () => _here && _hasHost,
              onRouteChanged: _selectionRoute,
            );
            _requireHost();
            if (selected == null) throw const _TaskFailure('selection_cancelled');
            bound = selected;
          } else {
            final path = await ui.chooseDirectory(
              kind: kind,
              directoryHint: _optionalText(input, 'directoryHint'),
              isCurrent: () => _here && _hasHost,
              onRouteChanged: _selectionRoute,
            );
            _requireHost();
            if (path == null) throw const _TaskFailure('selection_cancelled');
            bound = await client.bindCompanionNotesDirectory(capability!, path);
            _requireHost();
          }
          folder = bound['folderRef']! as String;
          directoryStore = bound['hostStoreId']! as String;
          if (capability != null && directoryStore != capability.hostStoreId) {
            throw const _TaskFailure('original_host_store_required');
          }
          labels = {'source': bound['displayPath'], if (kind == 'host.notes_to_todo') 'output': bound['displayPath']};
        } else {
          folder = oldArgs!['folderRef']! as String;
          directoryStore = originalStore;
          labels = Map<String, Object?>.from(previous['directory_labels']! as Map);
        }
        args = {'folderRef': folder, 'localDate': date, 'timeZone': zone, 'dateBy': 'modified'};
        if (kind == 'host.find_draft') {
          final extensions = input['extensions'] ?? oldArgs?['extensions'];
          if (extensions is! List ||
              extensions.isEmpty ||
              extensions.any((entry) => !const ['md', 'txt'].contains(entry))) {
            throw const _TaskFailure('invalid_extensions');
          }
          args.addAll({'scope': 'currentLevel', 'extensions': List<Object?>.of(extensions)});
        } else {
          args.addAll({
            'outputDirRef': folder,
            'outputName': _optionalText(input, 'outputName') ?? oldArgs?['outputName'] ?? '$date-待办.md',
            'writeMode': 'createNew',
          });
        }
      } else if (kind == 'host.compare_drafts') {
        final oldLabels = previous?['directory_labels'] as Map?;
        final inputs = previous == null || input['chooseInputs'] == true
            ? await ui.chooseDrafts(
                store: _store,
                hostKey: host!.key,
                client: client,
                capability: capability,
                isCurrent: () => _here && _hasHost,
                onRouteChanged: _selectionRoute,
                originalStoreId: originalStore,
              )
            : Map<String, Object?>.from(oldLabels!['inputs']! as Map);
        _requireHost();
        if (inputs == null) throw const _TaskFailure('selection_cancelled');
        labels = {'inputs': inputs};
        args = {
          for (final side in ['a', 'b'])
            side: {
              'sourceRef': (inputs[side]! as MemoryRow)['sourceRef'],
              'version': (inputs[side]! as MemoryRow)['version'],
            },
          'maxHighlights': 3,
        };
      } else {
        final oldLabels = previous?['directory_labels'] as Map?;
        final selected = previous == null || input['chooseInputs'] == true
            ? await ui.chooseReceipts(
                store: _store,
                hostKey: host!.key,
                client: client,
                capability: capability,
                isCurrent: () => _here && _hasHost,
                onRouteChanged: _selectionRoute,
                originalStoreId: originalStore,
              )
            : (
                inputs: [for (final row in oldLabels!['inputs']! as List) Map<String, Object?>.from(row as Map)],
                outputDirectory: Map<String, Object?>.from(oldLabels['outputDirectory']! as Map),
              );
        _requireHost();
        if (selected == null) throw const _TaskFailure('selection_cancelled');
        labels = {'inputs': selected.inputs, 'outputDirectory': selected.outputDirectory};
        args = {
          'inputs': [
            for (final row in selected.inputs) {'sourceRef': row['sourceRef'], 'version': row['version']},
          ],
          'outputDirRef': selected.outputDirectory['folderRef'],
          'outputName': _optionalText(input, 'outputName') ?? oldArgs?['outputName'],
          'writeMode': 'createNew',
        };
      }
      final agreement = <String, Object?>{'args': args, ...terms};
      String? session = previous?['host_session_id'] as String?;
      if (previous == null && client != null) session = await host!.ensureSession();
      _requireHost();
      task = previous == null
          ? _createHost(kind, itemNo, agreement, labels, directoryStore, session)
          : _amendHost(kind, previous, itemNo, agreement, labels);
    }
    _accepted(call, task);
    // Saved refs already bind the original Host store. Only resumeNotes (or an
    // explicit original-task action) may dispatch after a real reconnection.
    if (client == null) return task;
    task = await memoryTools.memory.hostTasks.run(
      task,
      client: client,
      hostKey: host!.key,
      initialOpportunity: true,
      submitPending: true,
      capability: capability,
    );
    if (operation == 'create' &&
        kind == 'host.notes_to_todo' &&
        (task['agreement']! as MemoryRow)['afterExit'] == 'pause' &&
        capability != null &&
        capability.notesForeground &&
        _here &&
        _hasHost &&
        task['task_rev'] == 1 &&
        task['cancel_requested'] == 0 &&
        task['host_execution_id'] is String &&
        task['host_store_id'] == capability.hostStoreId) {
      _foregrounds.add((task: Map<String, Object?>.unmodifiable(task), client: client, capability: capability));
    }
    return task;
  }

  Future<MemoryRow> _terms(MemoryRow input, MemoryRow? previous) async {
    final afterExit = input['afterExit'] ?? previous?['afterExit'];
    final allowQueue = input['allowQueue'] ?? previous?['allowQueue'];
    if (!const ['continue', 'pause'].contains(afterExit) || allowQueue is! bool) {
      throw const _TaskFailure('agreement_missing');
    }
    var time = _optionalText(input, 'deadlineTime');
    if (input['deadlineChoices'] case final List choices) {
      if (time != null || choices.isEmpty || choices.any((value) => value is! String)) {
        throw const _TaskFailure('invalid_deadline');
      }
      final values = choices.cast<String>();
      for (final value in values) {
        _time(value);
      }
      time = await ui.chooseDeadline(values, isCurrent: () => _here && _hasHost, onRouteChanged: _selectionRoute);
      _requireHost();
      if (time == null) throw const _TaskFailure('selection_cancelled');
      if (!values.contains(time)) throw const _TaskFailure('invalid_deadline_choice');
    }
    int? deadline = previous?['deadlineAtMs'] as int?;
    if (input.containsKey('deadlineTime') && input['deadlineTime'] == null) deadline = null;
    if (time != null) {
      final zone = source['zone_id'];
      final offset = source['offset_seconds'];
      if (zone is! String || offset is! int) throw const _TaskFailure('original_date_zone_missing');
      final original = DateTime.fromMillisecondsSinceEpoch(
        (source['said_at_utc']! as int) + offset * 1000,
        isUtc: true,
      );
      final date = _optionalText(input, 'deadlineDate') ?? original.toIso8601String().substring(0, 10);
      _date(date);
      _time(time);
      final resolved = await reminders.resolve(date, time, zone);
      _requireHost();
      if (resolved['kind'] != 'unique') throw const _TaskFailure('deadline_not_unique');
      deadline = ((resolved['moments']! as List).single as Map)['epochMs']! as int;
    }
    return {'deadlineAtMs': deadline, 'afterExit': afterExit, 'allowQueue': allowQueue};
  }

  MemoryRow _createHost(
    String kind,
    int itemNo,
    MemoryRow agreement,
    MemoryRow labels,
    String? storeId,
    String? session,
  ) {
    switch (kind) {
      case 'host.notes_to_todo':
        return _store.createNotesTaskFromMessage(
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          roomMode: roomMode,
          hostKey: host!.key,
          hostSessionId: session,
          agreement: agreement,
          directoryLabels: labels,
        );
      case 'host.find_draft':
        return _store.createFindDraftTaskFromMessage(
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          roomMode: roomMode,
          hostKey: host!.key,
          hostSessionId: session,
          directoryHostStoreId: storeId!,
          agreement: agreement,
          directoryLabels: labels,
        );
      case 'host.compare_drafts':
        return _store.createCompareDraftTaskFromMessage(
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          roomMode: roomMode,
          hostKey: host!.key,
          hostSessionId: session,
          agreement: agreement,
          inputs: labels['inputs']! as MemoryRow,
        );
      case 'host.receipts_to_sheet':
        return _store.createReceiptsTaskFromMessage(
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          roomMode: roomMode,
          hostKey: host!.key,
          hostSessionId: session,
          agreement: agreement,
          inputs: labels['inputs']! as List<MemoryRow>,
          outputDirectory: labels['outputDirectory']! as MemoryRow,
        );
      default:
        throw const _TaskFailure('invalid_tool');
    }
  }

  MemoryRow _amendHost(String kind, MemoryRow previous, int itemNo, MemoryRow agreement, MemoryRow labels) {
    final id = previous['task_id']! as String;
    final revision = previous['task_rev']! as int;
    switch (kind) {
      case 'host.notes_to_todo':
        return _store.amendNotesTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          agreement: agreement,
          directoryLabels: labels,
        );
      case 'host.find_draft':
        return _store.amendFindDraftTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          agreement: agreement,
          directoryLabels: labels,
        );
      case 'host.compare_drafts':
        return _store.amendCompareDraftTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          agreement: agreement,
          inputs: labels['inputs']! as MemoryRow,
        );
      case 'host.receipts_to_sheet':
        return _store.amendReceiptsTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
          agreement: agreement,
          inputs: labels['inputs']! as List<MemoryRow>,
          outputDirectory: labels['outputDirectory']! as MemoryRow,
        );
      default:
        throw const _TaskFailure('invalid_tool');
    }
  }

  MemoryRow _cancelHost(String kind, MemoryRow previous, int itemNo) {
    final id = previous['task_id']! as String;
    final revision = previous['task_rev']! as int;
    switch (kind) {
      case 'host.notes_to_todo':
        return _store.cancelNotesTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
        );
      case 'host.find_draft':
        return _store.cancelFindDraftTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
        );
      case 'host.compare_drafts':
        return _store.cancelCompareDraftTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
        );
      case 'host.receipts_to_sheet':
        return _store.cancelReceiptsTask(
          taskId: id,
          expectedTaskRev: revision,
          messageId: _sourceId,
          expectedSourceRev: _sourceRevision,
          itemNo: itemNo,
        );
      default:
        throw const _TaskFailure('invalid_tool');
    }
  }

  void _accepted(CompanionAgentToolCall call, MemoryRow task, {bool present = true}) {
    _store.finishAgentTaskCall(turnId: memoryTools.turnId, callId: call.id, taskId: task['task_id']! as String);
    _show(task);
    memoryTools.memory.changed();
    if (present && ui.isCurrent) ui.accepted(task);
  }

  void _show(MemoryRow task) => _shownTasks[task['task_id']! as String] = task['task_rev']! as int;

  MemoryRow _target(MemoryRow input, String kind) {
    final id = _text(input, 'taskId');
    final expected = input['expectedTaskRev'];
    final task = _store.task(id);
    if (expected is! int ||
        _shownTasks[id] != expected ||
        task == null ||
        task['task_rev'] != expected ||
        task['kind'] != kind ||
        task['source_session_id'] != _sessionId) {
      throw const _TaskFailure('read_the_original_task_first');
    }
    return _readTask(task);
  }

  MemoryRow _readTask(MemoryRow task) => switch (task['kind']) {
    'public.lookup' => _store.lookupTask(task['task_id']! as String)!,
    'phone.map_open' => _store.mapTask(task['task_id']! as String)!,
    'host.notes_to_todo' ||
    'host.find_draft' ||
    'host.compare_drafts' ||
    'host.receipts_to_sheet' => _store.hostTask(task['task_id']! as String)!,
    _ => task,
  };

  CompanionAgentToolResult _result(MemoryRow task, {bool replayed = false, String? error}) {
    _show(task);
    final summary = _summary(task);
    return CompanionAgentToolResult(
      externalWebContent: _hasExternalWebContent(summary),
      content: jsonEncode({
        'accepted': true,
        'replayed': replayed,
        'task': summary,
        'receiptError': ?error,
        'message': 'The original command is saved. Only the reported state and receipts establish its effects; cancellation is not proof that an earlier effect stopped.',
      }),
    );
  }

  static bool _hasExternalWebContent(MemoryRow summary) =>
      summary['kind'] == 'public.lookup' && (summary['result'] != null || summary['report'] != null);

  static MemoryRow _summary(MemoryRow task) => {
    for (final key in const [
      'task_id',
      'task_rev',
      'kind',
      'source_session_id',
      'state',
      'wait_reason',
      'cancel_requested',
      'operation',
      'executor_id',
      'reminder_text',
      'local_date',
      'local_time',
      'zone_id',
      'epoch_ms',
      'address',
      'target_label',
      'lookup_place_name',
      'lookup_city',
      'lookup_question',
      'result',
      'agreement',
    ])
      if (task.containsKey(key)) key: task[key],
    if (task['snapshot'] case final Map snapshot) 'report': snapshot['report'],
  };

  void _requireCurrent() {
    if (!_current) throw const _TaskFailure('turn_not_current');
  }

  void _requireHost() {
    if (!_here || !_hasHost) throw const _TaskFailure('original_host_or_window_changed');
  }

  void _requireMap() {
    if (!_mapHere) throw const _TaskFailure('original_map_window_changed');
  }

  static bool _supports(CompanionTasksCapability capability, String kind) => switch (kind) {
    'host.notes_to_todo' => capability.notes,
    'host.find_draft' => capability.findDraft && capability.sourceRead,
    'host.compare_drafts' => capability.compareDrafts,
    'host.receipts_to_sheet' => capability.receiptsToSheet && capability.artifactRead,
    _ => false,
  };
  static bool _shape(MemoryRow input, Map<String, Object?> schema) {
    final fields = schema['properties']! as Map;
    final required = schema['required']! as List;
    return input.keys.every(fields.containsKey) && required.every(input.containsKey);
  }

  static String _operation(MemoryRow input, {List<String> allowed = const ['create', 'amend', 'cancel']}) {
    final value = _text(input, 'operation');
    if (!allowed.contains(value)) throw const _TaskFailure('invalid_operation');
    return value;
  }

  static String _text(MemoryRow input, String field) =>
      _optionalText(input, field) ?? (throw _TaskFailure('${field}_missing'));
  static String? _optionalText(MemoryRow input, String field) {
    final value = input[field];
    if (value == null) return null;
    if (value is! String || value.trim().isEmpty) throw _TaskFailure('invalid_$field');
    return value;
  }

  static void _date(String value) {
    final parsed = DateTime.tryParse('${value}T00:00:00Z');
    if (value.length != 10 || parsed == null || parsed.toIso8601String().substring(0, 10) != value) {
      throw const _TaskFailure('invalid_date');
    }
  }

  static void _time(String value) {
    if (!RegExp(r'^(?:[01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) throw const _TaskFailure('invalid_time');
  }

  static String _errorCode(Object error) => switch (error) {
    _TaskFailure(:final code) => code,
    DshRemoteException(:final code) => code,
    PlatformException(:final code) => code,
    MissingPluginException() => 'phone_executor_unavailable',
    DshClosedException() => 'original_context_closed',
    _ => 'task_receipt_unconfirmed',
  };
  static CompanionAgentToolResult _failure(String code) => CompanionAgentToolResult(
    content: jsonEncode({
      'accepted': false,
      'code': code,
      'message': 'This tool request was not accepted. Explain the missing information or failure; do not claim it ran.',
    }),
    isError: true,
  );

  static const _textField = {'type': 'string', 'minLength': 1};
  static const _targetFields = <String, Object?>{
    'taskId': {'type': 'string', 'description': 'An exact ID read through task_status in this original room.'},
    'expectedTaskRev': {'type': 'integer', 'minimum': 1},
  };
  static const _operationFields = <String, Object?>{
    ..._targetFields,
    'operation': {
      'type': 'string',
      'enum': ['create', 'amend', 'cancel'],
    },
  };
  static const _hostFields = <String, Object?>{
    ..._operationFields,
    'afterExit': {
      'type': 'string',
      'enum': ['continue', 'pause'],
      'description': 'The user\'s actual agreed exit behavior; required for a new task.',
    },
    'allowQueue': {
      'type': 'boolean',
      'description': 'The user\'s actual permission to wait for the computer; required for a new task.',
    },
    'deadlineDate': _textField,
    'deadlineTime': {
      'type': ['string', 'null'],
      'description': 'HH:mm in the original phone zone, or null for no spoken deadline.',
    },
    'deadlineChoices': {
      'type': 'array',
      'items': _textField,
      'description': 'Ask the person to choose between actual ambiguous HH:mm interpretations.',
    },
  };
  static const phoneDefinitions = <CompanionAgentTool>[
    CompanionAgentTool(
      name: 'task_status',
      description: 'Read original task receipts in this room. Read IDs and revisions before amending or cancelling. A limited list never establishes uniqueness.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'taskId': _textField,
          'refresh': {'type': 'boolean'},
        },
        'required': [],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'reminder',
      description: 'Create, amend or cancel a real phone reminder. Text must be a literal excerpt of the user\'s original message (or unchanged original reminder). Dates are YYYY-MM-DD, time HH:mm; resolve relative language using the original message time. Missing or ambiguous time stays waiting, never guessed.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._operationFields,
          'text': _textField,
          'localDate': _textField,
          'localTime': _textField,
          'zoneId': _textField,
          'selectedOffsetSeconds': {'type': 'integer'},
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'public_lookup',
      description: 'Check published opening information using actual search, fetched sources and evidence. New lookups run on this phone in both modes and keep the original two-minute deadline. An explicit city needs its explicit zone. Cancellation of an old Host lookup preserves its original executor and stop evidence.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._targetFields,
          'operation': {
            'type': 'string',
            'enum': ['create', 'cancel'],
          },
          'placeName': _textField,
          'city': _textField,
          'localDate': _textField,
          'zoneId': _textField,
          'question': _textField,
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'map_open',
      description: 'Hand a complete literal address to a map selected by the person. Requires this actual foreground window. Reopen is a new explicit action; reading or retrying an old receipt never opens a map.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._targetFields,
          'operation': {
            'type': 'string',
            'enum': ['create', 'amend', 'cancel', 'reopen'],
          },
          'address': _textField,
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
  ];
  static const hostDefinitions = <CompanionAgentTool>[
    CompanionAgentTool(
      name: 'notes_to_todo',
      description: 'Ask the connected computer to summarize notes into a new todo file. The person selects the real directory. A new task needs the actual date and exit/queue agreement. Pause work starts only through this turn\'s original foreground opportunity.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._hostFields,
          'localDate': _textField,
          'outputName': _textField,
          'directoryHint': _textField,
          'chooseDirectory': {'type': 'boolean'},
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'find_draft',
      description: 'Find original md/txt drafts in one selected computer directory and original date window, with real source binding. No recursive directory scan. The person selects the directory; no path or file ref is accepted from the model.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._hostFields,
          'localDate': _textField,
          'extensions': {
            'type': 'array',
            'items': {
              'type': 'string',
              'enum': ['md', 'txt'],
            },
          },
          'directoryHint': _textField,
          'chooseDirectory': {'type': 'boolean'},
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'compare_drafts',
      description: 'Compare two original draft versions selected in A/B order by the person. The computer may highlight at most three changes; it never overwrites either original.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._hostFields,
          'chooseInputs': {'type': 'boolean'},
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
    CompanionAgentTool(
      name: 'receipts_to_sheet',
      description: 'Make a new .xlsx from exactly four original receipts selected by the person plus a real output directory. Keep original files and ambiguous values; never fabricate cells or file references.',
      inputSchema: {
        'type': 'object',
        'properties': {
          ..._hostFields,
          'outputName': _textField,
          'chooseInputs': {'type': 'boolean'},
        },
        'required': ['operation'],
        'additionalProperties': false,
      },
    ),
  ];
}

class _TaskFailure implements Exception {
  const _TaskFailure(this.code);
  final String code;
}
