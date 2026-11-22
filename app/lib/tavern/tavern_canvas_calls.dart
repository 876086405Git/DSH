// A canvas page's calls into the engine: what a card's script asks with
// `await dsh.call('getVariables', {target: {scope: 'chat'}})`. Each goes
// through [TavernScriptWire] within this chat's own script context, which is
// opened on the first call that needs one and closed with the page; a call
// may still name another context it opened itself. With [pages], the engine's
// deliveries for that context come back through [deliver] (the page's own
// copy of variables and messages stays current).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:flutter/foundation.dart';

import 'tavern_script_host.dart';
import 'tavern_script_wire.dart';

class TavernCanvasCalls {
  TavernCanvasCalls(
    this._bridge, {
    required this.chatId,
    required this.characterId,
    this.instanceId = 'canvas',
    this.pages,
    this.avatar,
    this.interact,
  });

  /// Who shows this chat's script UI requests (/input, /buttons, …).
  final TavernScriptInteractor? interact;

  /// The chat character's picture as the page can show it (a data: URL),
  /// for getCharAvatarPath; null when it has none. The app's, not the
  /// engine's: asked as 'characterAvatar'.
  final Future<String?> Function(String characterId)? avatar;

  final TavernScriptBridge _bridge;
  final String chatId;

  /// The chat's character as it is when the context opens; null for a group
  /// (the engine does not guess a member for it).
  final String? Function() characterId;

  /// Who the page is to the engine: its running instance, not a saved key.
  final String instanceId;

  /// The app's host, for the engine's deliveries to this page.
  final TavernScriptPages? pages;

  /// Puts a delivery into the page; null while there is no page to take it
  /// (it reloads a snapshot when it comes).
  TavernScriptPage? deliver;

  // A generation's events go to the page as they come, like a delivery.
  late final _wire = TavernScriptWire(_bridge, onGeneration: (e) => deliver?.call({...e, 'kind': 'generation'}));
  Future<String>? _context;
  String? _registered;

  /// Counts the contexts let go: one that finishes opening after its page
  /// was closed is not handed to the host.
  var _released = 0;

  static const _own = {'capabilities', 'openContext'};

  Future<String> _open() async {
    // The host first: deliveries for the context start as it opens.
    pages?.attach(_bridge);
    final released = _released;
    final id = (await _bridge.openContext(
      TavernScriptContextSpec(instanceId: instanceId, chatId: chatId, characterId: characterId()),
    )).id;
    if (released != _released) return id;
    _registered = id;
    pages?.add(id, (delivery) => deliver?.call(delivery) ?? Future.value(false), interact: interact, chatId: chatId);
    return id;
  }

  /// The scripts the page runs, by key ([tavernScriptKey]), as last chosen
  /// for this chat, and the character they were chosen with.
  var _scripts = <String, TavernRunnableScript>{};
  String? _scriptCharacter;

  /// The page's scripts now: one gone, or whose code changed (its frame
  /// starts over), has its context closed and its buttons dropped.
  void setScripts(TavernChatScripts chosen) {
    final next = {for (final s in chosen.scripts) tavernScriptKey(s.owner): s};
    final stale = {
      for (final MapEntry(:key, :value) in _scripts.entries)
        if (next[key]?.content != value.content) key,
    };
    _scripts = next;
    _scriptCharacter = chosen.characterId;
    if (stale.isEmpty) return;
    liveButtons.value = {...liveButtons.value}..removeWhere((key, _) => stale.contains(key));
    for (final key in stale) {
      if (_scriptContexts.remove(key) case final context?) unawaited(_closeContext(context));
    }
  }

  /// A script's own contexts (its buttons are kept on its owner), by key:
  /// each opened on the first call made as it ({asScript}). Not the page's:
  /// what the engine delivers goes to the page's context.
  final _scriptContexts = <String, Future<String>>{};

  Future<String> _openScript(String key) async {
    final script =
        _scripts[key] ??
        (throw TavernScriptException(
          code: TavernScriptErrorCode.closedContext,
          operation: 'openContext',
          message: 'That script no longer runs on this page.',
        ));
    final context = await _bridge.openContext(
      TavernScriptContextSpec(
        instanceId: '$instanceId:$key',
        chatId: chatId,
        characterId: _scriptCharacter,
        script: script.owner,
      ),
    );
    return context.id;
  }

  /// The buttons each script shows now, by key, as the page last said
  /// (replaceScriptButtons…); a script not here shows its own list's.
  final liveButtons = ValueNotifier<Map<String, List<String>>>(const {});

  /// The page saying what the buttons of the script [key] are now.
  void showButtons(String key, List<String> names) =>
      liveButtons.value = {...liveButtons.value, key: List.unmodifiable(names)};

  /// What scripts put in ST's places for buttons on the page (its QR bar,
  /// its extensions menu), as the page last said: each its id there and its
  /// words. A press goes back as {kind: press, id}.
  final hostButtons = ValueNotifier<List<({String id, String label})>>(const []);

  void _forget() {
    _released++;
    if (_registered case final id?) pages?.remove(id);
    _registered = null;
    _context = null;
  }

