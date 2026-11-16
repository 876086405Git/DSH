// What a card's script asks of the engine (P2 B1, Tavern.scripts) over its
// page's channel, and what it is told back: one JSON request
//   {"id": …, "method": "getVariables", "params": {…}}
// and one JSON reply
//   {"id": …, "ok": true, "result": …} or {"id": …, "ok": false, "error": {…}}.
//
// The rules the engine's App notes set for a wire (API-INTEGRATION, B1 §2):
// versions and revisions go out and come back as the opaque strings they
// are; a member present as null stays present; a message whose data is not
// an object reads data: null with its raw value beside it; every refusal —
// thrown at the call or later — comes back as a structured error, never as
// a channel failure. This first part carries reading (capabilities,
// contexts, messages), message writes (the engine's field names; a field it
// does not know is refused by it, never dropped here), variables and prompt
// injections (B2; a filter goes as the name of a function the page keeps).
// snapshot gives a page what its synchronous getters read.
// updateVariablesWith is not a wire method: a script's
// function stays in the page (read, call it once, replace with the version
// it read).

import 'dart:convert';
import 'dart:typed_data';

import 'package:dsh_tavern/dsh_tavern.dart';

class TavernScriptWire {
  TavernScriptWire(this.bridge, {this.onGeneration});

  final TavernScriptBridge bridge;

  /// Told each event of a generation asked over this wire while it runs
  /// (its words as they come), for the page that asked; the reply itself
  /// waits for the result.
  final void Function(Map<String, Object?> event)? onGeneration;

  /// The reply to [request], always JSON; never throws.
  Future<Map<String, Object?>> handle(Object? request) async {
    final id = request is Map ? request['id'] : null;
    try {
      if (request is! Map) throw _bad('request', 'A request is a JSON object.');
      final method = request['method'];
      if (method is! String) throw _bad('request', 'A request names its method.');
      final params = request['params'] ?? const <String, Object?>{};
      if (params is! Map) throw _bad(method, 'params is a JSON object.');
      final p = _Params(method, params);
      return {'id': id, 'ok': true, 'result': await _call(method, p)};
    } on TavernScriptException catch (e) {
      return {'id': id, 'ok': false, 'error': tavernScriptErrorJson(e)};
    } on Object catch (e) {
      // Not the engine's own refusal: said as such, not dressed as one.
      return {
        'id': id,
        'ok': false,
        'error': {'code': 'internal', 'message': '$e', 'committed': false},
      };
    }
  }

