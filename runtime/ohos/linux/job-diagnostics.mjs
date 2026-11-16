import { Buffer } from 'node:buffer';
import { TextDecoder } from 'node:util';

// These are bounded stderr observations, not a diagnosis of which peer or
// network operator caused a failure. Never include argv, URLs, credentials or
// arbitrary stderr text in a hint. Job lifecycle and outcome remain unchanged.
const hint = (category, evidence, message) => Object.freeze({ category, evidence, message });
const unknown = hint('unknown', 'none', '命令失败；错误输出不足以确定原因，尚不能归类为 DNS、连接或 TLS 错误。');
const kinds = [
  { hint: hint('dns', 'stderr', '命令输出提示域名解析失败。请检查网络、DNS 或代理设置。'),
    pattern: /could(?: not|n't) resolve (?:host|proxy)\b|temporary failure in name resolution|name or service not known|no address associated with hostname|\blookup [^\r\n]{1,2048}: (?:no such host|server misbehaving|i\/o timeout)\b/i },
  { hint: hint('connection', 'stderr', '命令输出提示无法建立连接或连接超时。请检查网络以及代理地址和端口。'),
    pattern: /failed to connect to\b|\bconnect(?:ion)? (?:timed out|timeout)\b|connection refused|network is unreachable|no route to host|\bdial tcp [^\r\n]{1,2048}: (?:i\/o timeout|connect:)/i },
  { hint: hint('tls-interrupted', 'stderr', '命令输出提示 TLS 连接被中途断开。请检查网络或代理；仅凭此输出无法判断断开方。'),
    pattern: /\b(?:TLS connect error|SSL routines::|SSL:)[^\r\n]{0,2048}\bunexpected eof\b/i },
  { hint: hint('tls-certificate', 'stderr', '命令输出提示 TLS 证书校验失败。请检查设备时间、代理证书和证书配置，不要关闭证书验证。'),
    pattern: /SSL certificate problem|certificate verify failed|CERTIFICATE_VERIFY_FAILED|x509: certificate (?:signed by unknown authority|has expired|is not valid for)|hostname[^\r\n]{0,2048}(?:doesn't|does not) match/i },
];

/** Takes the existing control wire job fields; performs no I/O or env access. */
export function deriveLinuxJobDiagnostic({ state, outcome, stderr } = {}) {
  // UNKNOWN, cancellation and signal termination are distinct facts. A stale
  // TLS-looking tail cannot make an unfinished or cancelled command a failure.
  if (state !== 'settled' || !outcome || outcome.cancelled !== false ||
      outcome.signal !== null || outcome.notStarted === true ||
      !Number.isInteger(outcome.exitCode) || outcome.exitCode < 1 || outcome.exitCode > 255) return null;

  // The producer retains at most 16 KiB. Do not infer a unique error from a
  // partial tail: omitted text could contain an earlier or conflicting cause.
  if (!stderr || stderr.encoding !== 'base64' || typeof stderr.data !== 'string' ||
      stderr.data.length > 21848 || stderr.truncated !== false ||
      !Number.isSafeInteger(stderr.totalBytes) || stderr.totalBytes < 0 || stderr.totalBytes > 16384 ||
      stderr.retainedBytes !== stderr.totalBytes) return unknown;
  const bytes = Buffer.from(stderr.data, 'base64');
  if (bytes.toString('base64') !== stderr.data || bytes.length !== stderr.totalBytes) return unknown;
  let text;
  try { text = new TextDecoder('utf-8', { fatal: true }).decode(bytes); }
  catch { return unknown; }
  const matched = kinds.filter(kind => kind.pattern.test(text));
  return matched.length === 1 ? matched[0].hint : unknown;
}
