/// 提示词增强：两条路由，两套宿主各一条路径。
///
/// * 本机引擎 —— dsh-go 桥：
///   `GET /dsh-go/v1/prompt-enhance/status`、`POST /dsh-go/v1/prompt-enhance`。
/// * 远程主机 —— 桌面版 `dsh-prompt-enhance` 插件：
///   `GET /dsh-prompt-enhance/status`、`POST /dsh-prompt-enhance/enhance`。
///
/// 两套的请求体与响应体结构相同（`{ok, error:{code,message}}`），所以客户端按载体
/// 类型挑路径、失败再换另一套，而不是让远程主机拿到 404 就当作功能不存在。
/// 契约见 `docs/design/prompt-enhance.md`。
library;

import 'carrier.dart';
import 'connection.dart';
import 'dsh_go_api.dart';
import 'json.dart';
import 'models.dart';
import 'session_api.dart';

const dshGoPromptEnhancePath = '/dsh-go/v1/prompt-enhance';

/// 桌面版 `dsh-prompt-enhance` 插件的诊断路由。
const desktopPromptEnhanceStatusPath = '/dsh-prompt-enhance/status';

/// 桌面版 `dsh-prompt-enhance` 插件的增强路由。
const desktopPromptEnhanceEnhancePath = '/dsh-prompt-enhance/enhance';

/// 一套增强端点：诊断用 [statusPath]，改写用 [enhancePath]。
class PromptEnhanceEndpoint {
  const PromptEnhanceEndpoint({required this.statusPath, required this.enhancePath});

  final String statusPath;
  final String enhancePath;
}


/// 一次增强里带上的一段会话上文（只放可见正文）。
class PromptEnhanceContextMessage {
  const PromptEnhanceContextMessage({required this.role, required this.text, this.focus = false});

  /// `user` 或 `assistant`。
  final String role;
  final String text;

  /// 上一条消息：Host 会按 4000 字放宽并标「重点」。
  final bool focus;

  Map<String, Object?> toJson() => {
    'role': role,
    'text': text,
    if (focus) 'focus': true,
  };
}

/// `POST /dsh-go/v1/prompt-enhance` 的成功结果。
class PromptEnhanceResult {
  const PromptEnhanceResult({
    required this.text,
    this.unchanged = false,
    this.limit = 0,
    this.compressed = false,
    this.trimmed = false,
    this.inputLength = 0,
    this.outputLength = 0,
    this.elapsedMs = 0,
    this.provider,
    this.model,
    this.contextUsed = false,
    this.contextMessageCount = 0,
  });

  /// 改写后的正文（Host 已保证 `outputLength <= limit`）。
  final String text;

  /// 模型没有改动原文（清理后为空）。
  final bool unchanged;

  /// 本次输出字符数上限。
  final int limit;

  /// 触发过压缩重写。
  final bool compressed;

  /// 最终用了硬截断。
  final bool trimmed;

  final int inputLength;
  final int outputLength;
  final int elapsedMs;
  final String? provider;
  final String? model;

  /// 本次用上了会话上文。
  final bool contextUsed;
  final int contextMessageCount;

  static PromptEnhanceResult fromJson(Object? json) {
    final map = asMapOrEmpty(json);
    final model = asMapOrEmpty(map['model']);
    final context = asMapOrEmpty(map['context']);
    return PromptEnhanceResult(
      text: asString(map['text']) ?? '',
      unchanged: map['unchanged'] == true,
      limit: asInt(map['limit']) ?? 0,
      compressed: map['compressed'] == true,
      trimmed: map['trimmed'] == true,
      inputLength: asInt(map['inputLength']) ?? 0,
      outputLength: asInt(map['outputLength']) ?? 0,
      elapsedMs: asInt(map['elapsedMs']) ?? 0,
      provider: asString(model['provider']),
      model: asString(model['model']),
      contextUsed: context['used'] == true,
      contextMessageCount: asInt(context['messageCount']) ?? 0,
    );
  }
}