  Future<Object?> _call(String method, _Params p) async {
    switch (method) {
      case 'capabilities':
        final c = bridge.capabilities;
        return {
          'adapterVersion': c.adapterVersion,
          'methods': [...c.methods]..sort(),
          'scopes': [for (final s in c.scopes) s.name]..sort(),
          'hostAttached': c.hostAttached,
          'simulated': c.simulated,
        };
      case 'openContext':
        final context = await bridge.openContext(
          TavernScriptContextSpec(
            instanceId: p.string('instanceId'),
            chatId: p.stringOrNull('chatId'),
            characterId: p.stringOrNull('characterId'),
            nodeId: p.stringOrNull('nodeId'),
            script: p.has('script') ? _owner(p.object('script'), p.method) : null,
          ),
        );
        return _context(context);
      case 'snapshot':
        // What a page keeps for its synchronous getters (P2 §4.3): the
        // path's messages and the variables the context sees, as of lastSeq.
        final s = await bridge.snapshot(p.string('contextId'));
        return {
          'context': _context(s.context),
          'engineEpoch': s.engineEpoch,
          'lastSeq': s.lastSeq,
          'pathRevision': s.pathRevision,
          'messages': [for (final m in s.messages) tavernScriptMessageJson(m)],
          'variables': [for (final v in s.variableSnapshots) tavernScriptVariablesJson(v)],
          'presetId': s.presetId,
          'personaId': s.personaId,
          'memberCharacterIds': s.memberCharacterIds,
          'resourceRefs': s.resourceRefs,
        };
      case 'closeContext':
        await bridge.closeContext(p.string('contextId'));
        return null;
      case 'getChatMessages':
        final range = p.has('range') ? p.object('range') : const <String, Object?>{};
        final page = await bridge.getChatMessages(
          p.string('contextId'),
          TavernMessageRange(first: _intOrNull(range, 'first', p.method), last: _intOrNull(range, 'last', p.method)),
          role: p.has('role') ? _enum(TavernScriptRole.values, p.string('role'), 'role', p.method) : null,
          hidden: p.has('hidden')
              ? _enum(TavernHiddenFilter.values, p.string('hidden'), 'hidden', p.method)
              : TavernHiddenFilter.all,
          includeSwipes: p.boolOr('includeSwipes', false),
        );
        return {
          'pathRevision': page.pathRevision,
          'totalPathLength': page.totalPathLength,
          'messages': [for (final m in page.messages) tavernScriptMessageJson(m)],
        };
      case 'setChatMessages':
        return _mutation(
          await bridge.setChatMessages(p.string('contextId'), [
            for (final (i, x) in p.list('patches').indexed) _patch(x, i, p.method),
          ], options: _write(p)),
        );
      case 'createChatMessages':
        return _mutation(
          await bridge.createChatMessages(
            p.string('contextId'),
            [for (final (i, x) in p.list('messages').indexed) _draft(x, i, p.method)],
            insertBefore: _intOrNull(p._map.cast<String, Object?>(), 'insertBefore', p.method),
            options: _write(p),
          ),
        );
      case 'deleteChatMessages':
        return _mutation(
          await bridge.deleteChatMessages(p.string('contextId'), [
            for (final id in p.list('messageIds'))
              switch (id) {
                final int n => n,
                _ => throw _bad(p.method, 'A floor is a whole number.', fieldPath: 'messageIds'),
              },
          ], options: _write(p)),
        );
      case 'rotateChatMessages':
        return _mutation(
          await bridge.rotateChatMessages(
            p.string('contextId'),
            p.integer('begin'),
            p.integer('middle'),
            p.integer('end'),
            options: _write(p),
          ),
        );
      case 'getVariables':
        return tavernScriptVariablesJson(
          await bridge.getVariables(p.string('contextId'), _target(p.object('target'), p.method)),
        );
      case 'replaceVariables':
        return tavernScriptVariablesJson(
          await bridge.replaceVariables(
            p.string('contextId'),
            _target(p.object('target'), p.method),
            p.object('value'),
            expectedVersion: p.stringOrNull('expectedVersion'),
          ),
        );
      case 'mutateVariables':
        final mutation = await bridge.mutateVariables(p.string('contextId'), _target(p.object('target'), p.method), [
          for (final (i, c) in p.list('changes').indexed) _change(c, i, p.method),
        ], expectedVersion: p.stringOrNull('expectedVersion'));
        return {
          'snapshot': tavernScriptVariablesJson(mutation.snapshot),
          'results': [
            for (final r in mutation.results)
              {'kind': r.kind.name, 'path': r.pathTokens, 'existed': r.existed, 'changed': r.changed},
          ],
        };
      // Prompt injections (B2): the engine's field names; a filter is the
      // reference to a function kept in the page, never the function.
      case 'injectPrompts':
        final lease = await bridge.injectPrompts(p.string('contextId'), [
          for (final (i, x) in p.list('prompts').indexed)
            TavernScriptInjection.fromJson(_asObject(x, 'prompts[$i]', p.method)),
        ], once: p.boolOr('once', false));
        return {
          'leaseId': lease.leaseId,
          'chatId': lease.chatId,
          'ownerContextId': lease.ownerContextId,
          'ownerInstanceId': lease.ownerInstanceId,
          'registrations': [
            for (final r in lease.registrations) {'id': r.id, 'registrationVersion': r.registrationVersion},
          ],
        };
      case 'uninjectPrompts':
        await bridge.uninjectPrompts(p.string('contextId'), [
          for (final (i, id) in p.list('ids').indexed)
            switch (id) {
              final String s => s,
              _ => throw _bad(p.method, 'An injection id is a string.', fieldPath: 'ids[$i]'),
            },
        ]);
        return null;
      case 'releaseInjectionLease':
        await bridge.releaseInjectionLease(p.string('leaseId'));
        return null;
      case 'listInjections':
        return [for (final v in await bridge.listInjections(p.string('contextId'))) tavernScriptInjectionViewJson(v)];
      // Asking the model (B2): the engine's request fields; the reply is the
      // result once it is in, its events told on the way ([onGeneration]).
      case 'generate' || 'generateRaw':
        final contextId = p.string('contextId');
        final request = p.object('request');
        final handle = p.method == 'generate'
            ? await bridge.generate(contextId, TavernScriptGenerateRequest.fromJson(request))
            : await bridge.generateRaw(contextId, TavernScriptRawRequest.fromJson(request));
        final told = onGeneration;
        final watch = told == null ? null : handle.events.listen((e) => told(tavernScriptGenerationEventJson(e)));
        try {
          final result = await handle.result;
          return {
            'id': result.id,
            'text': result.text,
            'reasoning': result.reasoning,
            'finishReason': result.finishReason,
            'hookIssues': [for (final x in result.hookIssues) _issueJson(x)],
          };
        } finally {
          await watch?.cancel();
        }
      case 'stopGenerationById':
        return bridge.stopGenerationById(p.string('generationId'));
      // A Slash script (B3): run to its end; the reply is its pipe and how it
      // ended (completed, or aborted by /abort). A failure is the error.
      case 'triggerSlash':
        final arguments = <String, String>{
          if (p.has('arguments'))
            for (final MapEntry(:key, :value) in p.object('arguments').entries)
              key: switch (value) {
                final String s => s,
                _ => throw _bad(p.method, 'An argument is a string.', fieldPath: 'arguments.$key'),
              },
        };
        final run = await bridge.triggerSlash(
          p.string('contextId'),
          p.string('source'),
          executionId: p.stringOrNull('executionId'),
          pipe: p.stringOrNull('pipe') ?? '',
          arguments: arguments,
        );
        final result = await run.result;
        return {'id': result.id, 'pipe': result.pipe, 'completion': result.completion.name};
      case 'stopScript':
        return bridge.stopScript(p.string('executionId'));
      // The regexes in play for this context, as 酒馆助手's getTavernRegexes
      // hands them out, by where each comes from (global, the preset in use,
      // the chat's character, the chat's own), in the order they apply.
      case 'getTavernRegexes':
        final regexes = await bridge.getTavernRegexes(
          p.string('contextId'),
          TavernScriptRegexQuery(
            effectiveOnly: p.boolOr('effectiveOnly', false),
            characterId: p.stringOrNull('characterId'),
            presetId: p.stringOrNull('presetId'),
          ),
        );
        return {
          for (final source in TavernScriptRegexSource.values)
            source.name: [
              for (final r in regexes)
                if (r.source == source) tavernHelperRegexJson(r),
            ],
        };
      // Stage 4 (STAGE4-APP-INTEGRATION §2): MVU, world info, books and their
      // bindings, presets, regex sources, a script's buttons, a character's
      // picture. Each answer is the engine's snapshot as it gives it.
      case 'setMvuEnabled':
        final init = await bridge.setMvuEnabled(p.string('contextId'), p.boolean('enabled'));
        return {
          'chatId': init.chatId,
          'enabled': init.enabled,
          'initializedRefs': [for (final r in init.initializedRefs) tavernScriptRefJson(r)],
          'issues': [for (final x in init.issues) _issueJson(x)],
        };
      case 'parseMvuMessage':
        final parsed = await bridge.parseMvuMessage(
          p.string('contextId'),
          p.string('message'),
          p.object('previousData'),
        );
        return {
          'data': parsed.data,
          'issues': [for (final x in parsed.issues) _issueJson(x)],
        };
      case 'updateWorldInfoSettings':
        return (await bridge.updateWorldInfoSettings(
          p.string('contextId'),
          p.object('patch'),
          expectedVersion: p.stringOrNull('expectedVersion'),
        )).toJson();
      case 'replaceScriptButtons':
        return (await bridge.replaceScriptButtons(p.string('contextId'), [
          for (final (i, x) in p.list('buttons').indexed) _button(x, i, p.method),
        ], expectedVersion: p.stringOrNull('expectedVersion'))).toJson();
      case 'getBookDirectory':
        final directory = await bridge.getBookDirectory(p.string('contextId'));
        return {
          'version': directory.version,
          'books': [for (final b in directory.books) b.toJson()],
          'issues': [for (final x in directory.issues) _issueJson(x)],
        };
      case 'resolveBook':
        return (await bridge.resolveBook(p.string('contextId'), p.string('nameOrHandle'))).toJson();
      case 'createBook':
        return _book(await bridge.createBook(p.string('contextId'), p.string('name'), p.object('raw')));
      case 'deleteBook':
        await bridge.deleteBook(
          p.string('contextId'),
          TavernScriptBookRef.fromJson(p.object('ref')),
          expectedVersion: p.string('expectedVersion'),
        );
        return null;
      case 'getContextBooks':
        return [
          for (final b in await bridge.getContextBooks(p.string('contextId')))
            {
              'ref': b.ref.toJson(),
              'source': b.source.name,
              'chatId': b.chatId,
              'personaId': b.personaId,
              'characterId': b.characterId,
            },
        ];
      case 'readBook':
        return _book(await bridge.readBook(p.string('contextId'), TavernScriptBookRef.fromJson(p.object('ref'))));
      case 'replaceBook':
        return _book(
          await bridge.replaceBook(
            p.string('contextId'),
            TavernScriptBookRef.fromJson(p.object('ref')),
            p.object('book'),
            expectedVersion: p.stringOrNull('expectedVersion'),
          ),
        );
      case 'readBookBindings':
        final target = _Params(p.method, p.object('target'));
        return _bindings(
          await bridge.readBookBindings(
            p.string('contextId'),
            TavernScriptBookBindingsTarget(
              scope: _enum(TavernScriptBookBindingScope.values, target.string('scope'), 'target.scope', p.method),
              targetId: target.stringOrNull('targetId'),
            ),
          ),
        );
      case 'updateBookBindings':
        final edit = _Params(p.method, p.object('edit'));
        return _bindings(
          await bridge.updateBookBindings(
            p.string('contextId'),
            TavernScriptBookBindingsEdit(
              scope: _enum(TavernScriptBookBindingScope.values, edit.string('scope'), 'edit.scope', p.method),
              targetId: edit.stringOrNull('targetId'),
              primary: edit.has('primary') ? TavernScriptBookRef.fromJson(edit.object('primary')) : null,
              additional: [
                if (edit.has('additional'))
                  for (final (i, x) in edit.list('additional').indexed)
                    TavernScriptBookRef.fromJson(_asObject(x, 'edit.additional[$i]', p.method)),
              ],
            ),
            expectedVersion: p.string('expectedVersion'),
          ),
        );
      case 'readPreset':
        return (await bridge.readPreset(p.string('contextId'), _presetRef(p.object('ref'), p.method))).toJson();
      case 'replacePreset':
        return (await bridge.replacePreset(
          p.string('contextId'),
          _presetRef(p.object('ref'), p.method),
          p.object('raw'),
          expectedVersion: p.string('expectedVersion'),
        )).toJson();
      case 'readTavernRegexesForWrite':
        return (await bridge.readTavernRegexesForWrite(
          p.string('contextId'),
          _regexTarget(p.object('target'), p.method),
        )).toJson();
      case 'replaceTavernRegexes':
        return (await bridge.replaceTavernRegexes(p.string('contextId'), _regexTarget(p.object('target'), p.method), [
          for (final (i, x) in p.list('items').indexed)
            switch (_asObject(x, 'items[$i]', p.method)) {
              final item => TavernScriptRegexWriteItem(
                engineId: _Params(p.method, item).stringOrNull('engineId'),
                raw: _asObject(item['raw'], 'items[$i].raw', p.method),
              ),
            },
        ], expectedVersion: p.string('expectedVersion'))).toJson();
      // A picture goes both ways as base64 (null: the character has none).
      case 'readCharacterAvatar':
        return _avatar(await bridge.readCharacterAvatar(p.string('contextId'), p.string('characterId')));
      case 'replaceCharacterAvatar':
        final Uint8List bytes;
        try {
          bytes = base64Decode(p.string('bytes'));
        } on FormatException {
          throw _bad(p.method, 'bytes is the picture in base64.', fieldPath: 'bytes');
        }
        return _avatar(
          await bridge.replaceCharacterAvatar(
            p.string('contextId'),
            p.string('characterId'),
            bytes,
            expectedVersion: p.string('expectedVersion'),
          ),
        );
      case 'replaceCharacterData':
        final character = await bridge.replaceCharacterData(
          p.string('contextId'),
          p.string('characterId'),
          p.object('data'),
          expectedVersion: p.stringOrNull('expectedVersion'),
        );
        return {'id': character.id, 'name': character.name};
      case 'substituteMacros':
        return bridge.substituteMacros(p.string('contextId'), p.string('text'));
    }
    throw TavernScriptException(
      code: TavernScriptErrorCode.unsupportedCapability,
      operation: method,
      message: 'The page channel does not carry $method.',
    );
  }
}

