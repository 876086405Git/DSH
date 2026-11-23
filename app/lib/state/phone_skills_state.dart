import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'phone_state.dart';

/// 手机技能 (docs/design/phone-skills.md §6): the learned skills, the drafts
/// waiting for the person, and the 「从做过的事里学」 switch, as the native side
/// keeps them. A new draft or a promotion / suspension reloads the listing.
class PhoneSkillsController extends AsyncNotifier<PhoneSkillListing> {
  PhoneChannel get _channel => ref.read(phoneChannelProvider);

  @override
  Future<PhoneSkillListing> build() async {
    // Without the native side (other platforms, widget tests) the listing fails here and
    // nothing subscribes to the event channel, which has no handler there either.
    final listing = await _channel.listSkills();
    if (!ref.mounted) return listing;
    final sub = _channel.skillEvents.listen((_) => unawaited(reload()));
    ref.onDispose(sub.cancel);
    return listing;
  }

  Future<void> reload() async {
    final next = await AsyncValue.guard(_channel.listSkills);
    if (ref.mounted) state = next;
  }

  Future<void> setLearn(bool on) async {
    await _channel.setSkillLearning(on);
    await reload();
  }

  Future<PhoneSkill> accept(String draftId, {PhoneSkillSections? edited}) =>
      _then(_channel.acceptSkill(draftId, edited: edited));

  Future<void> discard(String draftId) => _then(_channel.discardSkill(draftId));

  Future<PhoneSkill> save(
    String name, {
    String? display,
    String? description,
    String? whenToUse,
    PhoneSkillSections? sections,
  }) => _then(
    _channel.saveSkill(name, display: display, description: description, whenToUse: whenToUse, sections: sections),
  );

  Future<PhoneSkill> setEnabled(String name, bool on) => _then(_channel.setSkillEnabled(name, on));

  Future<PhoneSkill> restore(String name) => _then(_channel.restoreSkill(name));

  Future<void> delete(String name) => _then(_channel.deleteSkill(name));

  Future<T> _then<T>(Future<T> action) async {
    final result = await action;
    await reload();
    return result;
  }
}

/// Kept for the app's life (not auto-disposed): a discard after 「撤销」 times out, a save or a
/// 「恢复」 still finish when the page or chat that started them is gone.
final phoneSkillsProvider = AsyncNotifierProvider<PhoneSkillsController, PhoneSkillListing>(PhoneSkillsController.new);

/// One skill in full (its five sections and history), for the detail page.
final phoneSkillDetailProvider = FutureProvider.autoDispose.family<PhoneSkill, String>((ref, name) {
  // A change made anywhere (accept, restore, an outcome) reloads the listing; follow it.
  ref.watch(phoneSkillsProvider);
  return ref.read(phoneChannelProvider).getSkill(name);
});

/// Installed apps' names and icons, by the packages a skill names (sorted, joined by commas).
final phoneAppInfoProvider = FutureProvider.autoDispose.family<Map<String, ({String label, Uint8List icon})>, String>(
  (ref, packages) => ref.read(phoneChannelProvider).appInfo(packages.isEmpty ? const [] : packages.split(',')),
);

String appInfoKey(Iterable<String> packages) => (packages.toSet().toList()..sort()).join(',');