  /// The reply to [request], always JSON; never throws.
  Future<Map<String, Object?>> handle(Object? request) async {
    if (request is Map && request['method'] == 'characterAvatar') {
      final character = characterId();
      String? picture;
      try {
        picture = character == null ? null : await avatar?.call(character);
      } on Object {
        picture = null;
      }
      return {'id': request['id'], 'ok': true, 'result': picture};
    }
    if (request is! Map || request['method'] is! String || _own.contains(request['method'])) {
      return _wire.handle(request);
    }
    final params = request['params'] ?? const <Object?, Object?>{};
    if (params is! Map || params.containsKey('contextId')) return _wire.handle(request);
    final asScript = params['asScript'];
    void drop() => asScript is String ? _scriptContexts.remove(asScript) : _context = null;
    final String context;
    try {
      context = await (asScript is String ? _scriptContexts[asScript] ??= _openScript(asScript) : _context ??= _open());
    } on TavernScriptException catch (e) {
      drop();
      return {'id': request['id'], 'ok': false, 'error': tavernScriptErrorJson(e)};
    } on Object catch (e) {
      drop();
      return {
        'id': request['id'],
        'ok': false,
        'error': {'code': 'internal', 'message': '$e', 'committed': false},
      };
    }
    final reply = await _wire.handle({
      ...request,
      'params': {...params, 'contextId': context, ..._filters(params, context)},
    });
    // The engine let it go (reopened, closed): the next call opens anew.
    if (reply['error'] case {'code': 'closedContext' || 'noContext'}) {
      if (asScript is String) {
        _scriptContexts.remove(asScript);
      } else {
        _forget();
      }
    }
    return reply;
  }

  /// A prompt's filter, as the page names it ({callbackId}: a function it
  /// keeps), made the reference the engine calls back with: this context,
  /// this instance. A filter the page did not name that way goes as it was.
  Map<String, Object?> _filters(Map<Object?, Object?> params, String context) {
    if (params['prompts'] case final List<Object?> prompts) {
      return {
        'prompts': [
          for (final prompt in prompts)
            if (prompt case {'filter': {'callbackId': final String callbackId}})
              {
                ...prompt,
                'filter': {'contextId': context, 'instanceId': instanceId, 'callbackId': callbackId},
              }
            else
              prompt,
        ],
      };
    }
    return const {};
  }

  /// The page's answer to a filter it ran ({requestId, status, value, …}).
  void invoked(Map<Object?, Object?> answer) {
    if (answer['requestId'] case final String id) pages?.invoked(id, answer);
  }

  /// The page is up: its context opens now, so the host reaches it even
  /// with no script of its own on it (a preset's SPreset functions run
  /// here). One that fails to open is opened again by the next call.
  void pageReady() {
    if (_context != null) return;
    final opening = _context = _open();
    opening.then<void>(
      (_) {},
      onError: (Object _) {
        if (identical(_context, opening)) _context = null;
      },
    );
  }

  /// The page's answer to an SPreset evaluation it ran.
  void spreset(Map<Object?, Object?> answer) => pages?.spresetAnswered(answer);

  /// The page's answer to a lifecycle event it ran ({eventId, status, issues}).
  void acknowledge(Map<Object?, Object?> answer) {
    if (answer['eventId'] case final String id) pages?.acknowledge(id, answer);
  }

  /// The page itself went (its renderer was lost): what it was running did
  /// not finish; the context stays for the page that replaces it.
  void pageLost() {
    if (_registered case final id?) pages?.drop(id);
  }

  /// The page is gone: its contexts go with it.
  Future<void> close() async {
    final context = _context;
    final scripts = [..._scriptContexts.values];
    _scriptContexts.clear();
    _forget();
    for (final script in scripts) {
      await _closeContext(script);
    }
    if (context != null) await _closeContext(context);
  }

  Future<void> _closeContext(Future<String> context) async {
    try {
      await _bridge.closeContext(await context);
    } on Object {
      // Never opened, or already closed: nothing to release.
    }
  }
}

/// The picture at [path] as a data: URL a page can show (PNG, JPEG, GIF or
/// WebP, known by its first bytes); null when there is none to read.
Future<String?> tavernImageDataUrl(String? path) async {
  if (path == null || path.isEmpty) return null;
  final file = File(path);
  if (!await file.exists()) return null;
  final bytes = await file.readAsBytes();
  bool starts(List<int> head, [int at = 0]) {
    if (bytes.length < at + head.length) return false;
    for (var i = 0; i < head.length; i++) {
      if (bytes[at + i] != head[i]) return false;
    }
    return true;
  }

  final type = starts([0x89, 0x50, 0x4E, 0x47])
      ? 'image/png'
      : starts([0xFF, 0xD8, 0xFF])
      ? 'image/jpeg'
      : starts([0x47, 0x49, 0x46, 0x38])
      ? 'image/gif'
      : starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8)
      ? 'image/webp'
      : null;
  return type == null ? null : 'data:$type;base64,${base64Encode(bytes)}';
}

/// The personas' pictures a canvas page has been sent (getPersonaAvatarPath
/// answers at once, so the page keeps them): each goes once, and again only
/// when it changes. A fresh page starts from nothing ([reset]).
class TavernCanvasPersonaAvatars {
  TavernCanvasPersonaAvatars({this.read = tavernImageDataUrl});

  /// A picture file as the page shows it.
  final Future<String?> Function(String? path) read;

  final _sent = <String, String?>{};

  void reset() => _sent.clear();

  /// What the page is to be told for [personas]: each persona whose picture
  /// changed, with it as a data: URL (null: none now). One that changed again
  /// while this was reading is left to the later call.
  Future<List<(String, String?)>> changes(List<TavernPersona> personas) async {
    final changed = <TavernPersona>[];
    for (final persona in personas) {
      final had = _sent.containsKey(persona.id);
      if (had ? _sent[persona.id] == persona.avatarPath : persona.avatarPath == null) {
        _sent[persona.id] = persona.avatarPath;
        continue;
      }
      _sent[persona.id] = persona.avatarPath;
      changed.add(persona);
    }
    final out = <(String, String?)>[];
    for (final persona in changed) {
      String? url;
      try {
        url = await read(persona.avatarPath);
      } on Object {
        url = null;
      }
      if (_sent[persona.id] == persona.avatarPath) out.add((persona.id, url));
    }
    return out;
  }
}
