import 'dart:convert';

import 'package:dsh_tavern/src/import_report.dart';
import 'package:dsh_tavern/src/io/import_intake.dart';
import 'package:dsh_tavern/src/preset_library.dart';
import 'package:dsh_tavern/src/regex_library.dart';
import 'package:test/test.dart';

void main() {
  test('worker inspection preserves findings counts and fingerprint', () async {
    final document = <String, Object?>{
      'data': {
        'name': 'Sample',
        'first_mes': '<div>{{user}}</div>',
        'extensions': {
          'regex_scripts': [_rule()],
        },
        'character_book': {
          'entries': [
            {
              'keys': ['sample'],
              'content': 'A short entry.',
            },
          ],
        },
      },
    };
    final checkedAt = DateTime.utc(2026, 11, 18);
    final expected = assessImport(
      kind: TavernImportKind.character,
      document: document,
      embeddedAssetPaths: ['portrait.png'],
      checkedAt: checkedAt,
    );
    final actual = await assessImportAsync(
      kind: TavernImportKind.character,
      document: document,
      embeddedAssetPaths: ['portrait.png'].map((value) => value),
      checkedAt: checkedAt,
    );
    expect(actual.toJson(), expected.toJson());
  });

  test('empty valid assets keep usable verdicts without invented features', () {
    for (final entry in <TavernImportKind, Map<String, Object?>>{
      TavernImportKind.character: {'data': <String, Object?>{}},
      TavernImportKind.preset: {'prompts': <Object?>[]},
      TavernImportKind.lorebook: {'entries': <String, Object?>{}},
      TavernImportKind.regex: _rule(),
    }.entries) {
      final report = _assess(entry.key, entry.value);
      expect(report.verdict, TavernImportVerdict.usable);
      expect(report.findings, isEmpty);
      expect(report.renderLevel, entry.key == TavernImportKind.character ? 0 : null);
    }
  });

  test('unknown metadata stays opaque and cannot create script or macro warnings', () {
    final report = _card({
      'vendor': '<script>void 0;</script>{{banned::x}}',
      'extensions': {
        'future_helper': {'script': 'TavernHelper getVariables {{banned::x}}'},
      },
    });
    expect(report.verdict, TavernImportVerdict.usable);
    expect(report.findings, isEmpty);
    expect(report.counts['scripts'], 0);
    expect(report.counts['macroOccurrences'], 0);
    expect(report.renderLevel, 0);
  });

  test('component counts distinguish declarations stored rows and embedded files', () {
    final report = _assess(
      TavernImportKind.character,
      {
        'data': {
          'assets': [
            {'name': 'a'},
            {'name': 'b'},
            {'name': 'c'},
          ],
          'extensions': {
            'regex_scripts': [_rule(), _rule()],
          },
          'character_book': {
            'entries': [
              {
                'id': 1,
                'keys': ['one', 'two'],
                'secondary_keys': ['s'],
                'enabled': true,
                'content': '',
              },
              {'id': 2, 'keys': <String>[], 'enabled': false, 'content': ''},
            ],
          },
        },
      },
      embeddedAssetPaths: ['a.png', 'a.png', 'b.png'],
    );
    expect(report.counts['assets'], 3);
    expect(report.counts['embeddedFiles'], 2);
    expect(report.counts['regexScripts'], 2);
    expect(report.counts['worldInfoBooks'], 1);
    expect(report.counts['entriesStored'], 2);
    expect(report.counts['entriesInExecutionView'], 2);
    expect(report.counts['entriesEnabled'], 1);
    expect(report.counts['entriesDisabled'], 1);
    expect(report.counts['primaryKeys'], 2);
    expect(report.counts['secondaryKeys'], 1);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('asset names and supplied paths are counted without pretending their bytes were inspected', () {
    final report = _assess(
      TavernImportKind.character,
      {
        'data': {
          'assets': [
            {'name': 'helper.js', 'uri': 'ccdefault:'},
            {'name': 'page.html', 'uri': 'embeded://page.html'},
          ],
        },
      },
      embeddedAssetPaths: ['helper.js', 'page.html'],
    );
    expect(report.counts['assets'], 2);
    expect(report.counts['embeddedFiles'], 2);
    expect(report.counts['scripts'], 0);
    expect(report.findings, isEmpty);
    expect(report.renderLevel, 0);
  });

  test('malformed regex declarations receive per source invalid findings without duplicate receipts', () {
    final document = <String, Object?>{
      'data': {
        'extensions': {
          'regex_scripts': [false, _rule()],
        },
      },
    };
    final report = _assess(
      TavernImportKind.character,
      document,
      regexDiagnostics: const [
        TavernRegexDiagnostic(
          path: r'$.data.extensions.regex_scripts[0]',
          status: TavernRegexCompatibility.incompatible,
          code: 'invalid-rule',
          message: 'not an object',
        ),
      ],
    );
    expect(report.counts['regexScripts'], 2);
    expect(report.counts['regexChecks'], 1);
    expect(report.findings, hasLength(1));
    expect(report.findings.single.path, r'$.data.extensions.regex_scripts[0]');
    expect(report.findings.single.kind, TavernImportFindingKind.invalid);
    expect(report.verdict, TavernImportVerdict.partial);
    final invalidList = _card({
      'extensions': {
        'regex_scripts': {'unexpected': true},
      },
    });
    expect(invalidList.findings.single.path, r'$.data.extensions.regex_scripts');
    expect(invalidList.findings.single.code, 'invalid-rule-list');
    expect(invalidList.counts['regexScripts'], 0);
  });

  test('inspection preserves nested source values and produces immutable summaries', () {
    final raw = <String, Object?>{
      'prompts': [
        {'identifier': 'p', 'content': '{{banned::word}}'},
      ],
      'unknown': <Object?>[
        false,
        null,
        {'bytes': '\uFEFF\r\n海'},
      ],
    };
    final envelope = <String, Object?>{
      'prefill': {'enabled': false, 'toolCalls': true},
    };
    final before = jsonEncode([raw, envelope]);
    final report = _assess(TavernImportKind.preset, raw, envelope: envelope);
    expect(jsonEncode([raw, envelope]), before);
    expect(report.fingerprint, importFingerprint(TavernImportKind.preset, raw, envelope: envelope));
    expect(() => report.counts['scripts'] = 100, throwsUnsupportedError);
    expect(() => report.findings.clear(), throwsUnsupportedError);
  });

  test('each banned occurrence has an original UTF16 offset and CRLF aware line', () {
    const value = '🙂海{{banned::one}}\r\n{{ BANNED : two }}\r{{banned}}';
    final report = _card({'first_mes': value});
    final issues = _code(report, 'macro-banned-no-effect');
    expect(issues, hasLength(3));
    expect(issues.map((value) => value.path), List.filled(3, r'$.data.first_mes'));
    expect(issues.map((value) => value.offset), [value.indexOf('{{'), value.indexOf('{{ B'), value.lastIndexOf('{{')]);
    expect(issues.map((value) => value.line), [1, 2, 3]);
    expect(issues.every((value) => value.kind == TavernImportFindingKind.unsupported), isTrue);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('macro names respect syntax boundaries flags and closing calls', () {
    final report = _card({
      'first_mes':
          '{{! banned::one}}{{banned "two"}}{{banned:three}}'
          '{{bannedly::x}}{{banned-brother::x}}{{banned!bad}}{{/banned}}{{#banned::four}}',
    });
    expect(_code(report, 'macro-banned-no-effect'), hasLength(4));
    expect(report.counts['macroOccurrences'], 6);
  });

  test('nested banned evidence remains conditional inside comments or branches', () {
    final report = _card({'first_mes': '{{// {{banned::one}} }} {{if::false::{{banned::two}}}}'});
    final issues = _code(report, 'macro-banned-no-effect');
    expect(issues, hasLength(2));
    expect(issues.every((value) => value.conditional && value.kind == TavernImportFindingKind.conditional), isTrue);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('unclosed expressions and ordinary text do not become macro findings', () {
    final report = _card({'description': 'banned words; {banned}; {{banned::unclosed'});
    expect(report.findings, isEmpty);
    expect(report.counts['macroOccurrences'], 0);
  });

  test('supported empty result macros and extension queries are not gaps', () {
    final report = _card({
      'description':
          '{{noop}}{{comment}}{{setvar::a::1}}{{deletevar::a}}'
          '{{outlet::missing}}{{original}}{{hasExtension::TavernHelper}}{{vendorUnknown::a}}',
    });
    expect(report.findings, isEmpty);
    expect(report.counts['macroOccurrences'], 8);
    expect(report.renderLevel, 0);
  });

  test('card text arrays and multilingual notes retain individual paths', () {
    final report = _card({
      'alternate_greetings': ['{{banned}}', '{{banned}}'],
      'group_only_greetings': ['{{banned}}'],
      'creator_notes_multilingual': {'zh.CN': '{{banned}}'},
    });
    expect(_code(report, 'macro-banned-no-effect').map((value) => value.path), [
      r'$.data.alternate_greetings[0]',
      r'$.data.alternate_greetings[1]',
      r'$.data.group_only_greetings[0]',
      r'$.data.creator_notes_multilingual["zh.CN"]',
    ]);
  });

  test('regex patterns and trim strings are not display HTML', () {
    final report = _assess(
      TavernImportKind.regex,
      _rule({
        'findRegex': '<script>void 0;</script>',
        'replaceString': '<div>prompt</div>',
        'trimStrings': ['<script>void 0;</script>'],
        'promptOnly': true,
      }),
    );
    expect(report.renderLevel, isNull);
    expect(report.counts['htmlFragments'], 0);
    expect(report.counts['scripts'], 0);
  });

  test('legacy regex placement uses the same migrated display view as execution', () {
    final report = _assess(
      TavernImportKind.regex,
      _rule({
        'placement': [0],
        'replaceString': '<b>hi</b>',
      }),
    );
    expect(report.renderLevel, 1);
    expect(report.counts['htmlFragments'], 1);
    expect(report.findings, isEmpty);
  });

  test('dynamic regex macro scanning uses the existing numeric coercion', () {
    final raw = _rule({'findRegex': '{{banned::word}}', 'substituteRegex': ' 1 '});
    final report = _assess(TavernImportKind.regex, raw);
    expect(_code(report, 'macro-banned-no-effect').single.path, r'$.findRegex');
    final literal = _assess(TavernImportKind.regex, {...raw, 'substituteRegex': 0});
    expect(literal.counts['macroOccurrences'], 0);
  });

  test('prompt aliases and plain helper names are not HTML evidence', () {
    final report = _card({
      'first_mes':
          '<USER> <BOT> <CHAR> <GROUP> <CHARIFNOTGROUP> <START> '
          'TavernHelper getChatMessages JS-Slash-Runner',
    });
    expect(report.renderLevel, 0);
    expect(report.findings, isEmpty);
  });

  test('ordinary HTML layout and helper names in data attributes recommend level one', () {
    final report = _card({
      'first_mes':
          '<div data-note="TavernHelper"><b>hello</b></div>'
          '<iframe src="about:blank"></iframe><style>.own { color: red; }</style>',
    });
    expect(report.renderLevel, 1);
    expect(report.counts['htmlFragments'], 1);
    expect(report.counts['scripts'], 0);
    expect(report.findings, isEmpty);
  });

  test('Markdown code HTML comments escapes and encoded tags are not active markup', () {
    for (final content in [
      '```html\r\n<script>void 0;</script>\r\n```',
      '  ~~~~html\n<script>void 0;</script>\n  ~~~~',
      '`<script>void 0;</script>`',
      '<!-- <script>void 0;</script> -->',
      r'\<script>void 0;\</script>',
      '&lt;script&gt;void 0;&lt;/script&gt;',
    ]) {
      final report = _card({'first_mes': content});
      expect(report.renderLevel, 0, reason: content);
      expect(report.findings, isEmpty, reason: content);
    }
  });

  test('Markdown fences do not suppress the independent macro scanner', () {
    final report = _card({'first_mes': '```text\n{{banned::word}}\n```'});
    expect(_code(report, 'macro-banned-no-effect'), hasLength(1));
    expect(report.renderLevel, 0);
  });

  test('obvious indented Markdown examples are not positive markup evidence', () {
    for (final content in ['    <script>void 0;</script>', '\t<script>void 0;</script>']) {
      final report = _card({'first_mes': content});
      expect(report.findings, isEmpty);
      expect(report.renderLevel, 0);
    }
  });

  test('each inline external and module script has its own source finding', () {
    const content =
        '<script>void 0;</script>\n<SCRIPT src="asset.js"></SCRIPT>\n'
        '<script type="module">void 0;</script>';
    final report = _card({'first_mes': content});
    final issues = _code(report, 'embedded-script-not-executed');
    expect(issues, hasLength(3));
    expect(issues.map((value) => value.line), [1, 2, 3]);
    expect(issues.map((value) => value.offset), [0, content.indexOf('<SCRIPT'), content.lastIndexOf('<script')]);
    expect(report.counts['scripts'], 3);
    expect(report.renderLevel, 2);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('data script elements and empty script declarations do not claim executable code', () {
    final report = _card({
      'first_mes':
          '<script type="application/json">{"name":"TavernHelper"}</script>'
          '<script type="application/ld+json">{}</script><script></script><script src=""></script>',
    });
    expect(report.renderLevel, 1);
    expect(report.counts['scripts'], 0);
    expect(report.findings, isEmpty);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('explicit event handlers and javascript URLs are located individually', () {
    const content =
        '<button onclick="void 0;" onfocus="void 0;" data-onload="none">go</button>'
        '<a href="javascript:void 0">go</a><div once="void 0;"></div>';
    final report = _card({'first_mes': content});
    expect(_code(report, 'event-script-not-executed'), hasLength(2));
    expect(_code(report, 'javascript-url-not-executed'), hasLength(1));
    expect(report.counts['scripts'], 3);
    expect(report.renderLevel, 2);
    expect(report.findings.map((value) => value.offset), [
      content.indexOf('onclick'),
      content.indexOf('onfocus'),
      content.indexOf('href'),
    ]);
  });

  test('first duplicate HTML attribute wins and attribute text cannot inject a tag', () {
    final report = _card({
      'first_mes':
          '<div onclick="" onclick="void 0;" '
          'data-note="<script>void 0;</script>">hello</div>',
    });
    expect(report.renderLevel, 1);
    expect(report.counts['scripts'], 0);
    expect(report.findings, isEmpty);
  });

  test('Unicode before tags does not change UTF16 offsets through case conversion', () {
    const content = 'İ🙂\r\n<SCRIPT>void 0;</SCRIPT>';
    final finding = _code(_card({'first_mes': content}), 'embedded-script-not-executed').single;
    expect(finding.offset, content.indexOf('<SCRIPT'));
    expect(finding.line, 2);
  });

  test('cross message selectors include descendants siblings and media nested rules', () {
    final report = _card({
      'first_mes':
          '<style>#chat .mes { color:red; } '
          '.mes + .mes { margin:0; } @media screen { #chat > .mes { color:blue; } }</style>',
    });
    final issues = _code(report, 'cross-message-style');
    expect(issues, hasLength(3));
    expect(issues.every((value) => value.conditional && value.kind == TavernImportFindingKind.conditional), isTrue);
    expect(report.renderLevel, 2);
    expect(report.counts['scripts'], 0);
  });

  test('CSS comments strings attribute values and unrelated names do not create cross message evidence', () {
    for (final selector in [
      '#chatty .mes',
      '#chat .mes_text',
      '#chat.mes',
      '#chat, .mes',
      '[data-note="#chat .mes"]',
      ':not(#chat .mes)',
      r'#chat\ty .mes',
    ]) {
      final report = _card({
        'first_mes':
            '<style>/* #chat .mes {} */ $selector '
            '{ content: "#chat .mes { }"; }</style>',
      });
      expect(report.renderLevel, 1, reason: selector);
      expect(_code(report, 'cross-message-style'), isEmpty, reason: selector);
    }
  });

  test('CSS source positions survive masked comments and quoted declaration values', () {
    const content = '🙂<style>/* 海 */\r\n.x { content: "#chat .mes {}"; }\n#chat .mes {color:red}</style>';
    final finding = _code(_card({'first_mes': content}), 'cross-message-style').single;
    expect(finding.offset, content.lastIndexOf('#chat .mes'));
    expect(finding.line, 3);
  });

  test('CSS comments cannot invent a descendant combinator between compound tokens', () {
    final compound = _card({'first_mes': '<style>#chat/*comment*/.mes {color:red}</style>'});
    expect(_code(compound, 'cross-message-style'), isEmpty);
    expect(compound.renderLevel, 1);
    final descendant = _card({'first_mes': '<style>#chat/*comment*/ .mes {color:red}</style>'});
    expect(_code(descendant, 'cross-message-style'), hasLength(1));
    expect(descendant.renderLevel, 2);
  });

  test('raw style text is not recursively mistaken for HTML script elements', () {
    final report = _card({'first_mes': '<style>.x::after {content:"<script>void 0;</script>";}</style>'});
    expect(report.renderLevel, 1);
    expect(report.counts['scripts'], 0);
    expect(report.findings, isEmpty);
  });

  test('raw text and RCDATA containers do not create script elements from their literal bodies', () {
    for (final tag in ['textarea', 'title', 'iframe', 'xmp']) {
      final report = _card({'first_mes': '<$tag><script>void 0;</script></$tag>'});
      expect(report.renderLevel, 1, reason: tag);
      expect(report.counts['scripts'], 0, reason: tag);
      expect(report.findings, isEmpty, reason: tag);
    }
  });

  test('helper folder leaves keep exact locations and empty leaves are not scripts', () {
    final report = _card({
      'extensions': {
        'tavern_helper': {
          'scripts': [
            {
              'type': 'folder',
              'scripts': [
                {'id': 'same', 'type': 'script', 'content': 'void 0;'},
                {'id': 'same', 'type': 'script', 'src': 'asset.js'},
                {'type': 'script', 'content': '   '},
                {'type': 'folder', 'scripts': <Object?>[]},
              ],
            },
          ],
        },
      },
    });
    final issues = _code(report, 'helper-script-not-executed');
    expect(issues.map((value) => value.path), [
      r'$.data.extensions.tavern_helper.scripts[0].scripts[0]',
      r'$.data.extensions.tavern_helper.scripts[0].scripts[1]',
    ]);
    expect(issues.map((value) => value.identifier), ['same', 'same']);
    expect(report.counts['helperScripts'], 2);
    expect(report.counts['scripts'], 2);
    expect(report.renderLevel, 2);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('disabled helper folders make preserved script limitations conditional', () {
    final report = _card({
      'extensions': {
        'tavern_helper': {
          'scripts': [
            {
              'type': 'folder',
              'enabled': false,
              'children': [
                {'id': 'child', 'content': 'void 0;'},
              ],
            },
          ],
        },
      },
    });
    final finding = _code(report, 'helper-script-not-executed').single;
    expect(finding.path, r'$.data.extensions.tavern_helper.scripts[0].children[0]');
    expect(finding.conditional, isTrue);
    expect(finding.kind, TavernImportFindingKind.conditional);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('empty helper schemas and extension mentions do not prove a dependency', () {
    final report = _card({
      'description': 'This mentions TavernHelper and JS-Slash-Runner.',
      'extensions': {
        'tavern_helper': {'scripts': <Object?>[], 'variables': <String, Object?>{}},
        'TavernHelper_scripts': <Object?>[],
      },
    });
    expect(report.findings, isEmpty);
    expect(report.counts['helperScripts'], 0);
    expect(report.renderLevel, 0);
  });

  test('helper variable declarations and legacy scripts are separate known features', () {
    final report = _card({
      'extensions': {
        'tavern_helper': {
          'variables': {'one': 1, 'two': false},
        },
        'TavernHelper_scripts': [
          {'id': 'old', 'content': 'void 0;'},
        ],
      },
    });
    expect(_code(report, 'helper-variables-not-applied').single.path, r'$.data.extensions.tavern_helper.variables');
    expect(_code(report, 'helper-script-not-executed').single.path, r'$.data.extensions.TavernHelper_scripts[0]');
    expect(report.counts['helperVariables'], 2);
    expect(report.counts['helperScripts'], 1);
    expect(report.renderLevel, 2);
  });

  test('helper source bodies remain opaque rather than being expanded as prompt macros', () {
    final report = _card({
      'extensions': {
        'tavern_helper': {
          'scripts': [
            {'content': 'const text = "{{banned::x}}";'},
          ],
        },
      },
    });
    expect(_code(report, 'helper-script-not-executed'), hasLength(1));
    expect(_code(report, 'macro-banned-no-effect'), isEmpty);
    expect(report.counts['macroOccurrences'], 0);
  });

  test('prefill features tools and individual attachments never collapse to an aggregate warning', () {
    final report = _assess(
      TavernImportKind.preset,
      {
        'prompts': [
          {
            'identifier': 'p',
            'content': '',
            'contextFiles': [
              null,
              {'url': 'one'},
              '',
              {'url': 'two'},
            ],
          },
        ],
      },
      envelope: {
        'prefill': {
          'enabled': true,
          'toolCalls': true,
          'extractOutput': true,
          'postToolPrefix': {'mode': 'custom', 'text': 'prefix'},
        },
        'tools': [
          {'name': 'tool'},
        ],
      },
      presetIssues: const [
        TavernPresetIssue(path: r'$.prefill', code: 'prefill-features-preserved', message: 'aggregate'),
        TavernPresetIssue(path: r'$.tools', code: 'tools-preserved', message: 'aggregate'),
        TavernPresetIssue(path: r'$.preset.data.prompts[0]', code: 'attachments-preserved', message: 'aggregate'),
      ],
    );
    expect(report.findings.map((value) => value.path), [
      r'$.prompts[0].contextFiles[1]',
      r'$.prompts[0].contextFiles[3]',
      r'$.envelope.prefill.toolCalls',
      r'$.envelope.prefill.extractOutput',
      r'$.envelope.prefill.postToolPrefix.mode',
      r'$.envelope.tools',
    ]);
    expect(report.findings, hasLength(6));
    expect(report.counts['prompts'], 1);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('disabled prefill requested features are conditional without changing the document', () {
    final report = _assess(
      TavernImportKind.preset,
      {},
      envelope: {
        'prefill': {
          'enabled': false,
          'toolCalls': true,
          'extractOutput': true,
          'postToolPrefix': {'mode': 'custom', 'text': ''},
        },
      },
    );
    expect(report.findings, hasLength(3));
    expect(
      report.findings.every((value) => value.conditional && value.kind == TavernImportFindingKind.conditional),
      isTrue,
    );
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('false prefill switches inherit prefix and empty attachment collections are inert', () {
    final report = _assess(
      TavernImportKind.preset,
      {
        'prompts': [
          {'identifier': 'p', 'content': '', 'contextFiles': <Object?>[], 'contextFile': ''},
        ],
      },
      envelope: {
        'prefill': {
          'enabled': true,
          'toolCalls': false,
          'extractOutput': false,
          'postToolPrefix': {'mode': 'inherit', 'text': ''},
        },
        'tools': <Object?>[],
      },
    );
    expect(report.findings, isEmpty);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('codec issues preserve original wrapper paths and skip normalization receipts', () {
    final report = _assess(
      TavernImportKind.preset,
      {},
      presetIssues: const [
        TavernPresetIssue(
          path: r'$.preset.data.prompts[0].role',
          code: 'invalid-role',
          message: 'invalid role',
          identifier: 'p',
          severity: TavernPresetIssueSeverity.error,
        ),
        TavernPresetIssue(
          path: r'$.preset.data.prompt_order[0].order[1].identifier',
          code: 'missing-prompt',
          message: 'missing',
          identifier: 'missing',
        ),
        TavernPresetIssue(
          path: r'$.preset.data.temperature',
          code: 'coerced',
          message: 'normalized',
          severity: TavernPresetIssueSeverity.normalized,
        ),
        TavernPresetIssue(path: r'$.preset.data.future', code: 'retained-note', message: 'contextual'),
      ],
    );
    expect(report.findings.map((value) => value.kind), [
      TavernImportFindingKind.invalid,
      TavernImportFindingKind.unsupported,
      TavernImportFindingKind.conditional,
    ]);
    expect(report.findings.first.path, r'$.preset.data.prompts[0].role');
    expect(report.findings.first.identifier, 'p');
    expect(report.findings.any((value) => value.code == 'coerced'), isFalse);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('regex status counters preserve receipts without compiling any patterns again', () {
    final report = _assess(
      TavernImportKind.character,
      {'data': <String, Object?>{}},
      regexDiagnostics: [
        _diagnostic(TavernRegexCompatibility.compatible, path: r'$.a', code: 'compiled'),
        _diagnostic(TavernRegexCompatibility.literalFallback, path: r'$.b', code: 'literal-fallback'),
        _diagnostic(TavernRegexCompatibility.incompatible, path: r'$.c', code: 'compile-error'),
        _diagnostic(TavernRegexCompatibility.deferred, path: r'$.d', code: 'runtime-check'),
        _diagnostic(TavernRegexCompatibility.skipped, path: r'$.e', code: 'timeout'),
      ],
    );
    expect(report.counts['regexChecks'], 5);
    for (final key in [
      'regexCompatible',
      'regexLiteralFallback',
      'regexIncompatible',
      'regexDeferred',
      'regexUnchecked',
    ]) {
      expect(report.counts[key], 1);
    }
    expect(report.findings.map((value) => value.code), [
      'literal-fallback',
      'compile-error',
      'runtime-check',
      'timeout',
    ]);
    expect(report.findings.map((value) => value.kind), [
      TavernImportFindingKind.conditional,
      TavernImportFindingKind.invalid,
      TavernImportFindingKind.deferred,
      TavernImportFindingKind.unknown,
    ]);
    expect(report.verdict, TavernImportVerdict.partial);
  });

  test('an incompatible standalone rule is preserve only with no disabled mutation', () {
    final raw = _rule({'findRegex': '[', 'disabled': false});
    final report = _assess(
      TavernImportKind.regex,
      raw,
      regexDiagnostics: [_diagnostic(TavernRegexCompatibility.incompatible, code: 'compile-error')],
    );
    expect(report.verdict, TavernImportVerdict.preserveOnly);
    expect(raw['disabled'], isFalse);
    expect(report.counts['regexScripts'], 1);
    expect(report.findings.single.path, r'$.findRegex');
  });

  test('disabled and empty valid rules are not themselves unsupported features', () {
    for (final raw in [
      _rule({'disabled': true}),
      _rule({'findRegex': '', 'replaceString': ''}),
    ]) {
      final report = _assess(
        TavernImportKind.regex,
        raw,
        regexDiagnostics: [_diagnostic(TavernRegexCompatibility.compatible)],
      );
      expect(report.findings, isEmpty);
      expect(report.verdict, TavernImportVerdict.usable);
    }
    final disabledInvalid = _assess(
      TavernImportKind.regex,
      _rule({'disabled': true}),
      regexDiagnostics: [_diagnostic(TavernRegexCompatibility.incompatible)],
    );
    expect(disabledInvalid.verdict, TavernImportVerdict.partial);
  });

  test('deferred checks and conditional evidence never prove a standalone core is unusable', () {
    final deferred = _assess(
      TavernImportKind.regex,
      _rule({'substituteRegex': 1}),
      regexDiagnostics: [_diagnostic(TavernRegexCompatibility.deferred, code: 'runtime-check')],
    );
    expect(deferred.verdict, TavernImportVerdict.usable);
    expect(deferred.findings.single.kind, TavernImportFindingKind.deferred);
    final conditional = _assess(
      TavernImportKind.regex,
      _rule(),
      regexDiagnostics: const [
        TavernRegexDiagnostic(
          path: r'$.findRegex',
          status: TavernRegexCompatibility.incompatible,
          code: 'conditional',
          message: 'conditional receipt',
          conditional: true,
        ),
      ],
    );
    expect(conditional.verdict, TavernImportVerdict.usable);
  });

  test('skipped checks keep their actual reason and do not become incompatibility proofs', () {
    final report = _assess(
      TavernImportKind.regex,
      _rule(),
      regexDiagnostics: [_diagnostic(TavernRegexCompatibility.skipped, code: 'worker-unavailable')],
    );
    expect(report.verdict, TavernImportVerdict.partial);
    expect(report.findings.single.code, 'worker-unavailable');
    expect(report.findings.single.kind, TavernImportFindingKind.unknown);
  });

  test('an imported array member keeps one rule count and the original path prefix', () {
    final report = _assess(
      TavernImportKind.regex,
      _rule({'replaceString': '{{banned::x}}'}),
      path: r'$[3]',
      regexDiagnostics: [
        _diagnostic(TavernRegexCompatibility.incompatible, path: r'$[3].findRegex', code: 'compile-error'),
      ],
    );
    expect(report.counts['regexScripts'], 1);
    expect(report.findings.map((value) => value.path), [r'$[3].replaceString', r'$[3].findRegex']);
    expect(report.verdict, TavernImportVerdict.preserveOnly);
  });

  test('multiple decorator keyword receipts on one line cannot be deduplicated away', () {
    final report = _assess(
      TavernImportKind.lorebook,
      {'entries': <String, Object?>{}},
      regexDiagnostics: const [
        TavernRegexDiagnostic(
          path: r'$.entries["one"].content',
          status: TavernRegexCompatibility.incompatible,
          code: 'compile-error',
          message: 'invalid',
          identifier: '1',
          line: 2,
          decorator: 'additional_keys',
          keyIndex: 0,
          conditional: true,
          fallback: true,
        ),
        TavernRegexDiagnostic(
          path: r'$.entries["one"].content',
          status: TavernRegexCompatibility.incompatible,
          code: 'compile-error',
          message: 'invalid',
          identifier: '1',
          line: 2,
          decorator: 'additional_keys',
          keyIndex: 1,
          conditional: true,
          fallback: true,
        ),
      ],
    );
    expect(report.findings, hasLength(2));
    expect(report.findings.map((value) => value.message).toSet(), hasLength(2));
    expect(
      report.findings.every(
        (value) =>
            value.line == 2 && value.offset == null && value.identifier == '1' && value.conditional && value.fallback,
      ),
      isTrue,
    );
    expect(report.counts['regexIncompatible'], 2);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('native embedded books keep V3 keyword fields opaque instead of scanning their macros', () {
    final raw = <String, Object?>{
      'entries': {
        'native-row': {
          'uid': 'native',
          'key': ['ordinary'],
          'keysecondary': <String>[],
          'content': 'body',
          'keys': ['{{banned::one}}'],
          'secondary_keys': ['{{banned::two}}'],
          'enabled': true,
        },
      },
    };
    final before = jsonEncode(raw);
    final report = _card({'character_book': raw});
    expect(_code(report, 'macro-banned-no-effect'), isEmpty);
    expect(report.counts['macroOccurrences'], 0);
    expect(report.counts['primaryKeys'], 1);
    expect(report.counts['secondaryKeys'], 0);
    expect(report.findings.every((value) => value.kind == TavernImportFindingKind.unknown), isTrue);
    expect(report.verdict, TavernImportVerdict.usable);
    expect(jsonEncode(raw), before);
  });

  test('standalone V3 books keep native keyword fields opaque instead of scanning their macros', () {
    final raw = <String, Object?>{
      'entries': [
        {
          'id': 'v3',
          'keys': ['ordinary'],
          'secondary_keys': <String>[],
          'enabled': true,
          'content': 'body',
          'key': ['{{banned::one}}'],
          'keysecondary': ['{{banned::two}}'],
        },
      ],
    };
    final before = jsonEncode(raw);
    final report = _assess(TavernImportKind.lorebook, raw);
    expect(_code(report, 'macro-banned-no-effect'), isEmpty);
    expect(report.counts['macroOccurrences'], 0);
    expect(report.counts['primaryKeys'], 1);
    expect(report.counts['secondaryKeys'], 0);
    expect(report.findings.every((value) => value.kind == TavernImportFindingKind.unknown), isTrue);
    expect(report.verdict, TavernImportVerdict.usable);
    expect(jsonEncode(raw), before);
  });

  test('native unknown enabled false cannot suppress the active content limitation', () {
    final raw = <String, Object?>{
      'entries': {
        'entry': {
          'uid': 'native',
          'id': 'unknown-id',
          'key': <String>[],
          'content': '{{banned::x}}',
          'disable': false,
          'enabled': false,
        },
      },
    };
    final before = jsonEncode(raw);
    final report = _assess(TavernImportKind.lorebook, raw);
    final finding = _code(report, 'macro-banned-no-effect').single;
    expect(finding.path, r'$.entries["entry"].content');
    expect(finding.identifier, 'native');
    expect(finding.conditional, isFalse);
    expect(finding.kind, TavernImportFindingKind.unsupported);
    expect(report.counts['entriesEnabled'], 1);
    expect(report.verdict, TavernImportVerdict.partial);
    expect(jsonEncode(raw), before);
  });

  test('V3 unknown disable true cannot suppress the active content limitation', () {
    final raw = <String, Object?>{
      'entries': [
        {
          'id': 'v3',
          'uid': 'unknown-uid',
          'keys': <String>[],
          'content': '{{banned::x}}',
          'enabled': true,
          'disable': true,
        },
      ],
    };
    final before = jsonEncode(raw);
    final report = _assess(TavernImportKind.lorebook, raw);
    final finding = _code(report, 'macro-banned-no-effect').single;
    expect(finding.path, r'$.entries[0].content');
    expect(finding.identifier, 'v3');
    expect(finding.conditional, isFalse);
    expect(finding.kind, TavernImportFindingKind.unsupported);
    expect(report.counts['entriesEnabled'], 1);
    expect(report.verdict, TavernImportVerdict.partial);
    expect(jsonEncode(raw), before);
  });

  test('native disabled semantics accept only literal true and preserve nonboolean values', () {
    for (final value in <Object?>[true, false, null, 0, 1, 'true', 'false']) {
      final raw = <String, Object?>{
        'entries': {
          'row': {'uid': 1, 'key': <String>[], 'content': '{{banned::x}}', 'disable': value},
        },
      };
      final before = jsonEncode(raw);
      final report = _assess(TavernImportKind.lorebook, raw);
      final inactive = value == true;
      expect(_code(report, 'macro-banned-no-effect').single.conditional, inactive, reason: '$value');
      expect(report.counts['entriesDisabled'], inactive ? 1 : 0, reason: '$value');
      expect(report.verdict, inactive ? TavernImportVerdict.usable : TavernImportVerdict.partial, reason: '$value');
      expect(jsonEncode(raw), before);
    }
  });

  test('V3 enabled semantics require literal true including absent null and nonboolean cases', () {
    for (final flags in <Map<String, Object?>>[
      {},
      {'enabled': null},
      {'enabled': false},
      {'enabled': 0},
      {'enabled': 1},
      {'enabled': 'true'},
      {'enabled': 'false'},
      {'enabled': true},
    ]) {
      final raw = <String, Object?>{
        'entries': [
          {'id': 1, 'keys': <String>[], 'content': '{{banned::x}}', ...flags},
        ],
      };
      final before = jsonEncode(raw);
      final report = _assess(TavernImportKind.lorebook, raw);
      final inactive = flags['enabled'] != true;
      expect(_code(report, 'macro-banned-no-effect').single.conditional, inactive, reason: '$flags');
      expect(report.counts['entriesDisabled'], inactive ? 1 : 0, reason: '$flags');
      expect(report.verdict, inactive ? TavernImportVerdict.usable : TavernImportVerdict.partial, reason: '$flags');
      expect(jsonEncode(raw), before);
    }
  });

  test('actual keyword fields retain original indices while nonstrings stay unexpanded', () {
    for (final v3 in [false, true]) {
      final entry = <String, Object?>{
        if (v3) 'enabled': true,
        (v3 ? 'keys' : 'key'): <Object?>[false, '{{banned::primary}}'],
        (v3 ? 'secondary_keys' : 'keysecondary'): <Object?>[null, '{{banned::secondary}}'],
        'content': '',
      };
      final raw = <String, Object?>{
        'entries': v3 ? <Object?>[entry] : <String, Object?>{'row': entry},
      };
      final before = jsonEncode(raw);
      final report = _assess(TavernImportKind.lorebook, raw);
      expect(
        _code(report, 'macro-banned-no-effect').map((value) => value.path),
        v3
            ? [r'$.entries[0].keys[1]', r'$.entries[0].secondary_keys[1]']
            : [r'$.entries["row"].key[1]', r'$.entries["row"].keysecondary[1]'],
      );
      expect(report.counts['macroOccurrences'], 2);
      expect(report.counts['ignoredKeywordValues'], 2);
      expect(jsonEncode(raw), before);
    }
  });

  test('text findings use loader UID normalization and source shape fallback identities', () {
    final cases = <Map<String, Object?>>[
      {
        'entries': {
          'row': {'uid': 1.0, 'id': 'ignored', 'key': <String>[], 'content': '{{banned::x}}'},
        },
      },
      {
        'entries': [
          {'id': 1.0, 'uid': 'ignored', 'enabled': true, 'keys': <String>[], 'content': '{{banned::x}}'},
        ],
      },
      {
        'entries': {
          'fallback-key': {'key': <String>[], 'content': '{{banned::x}}'},
        },
      },
      {
        'entries': [
          {'enabled': true, 'keys': <String>[], 'content': '{{banned::x}}'},
        ],
      },
    ];
    final expected = ['1', '1', 'fallback-key', '0'];
    for (var index = 0; index < cases.length; index++) {
      final before = jsonEncode(cases[index]);
      final report = _assess(TavernImportKind.lorebook, cases[index]);
      expect(_code(report, 'macro-banned-no-effect').single.identifier, expected[index]);
      expect(jsonEncode(cases[index]), before);
    }
  });

  test('stored V3 rows keep separate text findings even when normalized ids collide', () {
    final raw = <String, Object?>{
      'entries': [
        {'id': 1.0, 'enabled': true, 'keys': <String>[], 'content': '{{banned::first}}'},
        {'id': '1', 'enabled': true, 'keys': <String>[], 'content': '{{banned::second}}'},
      ],
    };
    final before = jsonEncode(raw);
    final report = _assess(TavernImportKind.lorebook, raw);
    final findings = _code(report, 'macro-banned-no-effect');
    expect(findings.map((value) => value.path), [r'$.entries[0].content', r'$.entries[1].content']);
    expect(findings.map((value) => value.identifier), ['1', '1']);
    expect(report.counts['entriesStored'], 2);
    expect(report.counts['entriesInExecutionView'], 1);
    expect(report.counts['macroOccurrences'], 2);
    expect(jsonEncode(raw), before);
  });

  test('a structurally invalid book proves no execution view while an empty book is valid', () {
    final malformed = _assess(TavernImportKind.lorebook, {
      'entries': [false],
    });
    expect(malformed.verdict, TavernImportVerdict.preserveOnly);
    expect(malformed.counts['entriesInExecutionView'], 0);
    final empty = _assess(TavernImportKind.lorebook, {'entries': <Object?>[]});
    expect(empty.verdict, TavernImportVerdict.usable);
    final card = _card({
      'first_mes': 'still useful',
      'character_book': {
        'entries': [false],
      },
    });
    expect(card.verdict, TavernImportVerdict.partial);
  });

  test('disabled regex output macro limitations remain conditional', () {
    final report = _assess(TavernImportKind.regex, _rule({'disabled': true, 'replaceString': '{{banned::x}}'}));
    expect(report.findings.single.conditional, isTrue);
    expect(report.findings.single.kind, TavernImportFindingKind.conditional);
    expect(report.verdict, TavernImportVerdict.usable);
  });

  test('HTML counts describe fields rather than counting every tag as a fragment', () {
    final report = _card({
      'first_mes': '<b>a</b><i>b</i>',
      'alternate_greetings': ['<div>c</div>', 'plain'],
    });
    expect(report.counts['htmlFragments'], 2);
    expect(report.renderLevel, 1);
  });

  test('fingerprints depend on inspected content not the import path or check date', () {
    final document = _rule({'replaceString': '{{banned::word}}'});
    final first = _assess(TavernImportKind.regex, document, path: r'$[5]');
    final second = assessImport(
      kind: TavernImportKind.regex,
      document: document,
      checkedAt: DateTime.utc(2026, 11, 11),
    );
    expect(first.fingerprint, second.fingerprint);
    expect(first.findings.single.path, r'$[5].replaceString');
    expect(second.findings.single.path, r'$.replaceString');
    expect(first.checkedAt, isNot(second.checkedAt));
  });
}

TavernImportReport _card(Map<String, Object?> fields) => _assess(TavernImportKind.character, {'data': fields});

TavernImportReport _assess(
  TavernImportKind kind,
  Map<String, Object?> document, {
  Map<String, Object?>? envelope,
  Iterable<String> embeddedAssetPaths = const [],
  Iterable<TavernRegexDiagnostic> regexDiagnostics = const [],
  Iterable<TavernPresetIssue> presetIssues = const [],
  String path = r'$',
}) => assessImport(
  kind: kind,
  document: document,
  envelope: envelope,
  embeddedAssetPaths: embeddedAssetPaths,
  regexDiagnostics: regexDiagnostics,
  presetIssues: presetIssues,
  checkedAt: DateTime.utc(2026, 11, 10),
  path: path,
);

List<TavernImportFinding> _code(TavernImportReport report, String code) =>
    report.findings.where((value) => value.code == code).toList();

Map<String, Object?> _rule([Map<String, Object?> fields = const {}]) => {
  'id': 'rule',
  'scriptName': 'rule',
  'findRegex': 'a',
  'replaceString': '',
  'placement': [2],
  'disabled': false,
  ...fields,
};

TavernRegexDiagnostic _diagnostic(
  TavernRegexCompatibility status, {
  String path = r'$.findRegex',
  String code = 'compiled',
}) => TavernRegexDiagnostic(path: path, status: status, code: code, message: 'receipt', identifier: 'rule');
