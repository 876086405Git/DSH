part of 'engine.dart';

class _HelperRequestRuntime {
  _HelperRequestRuntime(this.record)
    : provider = SPresetProvider(source: _modelChatCompletionSource(record.config), model: record.config.model);
  final _ScriptGenerationRecord record;
  final SPresetProvider provider;
  _ScriptCoordinator get owner => record.owner;
  TavernHelperGenerationOptions get options => _helperOptions(record.request)!;
  Map<String, Object?> custom = {};
  String source = 'openai';
  Uri? endpoint;
  List<String> images = const [];
  bool historyImageInlining = false;
  ChatPreset? namedPreset;
  int namedInjectionStart = 0;
  List<TavernScriptPromptPart>? namedOrder;
  final namedInjectionContent = <int, String>{};
  _HelperResponseCapture? response;
  Future<void>? outputPending;
  String? endedText;
  String outputRaw = '';
  String outputReasoning = '';
  int emittedTextLength = 0;
  int emittedReasoningLength = 0;
  late int lastProgressAt;
  late double progressInterval;
  TavernHelperGenerationMetadata metadata = TavernHelperGenerationMetadata();

  Future<T> _hostCall<T>(Future<T> Function(TavernScriptHost, TavernScriptCancellation) call) async {
    final host = owner._host;
    if (host == null) {
      throw _scriptError(TavernScriptErrorCode.hostUnavailable, 'helperGenerate', 'No Helper host is attached.');
    }
    final version = owner._hostVersion;
    final token = _ScriptCancellation();
    record.context.hostCallbacks.add(token);
    var settled = false;
    unawaited(
      record.cancellation.whenCancelled.then((_) {
        if (!settled) token.cancel();
      }),
    );
    try {
      final result = await owner._ownDelivery(
        () => Future.any<T>([
          Future<T>.sync(() => call(host, token)),
          token.whenCancelled.then<T>(
            (_) => throw _scriptError(
              token.reason == 'hostUnavailable'
                  ? TavernScriptErrorCode.hostUnavailable
                  : TavernScriptErrorCode.cancelled,
              'helperGenerate',
              'The Helper host operation ended before its result.',
            ),
          ),
        ]),
      );
      record.cancellation.check();
      if (record.context.closed || version != owner._hostVersion || !identical(host, owner._host)) {
        throw _scriptError(
          TavernScriptErrorCode.hostUnavailable,
          'helperGenerate',
          'The Helper host changed during preparation.',
        );
      }
      return result;
    } finally {
      settled = true;
      record.context.hostCallbacks.remove(token);
    }
  }