/// 增强失败：`code` 与 Host 的错误码一一对应（见设计文档）。
class PromptEnhanceFailure implements Exception {
  const PromptEnhanceFailure(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  /// 宿主还不支持这两条路由。
  bool get unavailable => code == 'ROUTE_NOT_FOUND';

  @override
  String toString() => 'PromptEnhanceFailure($code): $message';
}

extension PromptEnhanceApi on DshClient {
  /// 只有 HTTP 载体才有可寻址的 web 路由。远程隧道（`RemoteTunnelCarrier`）走的是
  /// 一条受限 RPC 通道，没有 HTTP 通道——以前这里硬转 `DshHttpCarrier`，在远程主机上
  /// 直接抛类型错误，用户看到的是「type 'RemoteTunnelCarrier' is not a subtype …」。
  DshConnection? get _promptBridge {
    final current = carrier;
    return current is DshHttpCarrier ? current.connection : null;
  }

  /// 可用的增强端点，按尝试顺序排。没有 HTTP 通道时为空。
  ///
  /// 本机引擎由 dsh-go 桥提供 `/dsh-go/v1/prompt-enhance`；桌面版
  /// `dsh-prompt-enhance` 插件挂在 `/dsh-prompt-enhance`。两者结构相同，只是路径不同。
  List<PromptEnhanceEndpoint> get _promptEnhanceEndpoints {
    if (_promptBridge == null) return const <PromptEnhanceEndpoint>[];
    const bridge = PromptEnhanceEndpoint(
      statusPath: '$dshGoPromptEnhancePath/status',
      enhancePath: dshGoPromptEnhancePath,
    );
    const desktop = PromptEnhanceEndpoint(
      statusPath: desktopPromptEnhanceStatusPath,
      enhancePath: desktopPromptEnhanceEnhancePath,
    );
    // 本机引擎先试桥；其它 HTTP 宿主先试桌面插件。
    return canReachDshGo
        ? const <PromptEnhanceEndpoint>[bridge, desktop]
        : const <PromptEnhanceEndpoint>[desktop, bridge];
  }

  /// 是否存在任一可用的增强端点。
  Future<bool> promptEnhanceAvailable({Duration timeout = const Duration(seconds: 8)}) async {
    // 远程隧道：没有 HTTP 通道，但可以走 `plugin.route.call` 转发到宿主的插件路由。
    if (_promptBridge == null) return _pluginRouteEnhanceAvailable(timeout: timeout);
    final bridge = _promptBridge;
    if (bridge == null) return false;
    for (final endpoint in _promptEnhanceEndpoints) {
      try {
        final response = await bridge.get(endpoint.statusPath, timeout: timeout);
        if (response.statusCode != 200) continue;
        final map = asMap(tryDecodeJson(response.text));
        if (map != null && map['ok'] == true) return true;
      } catch (_) {
        // 换下一种端点；都不可用才返回 false。
      }
    }
    return false;
  }

