"""Offline regression tests: python3 -m unittest discover -s app/tool -p test_l10n_merge.py."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

import l10n_merge


class MessagePreflightTest(unittest.TestCase):
    def test_duplicate_plural_and_select_cases_are_rejected(self):
        for kind, case in [('plural', 'one'), ('plural', '=1'), ('select', 'ready')]:
            with self.subTest(kind=kind, case=case):
                _, errors = l10n_merge.parse_message(
                    f'{{count, {kind}, {case}{{first}} {case}{{second}} other{{last}}}}')
                self.assertTrue(any('duplicate' in e for e in errors), errors)

    def test_unknown_plural_category_is_rejected(self):
        _, errors = l10n_merge.parse_message('{count, plural, feww{few} other{other}}')
        self.assertTrue(any('unknown plural category' in e for e in errors), errors)

    def test_exact_selector_and_its_category_cannot_share_a_block(self):
        for first, second in [('=0', 'zero'), ('=1', 'one'), ('=2', 'two'), ('one', '=1')]:
            with self.subTest(first=first, second=second):
                _, errors = l10n_merge.parse_message(
                    f'{{n, plural, {first}{{A}} {second}{{B}} other{{C}}}}')
                self.assertTrue(any('same case to gen-l10n' in e for e in errors), errors)

    def test_exact_selector_alone_remains_valid(self):
        names, errors = l10n_merge.parse_message('{n, plural, =0{None} =1{One} other{{n} items}}')
        self.assertEqual(names, {'n'})
        self.assertEqual(errors, [])

    def test_select_values_are_not_plural_categories(self):
        names, errors = l10n_merge.parse_message('{state, select, ready{Ready} failed{Failed} other{Other}}')
        self.assertEqual(names, {'state'})
        self.assertEqual(errors, [])

    def test_russian_categories_with_nested_placeholder_are_valid(self):
        names, errors = l10n_merge.parse_message(
            '{count, plural, =0{Нет файлов} one{{count} файл} few{{count} файла} '
            'many{{count} файлов} other{{count} файла}}')
        self.assertEqual(names, {'count'})
        self.assertEqual(errors, [])

    def test_nested_select_keeps_its_own_cases(self):
        names, errors = l10n_merge.parse_message(
            '{state, select, ready{{count, plural, one{One} other{{count}}}} other{Wait}}')
        self.assertEqual(names, {'state', 'count'})
        self.assertEqual(errors, [])

    def test_existing_relaxed_literal_braces_and_apostrophes_remain_valid(self):
        names, errors = l10n_merge.parse_message("It's JSON: {\"ok\": true}; command {name}")
        self.assertEqual(names, {'name'})
        self.assertEqual(errors, [])


class MergeFixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name)
        (self.app / 'tool').mkdir()
        self.script = self.app / 'tool/l10n_merge.py'
        shutil.copyfile(Path(l10n_merge.__file__), self.script)
        self.parts = self.app / 'lib/l10n/parts'
        self.parts.mkdir(parents=True)
        self.write('zh', {'title': '标题'})
        self.write('en', {'title': 'Title'})
        self.outputs = [self.parts.parent / f'app_{lang}.arb' for lang in ('zh', 'en')]
        for output in self.outputs:
            output.write_text('existing-output', encoding='utf-8')

    def write(self, lang, data):
        (self.parts / f'probe_{lang}.arb').write_text(
            json.dumps(data, ensure_ascii=False), encoding='utf-8')

    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(self.script), *args],
                              capture_output=True, text=True, encoding='utf-8')

    def assert_rejected_without_writes(self, needle):
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout + result.stderr)
        self.assertNotIn('Traceback', result.stdout + result.stderr)
        for output in self.outputs:
            self.assertEqual(output.read_text(encoding='utf-8'), 'existing-output')


class MergeCliTest(MergeFixture):
    def test_appledouble_metadata_is_not_an_arb_catalog(self):
        (self.parts / '._probe_zh.arb').write_bytes(b'\x00\x05\x16\x07metadata')
        (self.parts.parent / '._app_en.arb').write_bytes(b'\x00\x05\x16\x07metadata')
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(self.outputs[0].read_text())['title'], '标题')

    def test_valid_merge_preserves_template_metadata(self):
        self.write('zh', {'title': '{name} 的标题', '@title': {'placeholders': {'name': {'type': 'String'}}}})
        self.write('en', {'title': 'Title for {name}'})
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        zh, en = [json.loads(output.read_text(encoding='utf-8')) for output in self.outputs]
        self.assertEqual(zh, {'@@locale': 'zh', 'title': '{name} 的标题',
                             '@title': {'placeholders': {'name': {'type': 'String'}}}})
        self.assertEqual(en, {'@@locale': 'en', 'title': 'Title for {name}'})

    def test_duplicate_message_key_is_not_silently_overwritten(self):
        (self.parts / 'probe_en.arb').write_text('{"title":"Correct","title":"Wrong"}', encoding='utf-8')
        self.assert_rejected_without_writes('duplicate key "title"')

    def test_duplicate_nested_metadata_is_rejected(self):
        (self.parts / 'probe_zh.arb').write_text(
            '{"title":"{n}","@title":{"placeholders":{"n":{"type":"int","type":"String"}}}}',
            encoding='utf-8')
        self.assert_rejected_without_writes('duplicate key "type"')

    def test_non_object_root_has_a_clear_diagnostic(self):
        for value in ([], None, 42, 'text'):
            with self.subTest(value=value):
                self.write('zh', value)
                self.assert_rejected_without_writes('ARB root must be an object')

    def test_non_json_constants_are_rejected(self):
        (self.parts / 'probe_zh.arb').write_text('{"title": NaN}', encoding='utf-8')
        self.assert_rejected_without_writes('non-JSON constant NaN')

    def test_empty_placeholder_declaration_does_not_skip_validation(self):
        self.write('zh', {'title': '{name}', '@title': {'placeholders': {}}})
        self.write('en', {'title': '{name}'})
        self.assert_rejected_without_writes('placeholders [] ≠ message [\'name\']')

    def test_metadata_shapes_and_orphan_entries_fail_cleanly(self):
        cases = [
            ({'title': '标题', '@title': 'description'}, 'metadata must be an object'),
            ({'title': '标题', '@title': {'placeholders': []}}, 'placeholders must be an object'),
            ({'title': '标题', '@title': {'placeholders': {'n': 'int'}}}, 'placeholder "n" must be an object'),
            ({'title': '标题', '@missing': {}}, 'orphan metadata'),
        ]
        for data, needle in cases:
            with self.subTest(data=data):
                self.write('zh', data)
                self.assert_rejected_without_writes(needle)

    def test_translation_metadata_is_checked_when_present(self):
        self.write('en', {'title': 'Title', '@title': {'placeholders': {'missing': {'type': 'String'}}}})
        self.assert_rejected_without_writes('en: "@title" placeholders')

    def test_empty_messages_in_either_language_are_rejected(self):
        for lang in ('zh', 'en'):
            with self.subTest(lang=lang):
                self.write('zh', {'title': '标题'})
                self.write('en', {'title': 'Title'})
                self.write(lang, {'title': ' \n\t'})
                self.assert_rejected_without_writes(f'"title" {lang} is empty')

    def test_invalid_icu_prevents_any_output(self):
        self.write('zh', {'title': '{n} 项'})
        self.write('en', {'title': '{n, plural, one{One} one{Again} other{Many}}'})
        self.assert_rejected_without_writes('duplicate plural case "one"')


class AdditionalLocaleTest(MergeFixture):
    def assert_locale_rejected(self, needle, *options):
        result = self.run_cli('--no-gen', '--locale', 'ru', *options)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(needle, result.stdout + result.stderr)
        for output in self.outputs:
            self.assertEqual(output.read_text(encoding='utf-8'), 'existing-output')
        self.assertFalse((self.parts.parent / 'app_ru.arb').exists())

    def test_unselected_draft_is_never_loaded_or_generated(self):
        (self.parts / 'probe_ru.arb').write_text('unfinished draft, not JSON', encoding='utf-8')
        result = self.run_cli('--no-gen')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.parts.parent / 'app_ru.arb').exists())

    def test_complete_extra_locale_can_add_russian_plural_categories(self):
        self.write('zh', {'title': '{n} 个文件', '@title': {'placeholders': {'n': {'type': 'int'}}}})
        self.write('en', {'title': '{n, plural, one{{n} file} other{{n} files}}'})
        ru = '{n, plural, one{{n} файл} few{{n} файла} many{{n} файлов} other{{n} файла}}'
        self.write('ru', {'title': ru})
        result = self.run_cli('--no-gen', '--locale', 'ru')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.parts.parent / 'app_ru.arb').read_text(encoding='utf-8')),
                         {'@@locale': 'ru', 'title': ru})

    def test_four_complete_locales_are_explicitly_selected(self):
        values = {'ru': 'Заголовок', 'ja': 'タイトル', 'ko': '제목', 'es': 'Título'}
        for lang, value in values.items():
            self.write(lang, {'title': value})
        options = [item for lang in values for item in ('--locale', lang)]
        result = self.run_cli('--no-gen', *options)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for lang, value in values.items():
            self.assertEqual(json.loads((self.parts.parent / f'app_{lang}.arb').read_text(encoding='utf-8')),
                             {'@@locale': lang, 'title': value})

    def test_missing_extra_locale_part_fails_without_filling_english(self):
        self.assert_locale_rejected('missing probe_ru.arb')

    def test_extra_locale_missing_or_unknown_keys_fail(self):
        for data, needle in [({}, 'has zh but no ru'), ({'title': 'Заголовок', 'extra': 'Лишнее'}, 'has ru but no zh')]:
            with self.subTest(data=data):
                self.write('ru', data)
                self.assert_locale_rejected(needle)

    def test_extra_locale_placeholder_and_icu_errors_are_checked(self):
        self.write('zh', {'title': '{n} 个'})
        self.write('en', {'title': '{n}'})
        for value, needle in [('{missing}', 'placeholders differ'),
                              ('{n, plural, feww{A} other{B}}', 'unknown plural category')]:
            with self.subTest(value=value):
                self.write('ru', {'title': value})
                self.assert_locale_rejected(needle)

    def test_locale_metadata_must_match_the_selected_file(self):
        self.write('ru', {'@@locale': 'en', 'title': 'Заголовок'})
        self.assert_locale_rejected('@@locale must equal "ru"')

    def test_region_subtag_and_area_underscores_are_not_confused(self):
        for lang, value in [('zh', '标题'), ('en', 'Title'), ('es', 'Título'), ('es_MX', 'Título')]:
            (self.parts / f'other_area_{lang}.arb').write_text(
                json.dumps({'regionTitle': value}), encoding='utf-8')
        self.write('es', {'title': 'Título'})
        self.write('es_MX', {'title': 'Título'})
        result = self.run_cli('--no-gen', '--locale', 'es', '--locale', 'es_MX')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.parts.parent / 'app_es_MX.arb').read_text(encoding='utf-8')),
                         {'@@locale': 'es_MX', 'regionTitle': 'Título', 'title': 'Título'})

    def test_extra_locale_cannot_introduce_an_unpaired_area(self):
        self.write('ru', {'title': 'Заголовок'})
        (self.parts / 'orphan_ru.arb').write_text('{"orphan":"No source"}', encoding='utf-8')
        self.assert_locale_rejected('missing orphan_zh.arb')

    def test_malformed_duplicate_and_builtin_locale_arguments_fail_cleanly(self):
        for options in [('--locale', '../ru'), ('--locale', 'ru-RU'), ('--locale', 'en'),
                        ('--locale', 'ru', '--locale', 'ru'), ('--part',)]:
            with self.subTest(options=options):
                result = self.run_cli('--no-gen', *options)
                self.assertEqual(result.returncode, 2)
                self.assertNotIn('Traceback', result.stdout + result.stderr)
                for output in self.outputs:
                    self.assertEqual(output.read_text(encoding='utf-8'), 'existing-output')

    def test_full_check_refuses_unselected_merged_catalog(self):
        unexpected = self.parts.parent / 'app_ru.arb'
        unexpected.write_text('do not delete automatically', encoding='utf-8')
        self.assert_rejected_without_writes('unselected merged catalogs: app_ru.arb')
        self.assertEqual(unexpected.read_text(encoding='utf-8'), 'do not delete automatically')
        result = self.run_cli('--check')
        self.assertEqual(result.returncode, 1)

    def test_non_app_filename_cannot_bypass_locale_opt_in(self):
        unexpected = self.parts.parent / 'draft_ru.arb'
        unexpected.write_text('{"@@locale":"ru","title":"Draft"}', encoding='utf-8')
        self.assert_rejected_without_writes('unselected merged catalogs: draft_ru.arb')
        self.assertEqual(unexpected.read_text(encoding='utf-8'), '{"@@locale":"ru","title":"Draft"}')

    def test_region_or_script_locale_requires_its_base_locale(self):
        for locale in ('es_MX', 'sr_Latn', 'sr_Latn_RS'):
            with self.subTest(locale=locale):
                result = self.run_cli('--no-gen', '--locale', locale)
                self.assertEqual(result.returncode, 2)
                self.assertIn('needs its base locale', result.stderr)
                for output in self.outputs:
                    self.assertEqual(output.read_text(encoding='utf-8'), 'existing-output')

    def test_part_check_can_validate_a_draft_area_without_releasing_it(self):
        self.write('ru', {'title': 'Заголовок'})
        for lang in ('zh', 'en'):
            (self.parts / f'other_{lang}.arb').write_text('{"other":"Other"}', encoding='utf-8')
        result = self.run_cli('--part', 'probe', '--locale', 'ru')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse((self.parts.parent / 'app_ru.arb').exists())
        self.assert_locale_rejected('missing other_ru.arb')

    def test_empty_input_directory_cannot_claim_success(self):
        for path in self.parts.iterdir():
            path.unlink()
        self.assert_rejected_without_writes('no ARB parts')


if __name__ == '__main__':
    unittest.main()