/// [r] in 酒馆助手's TavernRegex shape, as the engine runs it (its parsed
/// [TavernScriptRegex.execution]: a legacy placement 0 or 4 already spread
/// to what it means, a placement that is not a whole number dropped):
/// its ST fields renamed; where it runs (ST's placements 1 user input, 2 AI
/// output, 3 slash command, 5 world info, 6 reasoning); and its destination,
/// which is ST's two checkboxes as they are (display is 仅格式显示,
/// markdownOnly; prompt is 仅格式提示词, promptOnly; neither, it changes the
/// message itself).
Map<String, Object?> tavernHelperRegexJson(TavernScriptRegex r) {
  final script = r.execution;
  final placement = script.placement.toSet();
  return {
    'id': script.id.isNotEmpty ? script.id : r.stId,
    'script_name': script.scriptName,
    'enabled': r.enabled,
    'run_on_edit': script.runOnEdit,
    if (r.source != TavernScriptRegexSource.preset) 'scope': r.source.name,
    'find_regex': script.findRegex,
    'trim_strings': script.trimStrings.join('\n'),
    'replace_string': script.replaceString,
    'source': {
      'user_input': placement.contains(RegexPlacement.userInput),
      'ai_output': placement.contains(RegexPlacement.aiOutput),
      'slash_command': placement.contains(RegexPlacement.slashCommand),
      'world_info': placement.contains(RegexPlacement.worldInfo),
      'reasoning': placement.contains(RegexPlacement.reasoning),
    },
    'destination': {'display': script.markdownOnly, 'prompt': script.promptOnly},
    'min_depth': script.minDepth,
    'max_depth': script.maxDepth,
  };
}