  /// 把 [text] 改写成结构化提示词。
  ///
  /// [context] 是当前会话最近的可见正文（用户 + 助手正文，不含 reasoning），
  /// [selection] 是本次要用的模型；为空时 Host 用 profile 的默认模型。
  Future<PromptEnhanceResult> promptEnhance({
    required String text,
    List<PromptEnhanceContextMessage> context = const [],
    ModelSelection? selection,
    Duration timeout = const Duration(seconds: 135),
  }) async {
    final body = <String, Object?>{
      'text': text,
      if (context.isNotEmpty)
        'context': [
          for (final message in context) message.toJson(),
        ],
      if (selection != null)
        'model': {
          'provider': selection.provider,
          'model': selection.model,
        },
    };
    PromptEnhanceFailure? lastMissing;
    final bridge = _promptBridge;
    if (bridge == null) {
      // 远程隧道没有 HTTP 通道，但宿主能转发单个白名单插件路由：走 `plugin.route.call`。
      return _pluginRouteEnhance(body, timeout: timeout);
    }
    for (final endpoint in _promptEnhanceEndpoints) {
      final response = await bridge.postJson(endpoint.enhancePath, body, timeout: timeout);
      final map = asMap(tryDecodeJson(response.text));
      if (response.statusCode == 404 && map == null) {
        // 这条路径上没有增强路由：记下来，换下一种端点。
        final detail = response.text.replaceAll(RegExp(r'\s+'), ' ').trim();
        lastMissing = PromptEnhanceFailure(
          'ROUTE_NOT_FOUND',
          'No prompt-enhance route at ${endpoint.enhancePath} '
              '(HTTP 404, body: ${detail.length > 160 ? '${detail.substring(0, 160)}…' : detail})',
          statusCode: response.statusCode,
        );
        continue;
      }
      if (map == null) {
        throw PromptEnhanceFailure(
          'INVALID_BODY',
          'The host returned a body that is not JSON',
          statusCode: response.statusCode,
        );
      }
      if (response.statusCode != 200 || map['ok'] != true) {
        final error = asMapOrEmpty(map['error']);
        throw PromptEnhanceFailure(
          asString(error['code']) ?? 'LLM_ERROR',
          asString(error['message']) ?? 'Prompt enhance failed',
          statusCode: response.statusCode,
        );
      }
      return PromptEnhanceResult.fromJson(map);
    }
    throw lastMissing ??
        const PromptEnhanceFailure('ROUTE_NOT_FOUND', 'No prompt-enhance route on this Host');
  }

  // ---------------------------------------------------------------------------
  // 远程隧道：经 `plugin.route.call` 转发到宿主的插件路由
  //
  // 远程隧道只转发一条受限 RPC 通道，没有 HTTP 通道。ds-harness-remote 允许把单个
  // 白名单插件路由转给宿主的本地 web 服务（原本只给 ds-bot 的 `api/bot`），
  // 这里用同一条通道打 `dsh-prompt-enhance/enhance`。

  /// 远程隧道上转发的那条插件路由。
  static const _remoteEnhanceRoute = 'dsh-prompt-enhance/enhance';

  /// 远程隧道上这条插件路由的 RPC 方法名。
  static const _pluginRouteCall = 'plugin.route.call';

  Future<bool> _pluginRouteEnhanceAvailable({required Duration timeout}) async {
    try {
      final result = await _callPluginRoute(
        const <String, Object?>{'text': ' '},
        timeout: timeout,
      );
      // 只要宿主认识这条路由就会有回应：200 说明可用；4xx 说明路由在但输入被拒
      // （空/纯空格正是这种）；真正的「不可用」是 RPC 本身失败（下面 catch）。
      return result != null;
    } catch (_) {
      return false;
    }
  }

  Future<PromptEnhanceResult> _pluginRouteEnhance(
    Map<String, Object?> body, {
    required Duration timeout,
  }) async {
    final map = await _callPluginRoute(body, timeout: timeout);
    if (map == null) {
      throw const PromptEnhanceFailure(
        'ROUTE_NOT_FOUND',
        'This Host does not forward the prompt-enhance plugin route',
      );
    }
    if (map['ok'] != true) {
      final error = asMapOrEmpty(map['error']);
      throw PromptEnhanceFailure(
        asString(error['code']) ?? 'LLM_ERROR',
        asString(error['message']) ?? 'Prompt enhance failed',
      );
    }
    return PromptEnhanceResult.fromJson(map);
  }

  /// 发一次 `plugin.route.call`；返回宿主的 JSON 响应体，RPC 失败时返回 null。
  Future<Map<String, Object?>?> _callPluginRoute(
    Map<String, Object?> body, {
    required Duration timeout,
  }) async {
    try {
      final result = await rpc.call(
        _pluginRouteCall,
        {'route': _remoteEnhanceRoute, 'body': body},
        timeout,
      );
      // 宿主回 {status, json}：json 就是插件路由的响应体。
      final envelope = asMapOrEmpty(result is Map ? result : null);
      final json = asMap(envelope['json']);
      if (json != null) return json;
      // 少数宿主把结果直接放在 data 里。
      return asMap(result);
    } catch (_) {
      return null;
    }
  }
}
