import {
  Any, FlutterPlugin, FlutterPluginBinding, MethodCall, MethodChannel, MethodResult
} from '@ohos/flutter_ohos';
import { SecretStorageError, SecretVault } from './SecretVault';

// Public HUKS API 26, not an HMS or preferences-backed secret store.
export default class SecretsPlugin implements FlutterPlugin {
  private engine?: FlutterPluginBinding;
  private channel?: MethodChannel;
  private vault?: SecretVault;

  getUniqueClassName(): string { return 'DshSecretsPlugin'; }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    if (this.engine) this.onDetachedFromEngine(this.engine);
    this.engine = binding;
    this.vault = new SecretVault(binding.getApplicationContext().filesDir);
    this.channel = new MethodChannel(binding.getBinaryMessenger(), 'dsh/secrets');
    this.channel.setMethodCallHandler({ onMethodCall: (call: MethodCall, result: MethodResult): void => {
      const current = (): void => {
        if (this.engine !== binding) throw new SecretStorageError('cancelled', '窗口已关闭，凭据操作已取消。');
      };
      if (!['read', 'write', 'delete', 'readAll', 'recover'].includes(call.method)) { result.notImplemented(); return; }
      const work: Promise<Any> = this.invoke(call, current);
      work.then((value: Any): void => {
        try { current(); } catch (error) { this.error(result, error as Error); return; }
        try { result.success(value); } catch (_) { /* Retired transport: do not reply twice. */ }
      }, (error: Error): void => { this.error(result, error); });
    } });
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.engine !== binding) return;
    this.channel?.setMethodCallHandler(null);
    this.channel = undefined;
    this.vault = undefined;
    this.engine = undefined;
  }

  private error(result: MethodResult, error: Error): void {
    try {
      if (error instanceof SecretStorageError) result.error(error.code, error.message, null);
      else result.error('secrets_unavailable', '本机加密凭据暂不可用，请重试。', null);
    } catch (_) { /* A transport failure is not a second logical reply. */ }
  }

  private async invoke(call: MethodCall, current: () => void): Promise<Any> {
    current();
    const vault = this.vault;
    if (!vault) throw new SecretStorageError('secrets_unavailable', '本机加密凭据暂不可用，请重试。');
    if (call.method === 'recover') {
      if (call.argument('confirmed') !== true) {
        throw new SecretStorageError('secrets_invalid', '清除已保存的密钥需要明确确认。');
      }
      await vault.recover(current);
      return null;
    }
    if (call.method === 'readAll') return vault.readAll(current);
    const key: Any = call.argument('key');
    if (typeof key !== 'string') throw new SecretStorageError('secrets_invalid', '凭据参数无效。');
    if (call.method === 'read') return vault.read(key as string, current);
    if (call.method === 'delete') { await vault.delete(key as string, current); return null; }
    if (call.method === 'write') {
      const value: Any = call.argument('value');
      if (typeof value !== 'string') throw new SecretStorageError('secrets_invalid', '凭据参数无效。');
      await vault.write(key as string, value as string, current);
      return null;
    }
    throw new SecretStorageError('secrets_invalid', '凭据方法无效。');
  }
}
