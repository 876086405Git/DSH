"""python3 -m unittest discover -s app/tool -p 'test_guide_sync.py'"""
import json
import tempfile
import unittest
from pathlib import Path

import guide_sync

REPO = Path(__file__).resolve().parents[2]

SKILL = """---
# dsh-go:managed — the dsh-go app keeps this skill up to date
name: dsh-go-guide
description: The guide.
whenToUse: How to use the app.
---

Read [README](README.md).
"""

PAGE = {
    'zh': '# 引擎\n\n<!-- nav: commonSettings,hubSettingsEngine -->\n`设置 › 引擎` · [打开](dshgo://open/engine)\n\n点**启动**，或点**停止操作**。见 [设置](02-settings.md)。\n',
    'en': '# Engine\n\n<!-- nav: commonSettings,hubSettingsEngine -->\n`Settings › Engine` · [Open](dshgo://open/engine)\n\nTap **Start**, or **Stop actions**. See [Settings](02-settings.md).\n',
}

PAGE_LINKS = """const catalogPageLinks = <String>{
  'schedules',
};
"""

SPOTS = """final _pages = <SettingsPageMeta>[
  SettingsPageMeta(SettingsPageId.hub, title: (l) => l.commonSettings, links: const ['settings']),
  SettingsPageMeta(
    SettingsPageId.engine,
    title: (l) => l.hubSettingsEngine,
    links: const ['engine', 'phone'],
  ),
];
static final darkMode = SettingSpot('dark-mode', page: SettingsPageId.appearance, link: 'dark-mode');
"""


class GuideSyncTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.repo = Path(self.temp.name)
        self.guide = self.repo / 'docs/guide'
        self.write('app/pubspec.yaml', 'name: app\nversion: 0.9.2+1\n')
        self.write('app/lib/l10n/parts/hub_zh.arb', json.dumps(
            {'commonSettings': '设置', 'hubSettingsEngine': '引擎', 'phoneEngineStart': '启动', 'count': '{n} 个'}))
        self.write('app/lib/l10n/parts/hub_en.arb', json.dumps(
            {'commonSettings': 'Settings', 'hubSettingsEngine': 'Engine', 'phoneEngineStart': 'Start', 'count': '{n}'}))
        res = 'app/android/app/src/main/res'
        self.write(f'{res}/values-zh/s.xml', '<resources><string name="stop">停止操作</string></resources>')
        self.write(f'{res}/values/s.xml', '<resources><string name="stop">Stop actions</string></resources>')
        self.write('app/lib/links/page_links.dart', PAGE_LINKS)
        self.write('app/lib/ui/settings/index/spots.dart', SPOTS)
        self.write('docs/guide/SKILL.md', SKILL)
        self.write('docs/guide/README.md', '# Guide\n\n> dsh-go 0.9.2\n\n- [引擎](zh/01-engine.md)\n- [Engine](en/01-engine.md)\n')
        for locale, text in PAGE.items():
            self.write(f'docs/guide/{locale}/01-engine.md', text)
            self.write(f'docs/guide/{locale}/02-settings.md', '# Settings\n')

    def write(self, rel, text):
        path = self.repo / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')

    def errors(self):
        return guide_sync.check(self.repo, self.guide)

    def assertFails(self, needle):
        errors = self.errors()
        self.assertTrue(any(needle in e for e in errors), f'{needle!r} not in {errors}')

    def test_valid_guide_builds_and_then_checks_clean(self):
        self.assertEqual(self.errors(), [])
        self.assertEqual(guide_sync.run(self.repo, write=True), [])
        self.assertEqual(guide_sync.run(self.repo, write=False), [])
        assets = self.repo / 'app/assets/skills/dsh-go-guide'
        manifest = json.loads((assets / 'manifest.json').read_text())
        self.assertEqual(manifest['name'], 'dsh-go-guide')
        self.assertEqual(manifest['files']['zh-01-engine.md'], 'zh/01-engine.md')
        self.assertEqual(set(manifest['files']), {p.name for p in assets.iterdir()} - {'manifest.json'})
        for flat, target in manifest['files'].items():
            self.assertEqual((assets / flat).read_bytes(), (self.guide / target).read_bytes())

    def test_appledouble_metadata_does_not_enter_the_bundled_guide(self):
        self.write('docs/guide/zh/._01-engine.md', 'not a guide page')
        self.write('app/lib/l10n/parts/._hub_zh.arb', 'not JSON')
        self.write('app/android/app/src/main/res/values/._s.xml', 'not XML')
        self.assertEqual(guide_sync.run(self.repo, write=True), [])
        assets = self.repo / 'app/assets/skills/dsh-go-guide'
        (assets / '._SKILL.md').write_bytes(b'\x00\x05\x16\x07metadata')
        self.assertEqual(guide_sync.run(self.repo, write=False), [])
        manifest = json.loads((assets / 'manifest.json').read_text())
        self.assertFalse(any(name.startswith('._') for name in manifest['files']))

    def test_generated_assets_cannot_drift(self):
        guide_sync.run(self.repo, write=True)
        assets = self.repo / 'app/assets/skills/dsh-go-guide'
        (assets / 'zh-01-engine.md').write_text('edited by hand')
        self.assertTrue(any('out of date' in e for e in guide_sync.run(self.repo, write=False)))
        guide_sync.run(self.repo, write=True)
        (assets / 'stale.md').write_text('old page')
        self.assertTrue(any('stale.md' in e for e in guide_sync.run(self.repo, write=False)))
        guide_sync.run(self.repo, write=True)
        self.assertFalse((assets / 'stale.md').exists())

    def test_nav_label_must_match_the_arb(self):
        self.write('docs/guide/zh/01-engine.md', PAGE['zh'].replace('`设置 › 引擎`', '`设置 › 运行环境`'))
        self.assertFails('want `设置 › 引擎`')

    def test_nav_key_must_exist(self):
        self.write('docs/guide/en/01-engine.md', PAGE['en'].replace('hubSettingsEngine', 'hubSettingsGone'))
        self.assertFails('no en ARB key hubSettingsGone')

    def test_nav_uses_the_page_locale(self):
        self.write('docs/guide/en/01-engine.md', PAGE['en'].replace('`Settings › Engine`', '`设置 › 引擎`'))
        self.assertFails('want `Settings › Engine`')

    def test_placeholder_labels_are_not_paths(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n<!-- nav: count -->\n`{n} 个`\n')
        self.assertFails('not a plain label')

    def test_path_without_annotation_fails(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n在 `设置 › 引擎` 里。\n')
        self.assertFails('path without a nav annotation')

    def test_malformed_annotation_fails(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n<!-- nav: commonSettings, hubSettingsEngine -->\n`设置 › 引擎`\n')
        self.assertFails('malformed annotation')

    def test_bold_must_be_a_label_of_that_locale(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n点**开始**。\n')
        self.assertFails('**开始** is not a zh UI label')
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n点**Start**。\n')
        self.assertFails('**Start** is not a zh UI label')

    def test_links_must_resolve_and_page_links_must_be_allowed(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n见 [宠物](06-pets.md)。\n')
        self.assertFails('broken link 06-pets.md')
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n[打开](dshgo://open/terminal)\n')
        self.assertFails('dshgo://open/terminal is not a page link')
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n[打开](dshgo://open/settings)\n')
        self.assertEqual(self.errors(), [])
        # A row's link and a 全部功能 page open too.
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n[深色](dshgo://open/dark-mode) [自动化](dshgo://open/schedules)\n')
        self.assertEqual(self.errors(), [])

    def test_version_must_match_pubspec(self):
        self.write('app/pubspec.yaml', 'version: 0.9.3+1\n')
        self.assertFails('`> dsh-go 0.9.3`')

    def test_both_languages_hold_the_same_pages(self):
        (self.guide / 'en/02-settings.md').unlink()
        self.assertFails('zh/en pages differ')

    def test_skill_front_matter(self):
        self.write('docs/guide/SKILL.md', SKILL.replace('# dsh-go:managed — the dsh-go app keeps this skill up to date\n', ''))
        self.assertFails('# dsh-go:managed')
        self.write('docs/guide/SKILL.md', SKILL.replace('whenToUse', 'when'))
        self.assertFails('needs whenToUse')
        self.write('docs/guide/SKILL.md', SKILL.replace('description: The guide.', 'description: The guide: where things are.'))
        self.assertFails('description must be a plain one-line value')

    def test_product_copy_words(self):
        self.write('docs/guide/zh/02-settings.md', '# 设置\n\n新会话。\n')
        self.assertFails('avoid 「会话」')

    def test_stray_files_fail(self):
        self.write('docs/guide/notes.txt', 'draft')
        self.assertFails('notes.txt: not part of the guide')


class RepositoryGuideTest(unittest.TestCase):
    def test_docs_guide_matches_the_app_and_its_assets(self):
        self.assertEqual(guide_sync.run(REPO, write=False), [])


if __name__ == '__main__':
    unittest.main()
