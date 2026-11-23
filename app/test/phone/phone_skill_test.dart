import 'package:dsh_app/phone/phone_channel.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const sections = PhoneSkillSections(
  entry: 'Open app',
  steps: 'Choose item',
  pitfalls: 'Check selection',
  success: 'Result visible',
  handoff: 'Ask if ambiguous',
);
const origin = {'sessionId': 'session-A', 'taskId': 7};
Map<String, Object?> skill() => {
  'name': 'phone-search',
  'display': 'Search',
  'description': 'Search a list',
  'whenToUse': 'Find an item',
  'apps': ['test.app'],
  'source': 'learned',
  'state': 'trial',
  'uses': 1,
  'recent': ['void'],
  'updatedAt': 100,
  'learnedFrom': origin,
  'body': 'full text',
  'sections': sections.toMap(),
  'history': [90],
};
Map<String, Object?> draft() => {
  'id': 'pending',
  'name': 'phone-search',
  'display': 'Search',
  'description': 'Search a list',
  'whenToUse': 'Find an item',
  'apps': ['test.app'],
  'kind': 'update',
  'target': 'phone-search',
  'baseFingerprint': 'original',
  'sections': sections.toMap(),
  'body': 'full draft',
  'from': origin,
  'createdAt': 101,
  'diff': [
    {'op': '+', 'text': 'Updated step'},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('list, detail and management use the native shapes and preserve edited text', () async {
    final native = FakePhoneNative()..install();
    final channel = PhoneChannel();
    final saved = skill();
    native.skills['phone-search'] = saved;
    native.drafts['pending'] = draft();
    native.legacy['phone-task-old'] = {'name': 'phone-task-old', 'path': 'skills/phone-task-old/SKILL.md'};
    final listing = await channel.listSkills();
    expect(listing.learn, isTrue);
    expect(listing.skills.single.recent, [PhoneSkillOutcome.unscored]);
    expect(listing.drafts.single.diff.single.operation, PhoneSkillDiffOperation.added);
    expect(listing.legacy.single.name, 'phone-task-old');
    expect((await channel.getSkill('phone-search')).history, [90]);
    expect(await channel.setSkillLearning(false), isFalse);
    expect((await channel.listSkills()).learn, isFalse);

    for (final method in ['skills.accept', 'skills.save', 'skills.setEnabled', 'skills.restore']) {
      native.results[method] = saved;
    }
    final accepted = await channel.acceptSkill('pending', edited: sections);
    expect(accepted.learnedFrom!.sessionId, 'session-A');
    expect(native.callsOf('skills.accept').single.arguments, {'draftId': 'pending', 'edited': sections.toMap()});
    await channel.saveSkill(accepted.name, display: 'Edited', sections: sections);
    expect(native.callsOf('skills.save').single.arguments, {
      'name': accepted.name,
      'display': 'Edited',
      'sections': sections.toMap(),
    });
    await channel.setSkillEnabled(accepted.name, false);
    expect(native.callsOf('skills.setEnabled').single.arguments, {'name': accepted.name, 'on': false});
    await channel.deleteSkill(accepted.name);
    expect((await channel.listSkills()).archived, [accepted.name]);
    await channel.restoreSkill(accepted.name);
    await channel.discardSkill('ignored');
    expect(native.callsOf('skills.discard').single.arguments, {'draftId': 'ignored'});
    expect((await channel.listSkills()).drafts, isEmpty);
  });

  test('an update conflict keeps the native detail and the draft', () async {
    final native = FakePhoneNative()..install();
    native.drafts['pending'] = draft();
    native.results['skills.accept'] = {'error': 'changed', 'detail': 'Original was edited.'};
    await expectLater(
      PhoneChannel().acceptSkill('pending'),
      throwsA(
        isA<PhoneSkillException>()
            .having((e) => e.code, 'code', 'changed')
            .having((e) => e.detail, 'detail', 'Original was edited.'),
      ),
    );
    expect(native.drafts.keys, ['pending']);
  });

  test('transport errors keep private native exception text out of the UI', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(phoneMethods, (_) async {
      throw PlatformException(code: 'private-code', message: 'private path');
    });
    addTearDown(() => messenger.setMockMethodCallHandler(phoneMethods, null));
    await expectLater(
      PhoneChannel().listSkills(),
      throwsA(
        isA<PhoneSkillException>()
            .having((e) => e.code, 'code', 'unavailable')
            .having((e) => e.detail, 'detail', isNot(contains('private'))),
      ),
    );
  });

  test('skill events and status share one native listen and keep their own data', () async {
    final native = FakePhoneNative()..install();
    final channel = PhoneChannel();
    final statuses = <PhoneStatus>[];
    final events = <PhoneSkillEvent>[];
    final statusSubscription = channel.statusChanges.listen(statuses.add);
    final eventSubscription = PhoneChannel().skillEvents.listen(events.add);
    await pumpEventQueue(times: 1);
    native.push(phoneStatus(taskActive: true, taskId: 7));
    native.pushSkill({'type': 'skillDraft', 'draft': draft()});
    native.pushSkill({
      'type': 'skillOutcome',
      'display': 'Search',
      'name': 'phone-search',
      'state': 'active',
      'change': 'promoted',
      'from': origin,
    });
    await pumpEventQueue(times: 1);
    expect(statuses.single.task.id, 7);
    expect((events.first as PhoneSkillDraftEvent).draft.from.taskId, 7);
    final outcome = events.last as PhoneSkillOutcomeEvent;
    expect(outcome.from.sessionId, 'session-A');
    expect(outcome.change, PhoneSkillChange.promoted);
    await eventSubscription.cancel();
    expect(native.listening, isTrue);
    await statusSubscription.cancel();
    expect(native.listening, isFalse);
  });
}
