#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
spec=importlib.util.spec_from_file_location('audit_dart_bridges',HERE.parent/'audit-dart-bridges.py')
audit=importlib.util.module_from_spec(spec);sys.modules[spec.name]=audit;spec.loader.exec_module(audit)

class BridgeInventoryTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.dart=self.root/'app/lib/calls.dart';self.dart.parent.mkdir(parents=True)
        self.native=self.root/'app/ohos/entry/src/main/ets/plugins/FixturePlugin.ets';self.native.parent.mkdir(parents=True)
        self.entry=self.native.parent.parent/'entryability/EntryAbility.ets';self.entry.parent.mkdir()
        for source,target in [('calls.dart',self.dart),('FixturePlugin.ets',self.native),('EntryAbility.ets',self.entry)]:
            shutil.copy2(HERE/'fixtures/dart-bridges'/source,target)

    def report(self,required=('dsh/first','dsh/second')):
        return audit.audit(self.root,{},required)

    def test_literals_generics_inline_system_event_and_callback_are_distinct(self):
        report=self.report()
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(len(report['dartCalls']),5)
        self.assertEqual(report['counts'],{'HANDLER_PRESENT':3,'SYSTEM_BUILTIN_NOT_APP_ARKTS':1,'EVENT_HANDLER_PRESENT':1})
        self.assertEqual(len(report['nativeToDartCallbacks']),1)
        self.assertEqual(report['nativeToDartCallbacks'][0]['classification'],'NATIVE_TO_DART_CALLBACK')

    def test_another_channel_and_unreachable_or_unrelated_cases_do_not_satisfy_call(self):
        with self.dart.open('a') as f:f.write("\nvoid missing() { first.invokeMethod('list'); second.invokeMethod('unreachable'); second.invokeMethod('unrelatedCase'); }\n")
        report=self.report()
        failed=[r for r in report['dartCalls'] if r['status']=='MISSING_METHOD']
        self.assertEqual([r['method'] for r in failed],['list','unreachable','unrelatedCase'])
        self.assertEqual(report['gateStatus'],'FAIL')

    def test_handler_definition_without_entry_registration_stays_unconfirmed(self):
        self.entry.write_text('const unrelated = new FixturePlugin();')
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        self.assertTrue(any(r['status']=='UNCONFIRMED_REGISTRATION' for r in report['dartCalls']))

    def test_dynamic_method_is_unknown_and_required_scope_fails(self):
        with self.dart.open('a') as f:f.write('\nvoid dynamicCall(String method) { first.invokeMethod(method); }\n')
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        self.assertEqual(report['fullInventoryStatus'],'INCOMPLETE')
        self.assertEqual(report['counts']['UNKNOWN_DYNAMIC'],1)

    def test_whitelist_and_dispatch_are_independent_requirements(self):
        original=self.native.read_text()
        for removed in ('whitelist','dispatch'):
            with self.subTest(removed=removed):
                if removed=='whitelist':
                    changed=original.replace("['read', 'readAll']", "['read']")
                else:
                    changed=original.replace("if (call.method === 'readAll') result.success({});", '')
                self.native.write_text(changed)
                report=self.report()
                row=next(row for row in report['dartCalls'] if row['method']=='readAll')
                self.assertEqual(report['gateStatus'],'FAIL')
                self.assertIn(removed,row['missingLayers'])
        self.native.write_text(original)
        self.assertEqual(self.report()['gateStatus'],'PASS_SCOPED')

    def test_dynamic_whitelist_is_not_assumed_to_accept_all_methods(self):
        self.native.write_text(self.native.read_text().replace("['read', 'readAll']", "allowedMethods"))
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        self.assertTrue(any(row['status']=='UNKNOWN_ACCEPTANCE' for row in report['dartCalls']))

    def actual_plugin(self, name, channel, methods):
        source=HERE.parents[2]/'app/ohos/entry/src/main/ets/plugins'/f'{name}.ets'
        self.native.write_text(source.read_text())
        self.entry.write_text(f"engine.getPlugins()?.add(new {name}());")
        self.dart.write_text("const bridge = MethodChannel('"+channel+"'); void run() {"+
                             ''.join(f"bridge.invokeMethod('{method}');" for method in methods)+'}')
        return lambda: self.report((channel,))

    def test_negative_reject_guard_requires_return_and_real_continuation(self):
        report=self.actual_plugin('AppLinksPlugin','dsh/links',['ready'])
        original=self.native.read_text()
        self.assertEqual(report()['gateStatus'],'PASS_SCOPED')
        # An unterminated rejection is not a proof of the allowed path.
        self.native.write_text(original.replace('result.notImplemented(); return;', 'result.notImplemented();'))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('result.success(true);', ''))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_try_wrapped_reject_guard_requires_a_real_continuation(self):
        report=self.actual_plugin('PerformancePlugin','dsh/performance',['snapshot'])
        original="""class PerformancePlugin {
  onAttachedToEngine(binding) {
    this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/performance');
    this.methods.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      if (call.method !== 'snapshot') { try { result.notImplemented(); } catch (_) {} return; }
      try { result.success(this.snapshot()); } catch (_) {}
    } });
  }
}"""
        self.native.write_text(original)
        self.assertEqual(report()['gateStatus'],'PASS_SCOPED')
        self.native.write_text(original.replace('result.success(this.snapshot());',''))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_try_catch_rejection_and_non_guard_list_do_not_make_acceptance_unknown(self):
        for name,channel,methods in [
            ('VoicePlugin','dsh/voice',['permission','capabilities','cancel']),
            ('NotifyPlugin','dsh/notify',['status','show','requestPermission']),
            ('NativeMediaPlugin','dsh/native-media',['capabilities'])]:
            with self.subTest(plugin=name):
                report=self.actual_plugin(name,channel,methods)
                self.assertEqual(report()['gateStatus'],'PASS_SCOPED')
        self.native.write_text(self.native.read_text().replace("try { result.notImplemented(); } catch (_) {} return;", "try { result.notImplemented(); return; } catch (_) {}"))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_allowed_method_falls_through_unique_forwarded_handler(self):
        report=self.actual_plugin('FilesMediaPlugin','dsh/media',['saveImage','openSettings'])
        self.assertEqual(report()['gateStatus'],'PASS_SCOPED')
        original=self.native.read_text()
        start=original.index('  private async mediaCall(')
        self.native.write_text(original[:start]+"  private async mediaCall(call: MethodCall): Promise<Any> { if (call.method === 'openSettings') return false; } }\n")
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('this.mediaCall(call)', 'this.missingHandler(call)'))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('this.reply(this.mediaCall(call), result);',
                                               'if (false) { this.reply(this.mediaCall(call), result); }'))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_binary_ternary_fallback_does_not_certify_a_third_allowed_method(self):
        report=self.actual_plugin('DiagnosticsPlugin','dsh/diagnostics',['info','engineLog'])
        self.assertEqual(report()['gateStatus'],'PASS_SCOPED')
        original=self.native.read_text()
        self.native.write_text(original.replace("['info', 'engineLog']", "['info', 'engineLog', 'other']"))
        self.dart.write_text(self.dart.read_text().replace("bridge.invokeMethod('engineLog');", "bridge.invokeMethod('other');"))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('logs.tail(limit)', 'undefined'))
        self.dart.write_text(self.dart.read_text().replace("bridge.invokeMethod('other');", "bridge.invokeMethod('engineLog');"))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('result.success(value);',''))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_unreachable_ternary_and_reply_are_not_dispatch_evidence(self):
        report=self.actual_plugin('DiagnosticsPlugin','dsh/diagnostics',['engineLog'])
        original=self.native.read_text()
        assignment="work = call.method === 'info' ? this.info(context, logs) : logs.tail(limit);"
        self.native.write_text(original.replace(assignment, 'if (false) { '+assignment+' }'))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace(assignment, 'const neverCalled = (): void => { '+assignment+' };'))
        self.assertEqual(report()['gateStatus'],'FAIL')
        self.native.write_text(original.replace('result.success(value);','if (false) { result.success(value); }'))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_unconditional_return_stops_later_reply_recognition(self):
        report=self.actual_plugin('AppLinksPlugin','dsh/links',['ready'])
        self.native.write_text(self.native.read_text().replace('result.success(true);','return; result.success(true);'))
        self.assertEqual(report()['gateStatus'],'FAIL')

    def test_indirect_rejecting_membership_stays_unknown(self):
        original=self.native.read_text()
        guard="if (!['read', 'readAll'].includes(call.method))"
        for declaration in ["const accepted = ['read'].includes(call.method);", "const allowedMethods = ['read']; const accepted = allowedMethods.includes(call.method);"]:
            with self.subTest(declaration=declaration):
                self.native.write_text(original.replace(guard, declaration+' if (!accepted)'))
                report=self.report()
                self.assertEqual(report['gateStatus'],'FAIL')
                self.assertTrue(any(row['status']=='UNKNOWN_ACCEPTANCE' for row in report['dartCalls']))

    def test_a_whitelist_is_not_required_for_a_switch_only_handler(self):
        report=self.report(('dsh/second',))
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        row=next(row for row in report['nativeHandlers'] if row['channel']=='dsh/second')
        self.assertEqual(row['acceptanceGuards'],[])

    def test_scoped_success_does_not_erase_other_channel_gap(self):
        with self.dart.open('a') as f:f.write("\nvoid missing() { const MethodChannel('dsh/unknown').invokeMethod('x'); }\n")
        report=self.report()
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(report['fullInventoryStatus'],'INCOMPLETE')
        self.assertEqual(report['counts']['MISSING_CHANNEL'],1)

    def test_all_seven_forks_remain_in_report_even_missing_inputs(self):
        rows=self.report()['forks']
        self.assertEqual([row['package'] for row in rows],list(audit.FORKS))
        self.assertTrue(all(row['status']=='UNKNOWN_MISSING_PACKAGE' for row in rows))

    def test_unresolved_alias_in_required_channel_file_does_not_auto_pass(self):
        with self.dart.open('a') as f:f.write("\nvoid indirect(dynamic alias) { alias.invokeMethod('read'); }\n")
        report=self.report()
        self.assertEqual(report['gateStatus'],'FAIL')
        row=next(row for row in report['dartCalls'] if row['receiver']=='alias')
        self.assertEqual(row['status'],'UNKNOWN_DYNAMIC')

    def test_constructor_default_and_field_receiver_resolve_without_claiming_injected_value(self):
        self.dart.write_text("import 'package:flutter/services.dart'; class Consumer { Consumer({MethodChannel? channel}) : _channel = channel ?? const MethodChannel('dsh/first'); final MethodChannel _channel; Future<void> run() async { await _channel.invokeMethod('read'); } }")
        report=self.report(('dsh/first',))
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')
        self.assertEqual(report['dartCalls'][0]['channel'],'dsh/first')

    def test_group1_requires_the_islands_channel_and_every_method_of_it(self):
        def row():
            report=audit.audit(self.root,{},(),True)
            return next(r for r in report['required'] if r.get('channel')=='dsh/islands')
        self.assertEqual([e['status'] for e in row()['errors']],['NO_DART_CALLS','NO_NATIVE_CHANNEL'])
        with self.dart.open('a') as f:f.write("\nclass Islands { Islands([MethodChannel? channel]) : _channel = channel ?? const MethodChannel('dsh/islands'); final MethodChannel _channel; void run() { _channel.invokeMethod<bool>('attach'); _channel.invokeMethod<void>('pause'); } }\n")
        self.assertEqual(row()['status'],'FAIL')
        plugin=self.native.parent/'IslandsPlugin.ets'
        plugin.write_text("export default class IslandsPlugin { onAttachedToEngine(binding) { this.methods = new MethodChannel(binding.getBinaryMessenger(), 'dsh/islands'); this.methods.setMethodCallHandler(this); } onMethodCall(call, result) { switch (call.method) { case 'attach': result.success(true); return; default: result.notImplemented(); } } }")
        self.entry.write_text(self.entry.read_text().replace('add(new FixturePlugin());','add(new FixturePlugin());\n    engine.getPlugins()?.add(new IslandsPlugin());'))
        failed=row()
        self.assertEqual(failed['status'],'FAIL')
        self.assertEqual([(e['method'],e['status']) for e in failed['errors']],[('pause','MISSING_METHOD')])
        plugin.write_text(plugin.read_text().replace("case 'attach':","case 'attach': case 'pause':"))
        self.assertEqual(row()['status'],'PASS_SCOPED')

    def test_selector_gap_is_not_hidden_by_channel_presence(self):
        fork=self.root/'secure';(fork/'lib').mkdir(parents=True)
        (fork/'pubspec.yaml').write_text('name: flutter_secure_storage\nflutter:\n  plugin:\n    platforms:\n      android:\n        pluginClass: SecurePlugin\n')
        (fork/'lib/flutter_secure_storage.dart').write_text("class Store { Map<String,String> _selectOptions() { if (defaultTargetPlatform == TargetPlatform.android) return {}; else throw UnsupportedError('unsupported_platform'); } }")
        report=audit.audit(self.root,{'flutter_secure_storage':fork},('dsh/first',))
        row=next(row for row in report['forks'] if row['package']=='flutter_secure_storage')
        self.assertEqual(row['status'],'NO_OH_DECLARATION')
        self.assertEqual(row['findings'][0]['kind'],'OH_SELECT_OPTIONS_MISSING_BRANCH')
        self.assertEqual(report['gateStatus'],'PASS_SCOPED')

    def test_unrelated_adapter_occurrence_does_not_certify_storage_default(self):
        wrapper=self.root/'app/lib/secrets/secure_storage.dart';wrapper.parent.mkdir()
        wrapper.write_text("class AppSecureStorage { bool get oh => _injected == null && (_platform ?? Platform.operatingSystem) == 'ohos'; }")
        consumers={
            'app/lib/remote/secret_store.dart': 'class SecureSecretStore { SecureSecretStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage); final AppSecureStorage _storage; }',
            'app/lib/forum/forum_auth.dart': 'class SecureForumStore { SecureForumStore([FlutterSecureStorage? storage]) : _storage = AppSecureStorage(storage); final AppSecureStorage _storage; }',
            'app/lib/state/settings_state.dart': 'class SettingsController { static const _secure = AppSecureStorage(); }',
            'app/lib/state/provider_keys.dart': 'class SecureProviderKeyVault { const SecureProviderKeyVault([this._injected]); final FlutterSecureStorage? _injected; AppSecureStorage get _storage => AppSecureStorage(_injected); }',
            'app/lib/share_hosted/hosted_links_state.dart': 'class SecureHostedLinkStore { const SecureHostedLinkStore([this._injected]); final FlutterSecureStorage? _injected; AppSecureStorage get _storage => AppSecureStorage(_injected); }'}
        for relative,body in consumers.items():
            path=self.root/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(body)
        self.assertEqual(audit.application_overrides(self.root)['secrets']['status'],'EXPLICIT_SOURCE_DEFAULTS')
        for relative,body in consumers.items():
            with self.subTest(source=relative):
                path=self.root/relative
                path.write_text(body.replace('AppSecureStorage(', 'FlutterSecureStorage(')
                                + '\nvoid unrelated() { AppSecureStorage(); }')
                report=audit.application_overrides(self.root)['secrets']
                self.assertEqual(report['status'],'MISSING_OR_UNKNOWN_OH_DEFAULT')
                self.assertFalse(next(row for row in report['consumers'] if row['source']==relative)['explicitAdapterDefault'])
                path.write_text(body)
        path=self.root/'app/lib/state/settings_state.dart'
        path.write_text('class SettingsController { void unused() { const _secure = AppSecureStorage(); } } class Unrelated { static const _secure = AppSecureStorage(); }')
        self.assertEqual(audit.application_overrides(self.root)['secrets']['status'],'MISSING_OR_UNKNOWN_OH_DEFAULT')

if __name__=='__main__':unittest.main()