  Future<void> prepare() async {
    custom = options.customApi?.toJson() ?? {};
    _selectNamedPreset();
    final proxyName = custom['proxy_preset'];
    if (proxyName is String && proxyName.isNotEmpty) {
      final host = owner._host;
      if (host is! TavernHelperProxyHost) {
        throw _scriptError(
          TavernScriptErrorCode.unsupportedCapability,
          'helperGenerate',
          'proxy_preset requires the App proxy-settings capability.',
          fieldPath: 'custom_api.proxy_preset',
        );
      }
      final proxy = await _hostCall(
        (host, token) => (host as TavernHelperProxyHost).resolveHelperProxy(proxyName.trim(), token),
      );
      if (proxy == null) {
        record.hookIssues.add(
          TavernScriptIssue(
            code: 'helperProxyNotFound',
            message: 'The named proxy was not found; explicit custom_api or the current connection is used.',
            committed: false,
            generationId: record.id,
            stage: 'customApi',
          ),
        );
      } else {
        custom.addAll({'apiurl': proxy.url, 'key': proxy.key});
      }
    }
    final current = record.config;
    final rawUrl = custom['apiurl'];
    final url = rawUrl is String && rawUrl.isNotEmpty ? trimJsWhitespace(rawUrl).replaceAll(RegExp(r'/+$'), '') : null;
    final declared = custom['source'];
    source = declared is String && declared.isNotEmpty
        ? declared
        : url != null
        ? 'openai'
        : _modelChatCompletionSource(current);
    if (!const {'openai', 'deepseek', 'custom', 'openrouter'}.contains(source)) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedCapability,
        'helperGenerate',
        'This provider requires a protocol adapter that is not installed.',
        fieldPath: 'custom_api.source',
      );
    }
    if (url == null &&
        ((source == 'deepseek') != current.deepseek ||
            source == 'openrouter' && _modelChatCompletionSource(current) != 'openrouter')) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedCapability,
        'helperGenerate',
        'Changing the provider requires an explicit endpoint or an installed provider resolver.',
        fieldPath: 'custom_api.source',
      );
    }
    if (url != null) {
      final parsed = Uri.tryParse(url);
      if (parsed == null || !const {'http', 'https'}.contains(parsed.scheme) || parsed.host.isEmpty) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'helperGenerate',
          'Expected an HTTP API URL.',
          fieldPath: 'custom_api.apiurl',
        );
      }
      endpoint = Uri.parse('$url/chat/completions');
    }
    final headers = url == null ? Map<String, String>.of(current.headers) : <String, String>{};
    if (source == 'custom') {
      for (final entry in _map(custom['custom_include_headers']).entries) {
        headers[entry.key] = presetString(entry.value);
      }
    }
    final customAuthorization = source == 'custom' && headers.keys.any((key) => key.toLowerCase() == 'authorization');
    final model = custom['model'];
    record.config = TavernModelConfig(
      apiKey: customAuthorization
          ? () async => null
          : url != null
          ? () async => _string(custom['key'])
          : current.apiKey,
      baseUrl: url ?? current.baseUrl,
      model: model is String && model.isNotEmpty ? model : current.model,
      deepseek: source == 'deepseek',
      thinking: true,
      headers: Map.unmodifiable(headers),
      auxiliary: current.auxiliary,
    );
    if (options.ignoredLiteralImages.isNotEmpty) {
      record.hookIssues.add(
        TavernScriptIssue(
          code: 'helperRawLiteralImageNotConsumed',
          message: 'The fixed Helper raw literal path does not consume RolePrompt.image.',
          committed: false,
          generationId: record.id,
          stage: 'options',
          details: {'indices': options.ignoredLiteralImages},
        ),
      );
    }
    if (options.raw && namedPreset == null && options.presetName != 'in_use') {
      record.hookIssues.add(
        TavernScriptIssue(
          code: 'helperRawPresetNameNotConsumed',
          message: 'The fixed Helper raw path does not select preset_name.',
          committed: false,
          generationId: record.id,
          stage: 'options',
        ),
      );
    }
  }

  late final bool imageArray = options.toJson()['image'] is List<Object?>;
  bool get normalImageArray => record.request is! TavernScriptRawRequest && imageArray && options.images.isNotEmpty;

  Future<String> prepareImageInput(String input) async {
    if (normalImageArray) return '$input$_helperArrayImageMarker';
    // Raw nonempty arrays are converted before base-data/WI preparation.
    if (record.request is TavernScriptRawRequest && imageArray && options.images.isNotEmpty) {
      images = await _resolveImages(options.images);
    }
    return input;
  }

  Future<void> prepareNormalSingleImage() async {
    if (record.request is TavernScriptRawRequest || imageArray || options.images.isEmpty) return;
    // The source converts after WI, but ST 1.19 does not consume this legacy
    // normal userMessageTemp.image field. Do not turn it into a sent image.
    await _resolveImages(options.images);
  }

  Future<void> prepareRawUserImage() async {
    if (!imageArray) images = await _resolveImages(options.images);
  }

  Future<void> prepareRawHistoryImages(_ScriptGenerationCapture capture, {required bool hasInput}) async {
    if (!imageArray && !hasInput) images = await _resolveImages(options.images);
    final needsHistoryGate = options.historyImages.isNotEmpty || !imageArray && !hasInput && images.isNotEmpty;
    historyImageInlining = needsHistoryGate && await _historyImageInlining(capture);
    if (!imageArray && !hasInput && !historyImageInlining) images = const [];
  }

  Future<List<String>?> resolveHistoryImages(String identifier) async {
    if (!historyImageInlining) return null;
    for (final entry in options.historyImages.entries) {
      if (identifier == 'scriptHistory${entry.key}') return _resolveImages(entry.value);
    }
    return null;
  }

  Future<bool> _historyImageInlining(_ScriptGenerationCapture capture) async {
    // This engine's active model protocol is chat-completion. Like the source,
    // use the main environment before custom_api changes the request transport.
    if (!presetTruthy(capture.contextRegexPresetSettings['media_inlining'])) return false;
    if (provider.source == 'custom') return true;
    if (provider.source == 'openrouter') {
      if (owner._host is! TavernHelperImageCapabilityHost) {
        throw _scriptError(
          TavernScriptErrorCode.unsupportedCapability,
          'helperGenerate',
          'OpenRouter history images require actual model-catalog capabilities from the App.',
          fieldPath: 'image',
        );
      }
      return _hostCall(
        (host, token) => (host as TavernHelperImageCapabilityHost).supportsHelperModelImages(
          TavernHelperImageCapabilityRequest(
            generationId: record.id,
            contextId: record.context.value.id,
            chatId: record.context.value.chatId,
            source: provider.source,
            model: provider.model,
          ),
          token,
        ),
      );
    }
    if (provider.source != 'openai' && provider.source != 'deepseek') return false;
    final supported = _helperVisionModelPatterns.any(provider.model.contains);
    if (provider.source == 'deepseek') return supported;
    // Keep the fixed source's some(!includes) expression; it is not every().
    return supported &&
        const ['gpt-4-turbo-preview', 'o1-mini', 'o3-mini'].any((value) => !provider.model.contains(value));
  }

  void _selectNamedPreset() {
    if (options.raw || options.presetName == 'in_use') return;
    final matches = owner.engine._store.listPresets().where((preset) => preset.name == options.presetName).toList();
    if (matches.length != 1) {
      throw _scriptError(
        matches.isEmpty ? TavernScriptErrorCode.notFound : TavernScriptErrorCode.invalidArgument,
        'helperGenerate',
        matches.isEmpty ? 'The named preset does not exist.' : 'The preset name is ambiguous.',
        fieldPath: 'preset_name',
      );
    }
    final preset = namedPreset = ChatPreset(owner.engine._requirePreset(matches.single.id).raw);
    final raw = preset.raw;
    final prompts = _spRows(raw['prompts']);
    final order = _spRows(
      _spRows(raw['prompt_order']).where((row) => row['character_id'] == 100001).firstOrNull?['order'],
    );
    final ordered = <Object?>[];
    final depth = <Map<String, Object?>>[];
    const placeholders = {
      'worldInfoBefore': 'world_info_before',
      'personaDescription': 'persona_description',
      'charDescription': 'char_description',
      'charPersonality': 'char_personality',
      'scenario': 'scenario',
      'worldInfoAfter': 'world_info_after',
      'dialogueExamples': 'dialogue_examples',
      'chatHistory': 'chat_history',
    };
    for (final (index, entry) in order.indexed) {
      final prompt = prompts.where((row) => row['identifier'] == entry['identifier']).firstOrNull;
      if (prompt == null) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'helperGenerate',
          'The named preset order refers to a missing prompt.',
          fieldPath: 'preset_name.prompt_order[$index]',
        );
      }
      if (!presetTruthy(entry['enabled'] ?? prompt['enabled'] ?? true)) continue;
      final positionable = prompt['system_prompt'] == false || prompt['marker'] == true;
      final role = prompt['role'] ?? 'system';
      if (positionable && prompt['injection_position'] == 1) {
        depth.add({
          'role': role,
          'content': prompt['content'] ?? '',
          'depth': prompt['injection_depth'] ?? 4,
          'order': prompt['injection_order'] ?? 100,
          'index': index,
        });
      } else {
        ordered.add(placeholders[prompt['identifier']] ?? {'role': role, 'content': prompt['content'] ?? ''});
      }
    }
    depth.sort((a, b) {
      final depthOrder = presetNumber(a['depth'], 4).compareTo(presetNumber(b['depth'], 4));
      if (depthOrder != 0) return depthOrder;
      final order = presetNumber(a['order'], 100).compareTo(presetNumber(b['order'], 100));
      return order == 0 ? (a['index']! as int).compareTo(b['index']! as int) : order;
    });
    const fields = {
      'max_tokens': 'openai_max_tokens',
      'temperature': 'temperature',
      'frequency_penalty': 'frequency_penalty',
      'presence_penalty': 'presence_penalty',
      'top_p': 'top_p',
      'top_k': 'top_k',
    };
    const bounds = {
      'temperature': (0, 2),
      'frequency_penalty': (-2, 2),
      'presence_penalty': (-2, 2),
      'top_p': (0, 1),
      'top_k': (0, 100),
    };
    for (final entry in fields.entries) {
      final value = raw.containsKey(entry.value) ? presetJsNumber(raw[entry.value]) : double.nan;
      if (!value.isFinite) {
        throw _scriptError(
          TavernScriptErrorCode.invalidArgument,
          'helperGenerate',
          'The named preset sampler is not a finite JSON number.',
          fieldPath: 'preset_name.${entry.value}',
        );
      }
      final bound = bounds[entry.key];
      custom[entry.key] = bound == null ? value : value.clamp(bound.$1, bound.$2);
    }
    final json = options.toJson();
    final originalInjections = (json['injects'] as List<Object?>?) ?? const [];
    namedInjectionStart = originalInjections.length;
    record.request = TavernHelperRawRequest.fromJson({
      ...json,
      'ordered_prompts': ordered,
      'injects': [
        ...originalInjections,
        for (final entry in depth)
          {'role': entry['role'], 'content': entry['content'], 'position': 'in_chat', 'depth': entry['depth']},
      ],
    });
  }

  Future<List<String>> _resolveImages(List<String> sources) async {
    // Promise.all in both source array paths starts every conversion while
    // retaining the original order of the surviving images.
    final resolved = await Future.wait<String?>([
      for (final source in sources) _resolveImage(source),
    ], eagerError: true);
    return List.unmodifiable(resolved.whereType<String>());
  }

  Future<String?> _resolveImage(String source) async {
    var value = source;
    if (!source.startsWith('data:')) {
      final host = owner._host;
      if (host is! TavernHelperImageHost) {
        throw _scriptError(
          TavernScriptErrorCode.unsupportedCapability,
          'helperGenerate',
          'URL images require the App image resolver; File images must be bridged as data URIs.',
          fieldPath: 'image',
        );
      }
      final version = owner._hostVersion;
      try {
        value = await _hostCall((host, token) => (host as TavernHelperImageHost).resolveHelperImage(source, token));
        record.spreset?.check();
      } on TavernHelperImageConversionFailure catch (error) {
        record.cancellation.check();
        record.spreset?.check();
        if (record.context.closed || version != owner._hostVersion || !identical(host, owner._host)) {
          throw _scriptError(
            TavernScriptErrorCode.hostUnavailable,
            'helperGenerate',
            'The Helper host changed during image conversion.',
          );
        }
        record.hookIssues.add(
          TavernScriptIssue(
            code: 'helperImageConversionFailed',
            message: 'An image download or base64 conversion failed; the fixed Helper skips that image.',
            committed: false,
            generationId: record.id,
            contextId: record.context.value.id,
            stage: 'image',
            details: {'conversionStage': error.stage.name, 'message': error.message},
          ),
        );
        return null;
      }
    }
    try {
      final data = Uri.parse(value).data;
      if (data == null || !data.mimeType.startsWith('image/') || data.contentAsBytes().isEmpty) {
        throw const FormatException();
      }
    } on FormatException {
      throw _scriptError(
        TavernScriptErrorCode.invalidArgument,
        'helperGenerate',
        'The image resolver did not produce a valid image data URI.',
        fieldPath: 'image',
      );
    }
    return value;
  }

  Map<String, Object?> applyWire(Map<String, Object?> assembled) {
    final body = prepareModelRequestBody(record.config, assembled);
    const defaults = {'temperature': 1, 'frequency_penalty': 0, 'presence_penalty': 0, 'top_p': 1, 'top_k': 0};
    for (final key in TavernHelperCustomApi.samplingKeys) {
      final value = custom[key];
      if (value == null || value == 'same_as_preset') continue;
      if (value == 'unset' || defaults.containsKey(key) && value == defaults[key]) {
        body.remove(key);
      } else {
        body[key] = value;
      }
    }
    if (source == 'custom') {
      // The backend first merges include-body, then restores nonempty actual
      // stops/tools (including ToolManager offers). Empty inputs do not win.
      final stops = body['stop'];
      final offered = body['tools'];
      final offeredChoice = body['tool_choice'];
      final hasOfferedChoice = body.containsKey('tool_choice');
      body.addAll(_captureScriptObject(_map(custom['custom_include_body'])));
      if (stops is List<Object?> && stops.isNotEmpty) body['stop'] = stops;
      if (offered is List<Object?> && offered.isNotEmpty) {
        body['tools'] = offered;
        if (hasOfferedChoice) {
          body['tool_choice'] = offeredChoice;
        } else {
          body.remove('tool_choice');
        }
      }
    }
    final tools = options.tools;
    if (tools.isNotEmpty) {
      if (source == 'deepseek') {
        for (final tool in tools) {
          final parameters = _spMap(_spMap(tool['function'])['parameters']);
          if (parameters['required'] is List<Object?> && (parameters['required']! as List<Object?>).isEmpty) {
            parameters.remove('required');
          }
        }
      }
      body['tools'] = tools;
      body['tool_choice'] = options.toolChoice ?? 'auto';
    }
    final schema = options.jsonSchema;
    if (schema != null) {
      if (source == 'deepseek') {
        body['response_format'] = {'type': 'json_object'};
        final messages = (body['messages']! as List<Object?>).toList();
        messages.add({
          'role': 'user',
          'content': 'JSON schema for the response:\n${const JsonEncoder.withIndent('    ').convert(schema['value'])}',
        });
        body['messages'] = messages;
      } else {
        body['response_format'] = {
          'type': 'json_schema',
          'json_schema': {'name': schema['name'], 'schema': schema['value'], 'strict': schema['strict'] ?? true},
        };
      }
    }
    if (source == 'openrouter') {
      body['reasoning'] = {
        ..._map(body['reasoning']),
        'exclude': false,
        if (body.containsKey('reasoning_effort')) 'effort': body.remove('reasoning_effort'),
      };
    }
    if (source == 'deepseek') {
      body['thinking'] = {'type': 'enabled'};
      body.remove('top_k');
    }
    if (source == 'custom') {
      for (final key in (custom['custom_exclude_body'] as List<Object?>? ?? const [])) {
        body.remove(key);
      }
    }
    return body;
  }
}