TavernScriptException _bad(String operation, String message, {String? fieldPath}) => TavernScriptException(
  code: TavernScriptErrorCode.invalidArgument,
  operation: operation,
  message: message,
  fieldPath: fieldPath,
);

/// A refusal as the page reads it.
Map<String, Object?> tavernScriptErrorJson(TavernScriptException e) => {
  'code': e.code.name,
  'operation': e.operation,
  'message': e.message,
  'committed': e.committed,
  'contextId': e.contextId,
  'nodeId': e.nodeId,
  'fieldPath': e.fieldPath,
  'issues': [for (final x in e.issues) _issueJson(x)],
};

/// A request's params, read strictly: the wrong type is the caller's error,
/// named by its field.
class _Params {
  _Params(this.method, this._map);

  final String method;
  final Map<Object?, Object?> _map;

  bool has(String key) => _map.containsKey(key) && _map[key] != null;

  Object? _need(String key) {
    if (!_map.containsKey(key)) throw _bad(method, '$key is missing.', fieldPath: key);
    return _map[key];
  }

  String string(String key) => switch (_need(key)) {
    final String s => s,
    _ => throw _bad(method, '$key is a string.', fieldPath: key),
  };

  String? stringOrNull(String key) => switch (_map[key]) {
    null => null,
    final String s => s,
    _ => throw _bad(method, '$key is a string.', fieldPath: key),
  };

