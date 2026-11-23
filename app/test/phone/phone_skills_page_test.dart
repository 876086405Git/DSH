// 手机技能 (docs/design/phone-skills.md §6): the skills page, a draft's
// 收下 / 不要, and the draft card in the chat the task ran in.
import 'package:dsh_app/ui/chat/widgets/phone_skill_banner.dart';
import 'package:dsh_app/ui/phone/phone_skills_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'support.dart';

const _sections = {
  'entry': '打开微信',
  'steps': '1. 进入对话\n2. 按住说话',
  'pitfalls': '- 松手太快会取消',
  'success': '对话里出现语音条',
  'handoff': '找不到联系人时',
};

Map<String, Object?> _skill({String state = 'trial', int uses = 0}) => {
  'name': 'phone-wechat-voice',
  'display': '微信发语音',
  'description': '在微信里给某人发语音消息',
  'whenToUse': '用户要在微信里发语音时',
  'apps': ['com.tencent.mm'],
  'source': 'learned',
  'state': state,
  'uses': uses,
  'recent': <String>[],
  'updatedAt': 100,
  'sections': _sections,
  'history': <int>[],
};

Map<String, Object?> _draft({String session = 'session-A'}) => {
  'id': 'd1',
  'name': 'phone-wechat-voice',
  'display': '微信发语音',
  'description': '在微信里给某人发语音消息',
  'whenToUse': '用户要在微信里发语音时',
  'apps': ['com.tencent.mm'],
  'kind': 'new',
  'sections': _sections,
  'body': 'full draft',
  'from': {'sessionId': session, 'taskId': 7},
  'createdAt': 101,
};

void main() {
  testWidgets('the page: 从做过的事里学 on by default, a learned skill with its state, turning learning off', (tester) async {
    final native = FakePhoneNative()..skills['phone-wechat-voice'] = _skill(state: 'active', uses: 12);
    await pumpPhone(tester, const PhoneSkillsPage(), native: native);
    expect(find.text('从做过的事里学'), findsOneWidget);
    expect(find.text('微信发语音'), findsOneWidget);
    expect(find.text('常用 · 用了 12 次'), findsOneWidget);
    await tester.tap(find.text('从做过的事里学'));
    await settlePhone(tester);
    expect(native.learn, isFalse);
    expect(find.text('关着时不再起草新技能，已收下的照常用'), findsOneWidget);
  });

  testWidgets('待确认: 收下 accepts the draft natively', (tester) async {
    final native = FakePhoneNative()
      ..drafts['d1'] = _draft()
      ..results['skills.accept'] = _skill();
    await pumpPhone(tester, const PhoneSkillsPage(drafts: true), native: native);
    expect(find.text('待确认 1'), findsOneWidget);
    expect(find.text('DSH 学会了一个新做法'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('phone-skill-draft-accept')));
    await settlePhone(tester);
    expect(native.calls.where((c) => c.method == 'skills.accept'), hasLength(1));
    expect(native.drafts, isEmpty);
    expect(find.text('没有要确认的草稿'), findsOneWidget);
  });

  testWidgets('the chat shows only its own task\'s draft', (tester) async {
    final native = FakePhoneNative()..drafts['d1'] = _draft();
    await pumpPhone(
      tester,
      const Scaffold(
        body: Column(
          children: [
            PhoneSkillBanner(sessionId: 'session-A'),
            PhoneSkillBanner(sessionId: 'session-B'),
          ],
        ),
      ),
      native: native,
    );
    expect(find.text('微信发语音'), findsOneWidget);
    expect(find.byType(PhoneSkillDraftCard), findsOneWidget);
  });
}