extension _HelperImagePreparation on _ScriptPromptRun {
  Future<List<PromptSegment>> _helperNormalArrayReady(List<PromptSegment> segments) async {
    final helper = capture.helper;
    if (helper?.normalImageArray != true) return segments;
    for (var index = segments.length - 1; index >= 0; index--) {
      final segment = segments[index];
      final content = segment.message['content'];
      if (segment.message['role'] != 'user' || content is! String || !content.contains(_helperArrayImageMarker)) {
        continue;
      }
      final images = await helper!._resolveImages(helper.options.images);
      cancellation.check();
      final quality = _string(capture.contextRegexPresetSettings['inline_image_quality']);
      final message = {
        ...segment.message,
        'content': [
          {'type': 'text', 'text': content.replaceFirst(_helperArrayImageMarker, '')},
          for (final image in images)
            {
              'type': 'image_url',
              'image_url': {'url': image, 'detail': quality.isEmpty ? 'low' : quality},
            },
        ],
      };
      return List<PromptSegment>.of(segments)
        ..[index] = PromptSegment(
          id: segment.id,
          message: message,
          sources: segment.sources,
          collectionId: segment.collectionId,
          tokens: owner.engine._counter.countMessage(message),
        );
    }
    helper!.record.hookIssues.add(
      TavernScriptIssue(
        code: 'helperImageMarkerMissing',
        message:
            'The ready prompt contains no user string with the image marker; the fixed Helper continues without resolving the images.',
        committed: false,
        generationId: capture.generationId,
        contextId: capture.context.value.id,
        stage: 'image',
      ),
    );
    return segments;
  }