  int integer(String key) => switch (_need(key)) {
    final int n => n,
    _ => throw _bad(method, '$key is a whole number.', fieldPath: key),
  };

  bool boolean(String key) => switch (_need(key)) {
    final bool b => b,
    _ => throw _bad(method, '$key is true or false.', fieldPath: key),
  };

  bool boolOr(String key, bool otherwise) => switch (_map[key]) {
    null => otherwise,
    final bool b => b,
    _ => throw _bad(method, '$key is true or false.', fieldPath: key),
  };

  Map<String, Object?> object(String key) => _asObject(_need(key), key, method);

  List<Object?> list(String key) => switch (_need(key)) {
    final List<Object?> l => l,
    _ => throw _bad(method, '$key is a list.', fieldPath: key),
  };
}

Map<String, Object?> _asObject(Object? value, String field, String method) {
  if (value is! Map) throw _bad(method, '$field is a JSON object.', fieldPath: field);
  final out = <String, Object?>{};
  for (final MapEntry(:key, :value) in value.entries) {
    if (key is! String) throw _bad(method, '$field has a key that is not a string.', fieldPath: field);
    out[key] = value;
  }
  return out;
}

int? _intOrNull(Map<String, Object?> map, String key, String method) => switch (map[key]) {
  null => null,
  final int n => n,
  _ => throw _bad(method, '$key is a whole number.', fieldPath: key),
};

