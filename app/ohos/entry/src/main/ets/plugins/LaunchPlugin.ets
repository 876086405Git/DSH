// 启动画面的默认动画（app/lib/launch/launch_state.dart）。首帧要原样画出系统启动页：
// module.json5 的 startWindowIcon 按实际大小居中（launch-page-config.md），底色是
// startWindowBackground。系统启动页自己淡出（200 ms），没有 Android 12+ 的交接。图标总是这一张，
// 系统不能换启动页图标，选了备用图标也一样。自定义启动画面在鸿蒙上隐藏。未在真机核实。
import deviceInfo from '@ohos.deviceInfo';
import image from '@ohos.multimedia.image';
import resourceManager from '@ohos.resourceManager';
import {
  Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { nativeHostState } from '../runtime/NativeHost';

function inactive(): Map<string, Any> {
  const reply: Map<string, Any> = new Map<string, Any>();
  reply.set('active', false);
  return reply;
}

export default class LaunchPlugin implements FlutterPlugin, MethodCallHandler {
  private channel?: MethodChannel;
  private manager?: resourceManager.ResourceManager;
  private readonly wait: number;

  // main() 等着 begin 的回答才画第一帧：读不到图标时宁可没有启动画面。
  constructor(wait: number = 600) { this.wait = wait; }

  getUniqueClassName(): string { return 'DshLaunchPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.manager = binding.getApplicationContext().resourceManager;
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/launch');
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(_binding: FlutterPluginBinding): void {
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.manager = undefined;
  }

  private async describe(manager: resourceManager.ResourceManager): Promise<Map<string, Any>> {
    const encoded: Uint8Array = await manager.getMediaByName('icon');
    const source = image.createImageSource(encoded.buffer.slice(encoded.byteOffset, encoded.byteOffset + encoded.byteLength));
    try {
      const map = await source.createPixelMap({ desiredPixelFormat: image.PixelMapFormat.RGBA_8888 });
      try {
        const size = (await map.getImageInfo()).size;
        const pixels = new ArrayBuffer(map.getPixelBytesNumber());
        if (size.width !== size.height || pixels.byteLength !== size.width * size.height * 4) return inactive();
        await map.readPixelsToBuffer(pixels);
        const background = (manager.getColorByNameSync('start_window_background') | 0xFF000000) >>> 0;
        const reply: Map<string, Any> = new Map<string, Any>();
        reply.set('active', true);
        reply.set('sdk', deviceInfo.sdkApiVersion);
        reply.set('systemSplash', false);
        reply.set('systemIcon', true);
        reply.set('iconPx', size.width);
        reply.set('icon', new Uint8Array(pixels));
        reply.set('background', background);
        reply.set('backgroundBottom', background);
        reply.set('dark', manager.getConfigurationSync().colorMode === resourceManager.ColorMode.DARK);
        // 引擎和 App 同进程，由 Dart 启动；已在跑的只有进程活过上一个窗口的情况。关了自动启动时
        // 动画也会播完（最多 1.36 s）才收，这里读不到那个设置。
        reply.set('coldEngine', nativeHostState().phase !== 'running');
        return reply;
      } finally { await map.release(); }
    } finally { await source.release(); }
  }

  private answer(result: MethodResult): void {
    const manager = this.manager;
    let answered = false;
    const reply = (value: Map<string, Any>): void => {
      if (answered) return;
      answered = true;
      result.success(value);
    };
    setTimeout((): void => reply(inactive()), this.wait);
    if (!manager) { reply(inactive()); return; }
    this.describe(manager).then(reply).catch((): void => reply(inactive()));
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    switch (call.method) {
      case 'begin':
      case 'snapshot':
        this.answer(result);
        return;
      case 'reveal':
        result.success(false);
        return;
      case 'mark':
      case 'done':
        result.success(null);
        return;
      default: result.notImplemented();
    }
  }
}