  String _helperImageText(String text, List<String>? images, {bool required = false, bool forceArray = false}) {
    if (images == null || images.isEmpty && !forceArray) return text;
    final marker = '\u2063helper-image-${_newStateId()}\u2063';
    helperImageSlots[marker] = images;
    if (required) {
      helperRequiredImageSlots.add(marker);
    }
    return '$text$marker';
  }

  PromptTokenCounter get _helperImageCounter => CallbackTokenCounter(
    name: owner.engine._counter.name,
    exact: owner.engine._counter.exact,
    text: owner.engine._counter.countText,
    // Normal arrays already contain the literal source marker at admission.
    // Only raw image slots need conversion to their counted message shape.
    message: (message) => owner.engine._counter.countMessage(_helperImageMessage(message)),
  );

  Map<String, Object?> _helperImageMessage(Map<String, Object?> message, {Set<String>? found}) {
    final content = message['content'];
    if (content is! String) return message;
    var text = content;
    final images = <String>[];
    var matched = false;
    for (final entry in helperImageSlots.entries) {
      if (!text.contains(entry.key)) continue;
      matched = true;
      text = text.replaceAll(entry.key, '');
      images.addAll(entry.value);
      found?.add(entry.key);
    }
    if (!matched) return message;
    final quality = _string(capture.contextRegexPresetSettings['inline_image_quality']);
    return {
      ...message,
      'content': [
        {'type': 'text', 'text': text},
        for (final image in images)
          {
            'type': 'image_url',
            'image_url': {'url': image, 'detail': quality.isEmpty ? 'low' : quality},
          },
      ],
    };
  }

