import 'package:dsh_app/state/chat_state.dart';
import 'package:dsh_app/state/unknown_results.dart';
import 'package:dsh_app/ui/chat/widgets/unknown_results_banner.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Chat extends ChatController {
  _Chat() : super('fixture');

  @override
  ChatState build() => const ChatState(loading: false);

  void show(ChatState value) => state = value;
}

void main() {
  testWidgets('a refused prompt refreshes recovery even when no turn started', (tester) async {
    final chat = _Chat();
    var reads = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatProvider('fixture').overrideWith(() => chat),
          unknownResultsProvider('fixture').overrideWith((ref) async {
            reads++;
            return null;
          }),
        ],
        child: const Directionality(
          textDirection: TextDirection.ltr,
          child: UnknownResultsBanner(sessionId: 'fixture'),
        ),
      ),
    );
    await tester.pump();
    expect(reads, 1);
    chat.show(
      const ChatState(loading: false, error: 'Previous tool results require reconciliation before another step'),
    );
    await tester.pump();
    await tester.pump();
    expect(reads, 2);
    chat.show(
      const ChatState(
        loading: false,
        error: 'Previous tool results require reconciliation before another step',
        title: 'renamed',
      ),
    );
    await tester.pump();
    expect(reads, 2, reason: 'An unrelated rebuild must not poll lifecycle status');
    chat.show(const ChatState(loading: false, running: true));
    await tester.pump();
    expect(reads, 2);
    chat.show(const ChatState(loading: false));
    await tester.pump();
    await tester.pump();
    expect(reads, 3, reason: 'Turn completion keeps its existing refresh');
  });
}
