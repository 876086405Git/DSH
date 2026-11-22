import 'package:dsh_tavern/dsh_tavern.dart';
import 'package:test/test.dart';

void main() {
  test('Helper wire captures options, images and history independently of native defaults', () {
    final wire = <String, Object?>{
      'generation_id': 'task-1',
      'user_input': 'Q',
      'should_stream': true,
      'should_silence': true,
      'should_return_reasoning': true,
      'max_chat_history': 0,
      'image': ['data:image/png;base64,AA==', 'https://example.invalid/p.png'],
      'overrides': {
        'char_description': 'D',
        'chat_history': {
          'with_depth_entries': false,
          'author_note': '',
          'prompts': [
            {'role': 'user', 'content': 'A', 'image': 'data:image/png;base64,AQ=='},
            {'role': 'assistant', 'content': 'B'},
          ],
        },
      },
      'custom_api': {
        'apiurl': 'https://example.invalid/v1',
        'temperature': 'unset',
        'top_p': 'same_as_preset',
        'top_k': 12,
        'custom_include_body': {'extra': true},
        'custom_exclude_body': ['nested.value'],
        'custom_include_headers': {'X-Test': 'one'},
      },
      'injects': [
        {'role': 'system', 'content': 'scan', 'position': 'none', 'depth': 0, 'should_scan': true},
      ],
      'ordered_prompts': [
        {'role': 'system', 'content': '{{incvar::literal}}'},
        'chat_history',
      ],
    };
    final request = TavernHelperRawRequest.fromJson(wire);
    wire.clear();
    expect(request.generationId, 'task-1');
    expect(request.stream && request.silent && request.includeReasoning, isTrue);
    expect(request.helperOptions.maxChatHistory, 0);
    expect(request.helperOptions.images, hasLength(2));
    expect(request.helperOptions.historyImages[0], ['data:image/png;base64,AQ==']);
    expect(request.overrides.fields['chatHistory'], hasLength(2));
    expect(request.overrides.fields['withDepthEntries'], isFalse);
    expect(request.helperOptions.nativeInjections.single.position, TavernScriptInjectionPosition.scanOnly);
    expect(request.helperOptions.nativeInjections.single.scan, isNull, reason: 'Raw does not read should_scan.');
    expect(request.injects, isEmpty);
    expect((request.orderedPrompts.first as TavernScriptPromptLiteral).content, '{{incvar::literal}}');
    final detached = request.toHelperJson();
    (detached['custom_api']! as Map<String, Object?>)['temperature'] = 99;
    expect(request.helperOptions.customApi!.toJson()['temperature'], 'unset');
    expect(() => request.helperOptions.images.clear(), throwsUnsupportedError);
    expect(() => request.helperOptions.historyImages[0]!.clear(), throwsUnsupportedError);
  });

  test('Helper raw default order differs from an explicit empty order and native raw', () {
    final defaults = TavernHelperRawRequest.fromJson({});
    expect(
      defaults.orderedPrompts.map((part) => (part as TavernScriptPromptPlaceholderPart).kind),
      TavernScriptPromptPlaceholder.values,
    );
    expect(TavernHelperRawRequest.fromJson({'ordered_prompts': <Object?>[]}).orderedPrompts, isEmpty);
    final native = TavernScriptRawRequest(orderedPrompts: const []);
    expect(native, isNot(isA<TavernHelperGenerationRequest>()));
    expect(native.presetId, isNull);
    expect(native.samplingOverrides, isEmpty);
    expect(TavernHelperRawRequest.fromJson({'generation_id': ''}).generationId, isNull);
  });

  test('Helper preserves the specified name and marks declared but unconsumed literal image', () {
    final normal = TavernHelperGenerateRequest.fromJson({'preset_name': 'named preset'});
    expect(normal.helperOptions.presetName, 'named preset');
    expect(normal.presetId, isNull);
    final raw = TavernHelperRawRequest.fromJson({
      'preset_name': 'raw does not select this',
      'max_chat_history': -1.9,
      'ordered_prompts': [
        {'role': 'user', 'content': 'literal', 'image': 'data:image/png;base64,AA=='},
      ],
    });
    expect(raw.helperOptions.raw, isTrue);
    expect(raw.helperOptions.maxChatHistory, -1);
    expect(raw.helperOptions.ignoredLiteralImages, [0]);
    expect(raw.helperOptions.images, isEmpty);
  });

  test('Helper boundary rejects unimplemented wire forms instead of accepting empty successes', () {
    for (final wire in <Map<String, Object?>>[
      {
        'image': {
          'name': 'file.png',
          'bytes': <int>[1],
        },
      },
      {
        'custom_api': {'temperature': 'invalid'},
      },
      {'tool_choice': 'all'},
      {
        'tools': [
          {
            'type': 'function',
            'function': {'parameters': <String, Object?>{}},
          },
        ],
      },
      {
        'overrides': {
          'chat_history': {
            'prompts': [
              {'role': 'tool', 'content': 'not a RolePrompt'},
            ],
          },
        },
      },
    ]) {
      expect(() => TavernHelperRawRequest.fromJson(wire), throwsA(isA<TavernScriptException>()));
    }
    expect(
      () => TavernHelperRawRequest.fromJson({
        'custom_api': {'temperature': double.infinity},
      }),
      throwsA(isA<TavernScriptException>().having((error) => error.code, 'code', TavernScriptErrorCode.invalidJson)),
    );
  });

  test('Helper detailed result is selected by return flag or actual tool calls and omits empty metadata', () {
    final empty = TavernHelperGenerationMetadata();
    expect(empty.toHelperValue(content: 'answer', reasoning: 'thought', shouldReturnReasoning: false), 'answer');
    expect(empty.toHelperValue(content: '', reasoning: '', shouldReturnReasoning: true), {'content': ''});
    final metadata = TavernHelperGenerationMetadata(
      reasoningSignature: 'signed',
      toolCalls: [
        TavernHelperToolCall(id: 'call-1', name: 'weather', arguments: '{"city":"X"}', thoughtSignature: 't'),
      ],
    );
    expect(metadata.toHelperValue(content: '', reasoning: 'thought', shouldReturnReasoning: false), {
      'content': '',
      'reasoning': 'thought',
      'reasoning_signature': 'signed',
      'tool_calls': [
        {
          'id': 'call-1',
          'type': 'function',
          'function': {'name': 'weather', 'arguments': '{"city":"X"}'},
          'thought_signature': 't',
        },
      ],
    });
  });
}