  List<PromptSegment> _materializeHelperImageSegments(List<PromptSegment> segments) => [
    for (final segment in segments)
      (() {
        final message = _helperImageMessage(segment.message, found: helperMaterializedImageSlots);
        return PromptSegment(
          id: segment.id,
          message: message,
          sources: segment.sources,
          collectionId: segment.collectionId,
          tokens: owner.engine._counter.countMessage(message),
        );
      })(),
  ];

  void _restoreHelperImages(Map<String, Object?> body) {
    if (helperImageSlots.isEmpty) return;
    final found = {...helperMaterializedImageSlots};
    body['messages'] = [
      for (final raw in body['messages']! as List<Object?>)
        raw is Map<String, Object?> ? _helperImageMessage(raw, found: found) : raw,
    ];
    if (!found.containsAll(helperRequiredImageSlots)) {
      throw _scriptError(
        TavernScriptErrorCode.unsupportedOption,
        'helperGenerate',
        'The selected prompt layout did not retain the requested user image.',
        fieldPath: 'image',
      );
    }
  }
}

const _helperArrayImageMarker = '__IMG_ARRAY_MARKER_';

// Fixed ST 1.19 isImageInliningSupported model patterns; source pin is in
// docs/HELPER-GENERATION-SOURCES.json. These are capability matches, not routing.
const _helperVisionModelPatterns = [
  'chatgpt-4o-latest',
  'gpt-4-turbo',
  'gpt-4-vision',
  'gpt-4.1',
  'gpt-4.5-preview',
  'gpt-4o',
  'gpt-6-astra',
  'gpt-5',
  'o1',
  'o3',
  'o4-mini',
  'claude-3',
  'claude-fable',
  'claude-opus-4',
  'claude-opus-5',
  'claude-sonnet-4',
  'claude-sonnet-5',
  'claude-haiku-4',
  'c4ai-aya-vision',
  'command-a-vision',
  'gemini-2.0',
  'gemini-2.5',
  'gemini-3',
  'gemini-exp-1206',
  'learnlm',
  'gemini-robotics',
  'gemma-3-27b',
  'gemma-3-12b',
  'gemma-3-4b',
  'gemma-4',
  'mistral-small-2503',
  'mistral-small-2506',
  'mistral-small-latest',
  'mistral-medium-latest',
  'mistral-medium-2505',
  'mistral-medium-2508',
  'pixtral',
  'grok-4',
  'grok-2-vision',
  'moonshot-v1-8k-vision-preview',
  'moonshot-v1-32k-vision-preview',
  'moonshot-v1-128k-vision-preview',
  'kimi-k2.5',
  'kimi-latest',
  'deepseek-v4-flash-vision-exp',
  'glm-4.5v',
  'glm-4.6v',
  'glm-5v-turbo',
  'autoglm-phone',
  'Qwen/Qwen3-VL-32B-Instruct',
  'Qwen/Qwen3-VL-8B-Instruct',
  'Qwen/Qwen3-VL-235B-A22B-Instruct',
  'Qwen/Qwen3-VL-30B-A3B-Instruct',
  'zai-org/GLM-4.5V',
];