T _enum<T extends Enum>(List<T> values, String name, String field, String method) {
  for (final v in values) {
    if (v.name == name) return v;
  }
  throw _bad(method, '$field is one of ${values.map((v) => v.name).join(', ')}.', fieldPath: field);
}

TavernScriptOwner _owner(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernScriptOwner(
    kind: _enum(TavernScriptOwnerKind.values, p.string('kind'), 'script.kind', method),
    scriptId: p.string('scriptId'),
    assetId: p.stringOrNull('assetId'),
  );
}

TavernScriptMessageRef _ref(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernScriptMessageRef(chatId: p.string('chatId'), nodeId: p.string('nodeId'));
}

TavernVariableTarget _target(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return TavernVariableTarget(
    scope: _enum(TavernVariableScope.values, p.string('scope'), 'target.scope', method),
    characterId: p.stringOrNull('characterId'),
    chatId: p.stringOrNull('chatId'),
    messageId: _intOrNull(json, 'messageId', method),
    messageRef: p.has('messageRef') ? _ref(p.object('messageRef'), method) : null,
    scriptOwner: p.has('scriptOwner') ? _owner(p.object('scriptOwner'), method) : null,
  );
}

/// One change; `value` present (even as null) is a value, absent is none.
TavernVariableChange _change(Object? json, int at, String method) {
  final change = _asObject(json, 'changes[$at]', method);
  final p = _Params(method, change);
  final path = <Object>[
    for (final token in p.list('path'))
      switch (token) {
        final String s => s,
        final int n when n >= 0 => n,
        _ => throw _bad(method, 'A path step is a key or an index from 0.', fieldPath: 'changes[$at].path'),
      },
  ];
  final kind = _enum(TavernVariableChangeKind.values, p.string('kind'), 'changes[$at].kind', method);
  return change.containsKey('value')
      ? TavernVariableChange(kind: kind, pathTokens: path, value: change['value'])
      : TavernVariableChange(kind: kind, pathTokens: path);
}

TavernScriptButton _button(Object? json, int at, String method) {
  final p = _Params(method, _asObject(json, 'buttons[$at]', method));
  return TavernScriptButton(name: p.string('name'), visible: p.boolOr('visible', true));
}

TavernScriptPresetRef _presetRef(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return switch (p.string('kind')) {
    'stored' => TavernScriptPresetRef.stored(p.string('presetId')),
    'current' => const TavernScriptPresetRef.current(),
    _ => throw _bad(method, 'A preset is {kind: stored, presetId} or {kind: current}.', fieldPath: 'ref.kind'),
  };
}

