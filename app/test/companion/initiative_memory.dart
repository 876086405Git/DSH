// Page tests use one real SQLite owner and the same clock as the initiative.
import 'dart:io';

import 'package:dsh_app/companion/companion_initiative.dart';
import 'package:dsh_app/companion/companion_local.dart';
import 'package:dsh_app/companion/companion_memory.dart';
import 'package:dsh_client/companion.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:sqlite3/sqlite3.dart';

Override initiativeMemory(CompanionInitiativeClock Function() clock) =>
    companionMemoryOwnerProvider.overrideWith((ref, rootPath) async {
      final memory = CompanionMemoryOwner(
        CompanionMemoryStore(sqlite3.open('$rootPath/memory.sqlite'), nowMilliseconds: () => clock().wallMs),
        CompanionLocal.at(Directory(rootPath)),
        nowMilliseconds: () => clock().wallMs,
      );
      ref.onDispose(memory.dispose);
      return memory;
    });
