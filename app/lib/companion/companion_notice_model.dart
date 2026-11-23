import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'companion_agent_loop.dart';
import 'companion_context.dart';
import 'companion_light.dart';
import 'companion_memory.dart';
import 'companion_notice_channel.dart';
import 'companion_notice_decision.dart';

abstract interface class CompanionNoticeModelTransport {
  bool get configured;
  Future<List<CompanionNoticeDecision>> classify(
    CompanionNoticeBatch batch, {
    required bool Function() current,
    required Future<bool> Function() authorize,
    required bool Function() reserve,
    required String Function(String kind, String value) fingerprint,
  });
  void cancel();
}

/// Reason codes may leave the classifier. Neither provider error bodies nor
/// FormatExceptions (whose source can be the entire model response) may do so.
class CompanionNoticeFailure implements Exception {
  const CompanionNoticeFailure(this.code);
  final String code;
}

String companionNoticeInput(CompanionNoticeBatch batch) =>
    '<untrusted_notices>${companionContextJson({
      'app': batch.appName,
      'level': batch.level.name,
      'items': [
        for (var i = 0; i < batch.items.length; i++) {
            'id': i,
            'segments': [for (final segment in batch.items[i].segments) segment.text],
          },
      ],
    })}</untrusted_notices>';

class CompanionNoticeModel implements CompanionNoticeModelTransport {
  CompanionNoticeModel({
    required this.owner,
    required this.client,
    required this.apiKey,
    required this.profile,
    required this.defaultPersona,
    this.onUsage,
    this.onUsageSettled,
    this.loadPrompt = _prompt,
  });

  final CompanionMemoryOwner owner;
  final http.Client Function() client;
  final String Function() apiKey, defaultPersona;
  final CompanionContextProfile Function() profile;
  final void Function(CompanionUsage)? onUsage;
  final void Function(Map<String, Object?>, {required bool partial})? onUsageSettled;
  final Future<String> Function() loadPrompt;
  CompanionAgentModelRequest? _active;

  static Future<String> _prompt() => rootBundle.loadString('assets/companion/notice_triage.md');

  @override
  bool get configured => apiKey().trim().isNotEmpty;

  @override
  void cancel() {
    final request = _active;
    if (request == null) return;
    request.client?.close();
    unawaited(request.drain());
  }

  @override
  Future<List<CompanionNoticeDecision>> classify(
    CompanionNoticeBatch batch, {
    required bool Function() current,
    required Future<bool> Function() authorize,
    required bool Function() reserve,
    required String Function(String kind, String value) fingerprint,
  }) async {
    const maxTokens = 1600;
    final prompt = await loadPrompt();
    if (!current() || !await authorize() || !current()) {
      throw const CompanionNoticeFailure('cancelled');
    }
    final key = apiKey().trim();
    if (key.isEmpty) throw const CompanionNoticeFailure('no_key');
    final system = companionContextSystem(profile: profile(), defaultPersona: defaultPersona(), fixedRules: prompt);
    final messages = <Map<String, Object?>>[
      {'role': 'user', 'content': companionNoticeInput(batch)},
    ];
    final body = companionAgentRequestBody(system: system, messages: messages, maxTokens: maxTokens);
    final id = owner.store.reserveRequest(
      category: 'notice',
      provider: 'deepseek',
      model: companionLightModel,
      inputTokens: estimateCompanionMemoryTokens(jsonEncode(body)),
      outputTokens: maxTokens,
    );
    if (id == null) throw const CompanionNoticeFailure('budget');
    final request = _active = CompanionAgentModelRequest(id);
    owner.retainReceipt(request.settled.future);
    try {
      final message = await request.read(
        client: client(),
        apiKey: key,
        system: system,
        messages: messages,
        tools: const [],
        maxTokens: maxTokens,
        isCurrent: current,
        onText: (_) {},
        onSent: () {
          if (!current()) throw const CompanionNoticeFailure('cancelled');
          if (!reserve()) throw const CompanionNoticeFailure('rate_limited');
          owner.store.markRequestSent(id);
          request.sent = true;
        },
        onUsage: (usage) {
          // Persist only recognized numeric usage fields, never arbitrary provider fields.
          final receipt = usage.toJson();
          for (final name in ['start_usage', 'final_usage']) {
            final raw = receipt[name];
            if (raw is Map) {
              receipt[name] = {
                for (final field in [
                  'input_tokens',
                  'cache_read_input_tokens',
                  'cache_creation_input_tokens',
                  'output_tokens',
                ])
                  if (raw[field] is int) field: raw[field],
              };
            }
          }
          receipt['stop_reason'] = switch (usage.stopReason) {
            'end_turn' || 'max_tokens' || 'refusal' || 'tool_use' => usage.stopReason,
            _ => null,
          };
          owner.store.recordUsage(id, receipt);
          owner.store.finishRequest(id, terminal: usage.terminal);
          request.finalized = true;
          owner.changed();
          onUsage?.call(usage);
        },
        onUsageSettled: (values, {required partial}) {
          onUsageSettled?.call({
            for (final entry in values.entries)
              if (entry.value is int) entry.key: entry.value,
          }, partial: partial);
        },
      );
      if (!current()) throw const CompanionNoticeFailure('cancelled');
      if (message == null || message.stopReason != 'end_turn' || message.calls.isNotEmpty) {
        throw const CompanionNoticeFailure('model_response');
      }
      return companionNoticeDecisions(
        message.content.map((block) => block['text'] as String).join(),
        batch,
        fingerprint: fingerprint,
      );
    } on CompanionLightError catch (error) {
      throw CompanionNoticeFailure('model_${error.failure.name}');
    } on FormatException {
      throw const CompanionNoticeFailure('model_response');
    } finally {
      request.client?.close();
      try {
        await request.drain();
      } finally {
        try {
          if (!request.finalized) {
            owner.store.finishRequest(id, terminal: request.sent ? 'cancelled' : 'not_sent');
          }
        } finally {
          _active = null;
          request.settled.complete();
        }
      }
    }
  }
}