TavernScriptRegexWriteTarget _regexTarget(Map<String, Object?> json, String method) {
  final p = _Params(method, json);
  return switch (p.string('kind')) {
    'globalInline' => const TavernScriptRegexWriteTarget.globalInline(),
    'globalLibrary' => const TavernScriptRegexWriteTarget.globalLibrary(),
    'character' => TavernScriptRegexWriteTarget.character(characterId: p.string('characterId')),
    'preset' => TavernScriptRegexWriteTarget.preset(preset: _presetRef(p.object('preset'), method)),
    _ => throw _bad(method, 'kind is globalInline, globalLibrary, character or preset.', fieldPath: 'target.kind'),
  };
}

Map<String, Object?> _book(TavernScriptBookSnapshot b) => {'ref': b.ref.toJson(), 'version': b.version, 'book': b.book};

Map<String, Object?> _bindings(TavernScriptBookBindingsSnapshot b) => {
  'scope': b.scope.name,
  'targetId': b.targetId,
  'version': b.version,
  'primary': b.primary?.toJson(),
  'additional': [for (final r in b.additional) r.toJson()],
  'inherited': [for (final r in b.inherited) r.toJson()],
};

Map<String, Object?> _avatar(TavernScriptCharacterAvatarSnapshot a) => {
  'characterId': a.characterId,
  'version': a.version,
  'bytes': switch (a.bytes) {
    final bytes? => base64Encode(bytes),
    null => null,
  },
};

/// A write's options: the path revision it expects (opaque) and what to redraw.
TavernScriptWriteOptions _write(_Params p) {
  final options = p.has('options') ? p.object('options') : const <String, Object?>{};
  final o = _Params(p.method, options);
  return TavernScriptWriteOptions(
    expectedPathRevision: o.stringOrNull('expectedPathRevision'),
    refresh: o.has('refresh')
        ? _enum(TavernScriptRefresh.values, o.string('refresh'), 'options.refresh', p.method)
        : TavernScriptRefresh.affected,
  );
}

/// One message to change: by floor or by stable ref, and the fields as the
/// engine names them (the engine checks them all).
TavernScriptMessagePatch _patch(Object? json, int at, String method) {
  final patch = _asObject(json, 'patches[$at]', method);
  final p = _Params(method, patch);
  return TavernScriptMessagePatch(
    messageId: _intOrNull(patch, 'messageId', method),
    ref: p.has('ref') ? _ref(p.object('ref'), method) : null,
    fields: p.object('fields'),
  );
}

/// One message to create. data given as null is refused (absent is none).
TavernScriptMessageDraft _draft(Object? json, int at, String method) {
  final draft = _asObject(json, 'messages[$at]', method);
  final p = _Params(method, draft);
  if (draft.containsKey('data') && draft['data'] == null) {
    throw _bad(method, 'data is an object when given.', fieldPath: 'messages[$at].data');
  }
  return TavernScriptMessageDraft(
    role: _enum(TavernScriptRole.values, p.string('role'), 'messages[$at].role', method),
    message: p.string('message'),
    name: p.stringOrNull('name'),
    speakerCharacterId: p.stringOrNull('speakerCharacterId'),
    hidden: p.boolOr('hidden', false),
    data: draft.containsKey('data') ? p.object('data') : null,
    extra: p.has('extra') ? p.object('extra') : const {},
  );
}

/// What a write did, as the page reads it; a floor whose message went is
/// kept as null.
Map<String, Object?> _mutation(TavernScriptMutation m) => {
  'oldRevision': m.oldRevision,
  'pathRevision': m.pathRevision,
  'upsertMessages': [for (final x in m.upsertMessages) tavernScriptMessageJson(x)],
  'affectedRefs': [for (final r in m.affectedRefs) tavernScriptRefJson(r)],
  'removedRefs': [for (final r in m.removedRefs) tavernScriptRefJson(r)],
  'indexChanges': {
    for (final MapEntry(:key, :value) in m.indexChanges.entries)
      '$key': value == null ? null : tavernScriptRefJson(value),
  },
  'refresh': m.refresh.name,
};

Map<String, Object?>? _ownerJson(TavernScriptOwner? o) =>
    o == null ? null : {'kind': o.kind.name, 'scriptId': o.scriptId, 'assetId': o.assetId};

Map<String, Object?> tavernScriptRefJson(TavernScriptMessageRef r) => {'chatId': r.chatId, 'nodeId': r.nodeId};

/// An injection as the engine lists it: where it comes from, as written, and
/// as read (null when it could not be), its filter's state and its lease.
Map<String, Object?> tavernScriptInjectionViewJson(TavernScriptInjectionView v) {
  final i = v.injection;
  return {
    'source': v.source.name,
    'sourceRef': v.sourceRef,
    'raw': v.raw,
    'injection': i == null
        ? null
        : {
            'id': i.id,
            'content': i.content,
            'role': i.role.name,
            'position': i.position.name,
            'depth': i.depth,
            'scan': i.scan,
            'filter': i.filter == null
                ? null
                : {
                    'contextId': i.filter!.contextId,
                    'instanceId': i.filter!.instanceId,
                    'callbackId': i.filter!.callbackId,
                  },
          },
    'filterStatus': v.filterStatus,
    'issues': [for (final x in v.issues) _issueJson(x)],
    'ownerContextId': v.ownerContextId,
    'ownerInstanceId': v.ownerInstanceId,
    'registrationVersion': v.registrationVersion,
    'once': v.once,
    'claimed': v.claimed,
    'leaseId': v.leaseId,
  };
}

/// A generation's event as the page reads it: which, how it stands, and its
/// words so far ([text]) or just now ([delta]).
Map<String, Object?> tavernScriptGenerationEventJson(TavernScriptGenerationEvent e) => {
  'id': e.id,
  'seq': e.seq,
  'event': e.kind.name,
  'status': e.status.name,
  'text': e.text,
  'delta': e.delta,
  'reasoning': e.reasoning,
  'finishReason': e.finishReason,
  'isSnapshot': e.isSnapshot,
};

Map<String, Object?> _issueJson(TavernScriptIssue i) => {
  'code': i.code,
  'message': i.message,
  'committed': i.committed,
  'stage': i.stage,
  'details': i.details,
};

Map<String, Object?> _context(TavernScriptContext c) => {
  'id': c.id,
  'engineEpoch': c.engineEpoch,
  'instanceId': c.instanceId,
  'chatId': c.chatId,
  'characterId': c.characterId,
  'nodeId': c.nodeId,
  'script': _ownerJson(c.script),
};

Map<String, Object?> _targetJson(TavernVariableTarget t) => {
  'scope': t.scope.name,
  'characterId': t.characterId,
  'chatId': t.chatId,
  'messageId': t.messageId,
  'messageRef': t.messageRef == null ? null : tavernScriptRefJson(t.messageRef!),
  'scriptOwner': _ownerJson(t.scriptOwner),
};

Map<String, Object?> tavernScriptVariablesJson(TavernVariableSnapshot s) => {
  'target': _targetJson(s.resolvedTarget),
  'version': s.version,
  'value': s.value,
};

Map<String, Object?>? _issue(TavernScriptShapeIssue? i) =>
    i == null ? null : {'fieldPath': i.fieldPath, 'actualKind': i.actualKind, 'message': i.message};

Map<String, Object?> tavernScriptMessageJson(TavernScriptMessage m) => {
  'messageId': m.messageId,
  'ref': tavernScriptRefJson(m.ref),
  'name': m.name,
  'role': m.role.name,
  'nativeRole': m.nativeRole.name,
  'message': m.message,
  'hidden': m.hidden,
  'speakerCharacterId': m.speakerCharacterId,
  'hasData': m.hasData,
  'data': m.data,
  'rawData': m.rawData,
  'dataIssue': _issue(m.dataIssue),
  'extra': m.extra,
  'swipeId': m.swipeId,
  'swipes': [
    for (final s in m.swipes)
      {
        'ref': tavernScriptRefJson(s.ref),
        'swipeId': s.swipeId,
        'text': s.text,
        'hasData': s.hasData,
        'data': s.data,
        'rawData': s.rawData,
        'dataIssue': _issue(s.dataIssue),
        'info': s.info,
      },
  ],
};
