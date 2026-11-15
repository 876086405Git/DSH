# Bounded TSS personalization requests

Both personalized-image and Cryptex DDI paths use the pinned upstream
`TSSRequest::send`. The local source patch makes this one shared path use:

- `https://gs.apple.com/TSS/controller?action=2`, using the existing `ring` /
  rustls backend with hostname and webpki-root certificate verification;
- one 30-second deadline covering DNS, TCP, TLS, write and response reads, without
  restarting the deadline for each phase;
- at most 1 MiB of received HTTP response bytes, including headers, chunk framing
  and trailers, with a separate 16 KiB header limit;
- checked declared lengths and chunk sizes, rejecting premature EOF, ambiguous
  framing, non-200 status, and invalid UTF-8 before parsing the TSS plist.

The bounded path sends exactly once: it does not follow redirects or fall back
to HTTP. A cap, timeout or transport error follows the existing DDI
`PERSONALIZATION` failure path. A timeout drops the request future and its local
stream; it does not claim that the remote server stops processing a received
request. Other HTTP users retain their existing send/redirect path. Checked
chunk-size arithmetic and rejection of an incomplete zero chunk also apply to
that shared decoder. No dependency or upstream version is changed.

The receive buffer length is capped before append. TLS/library internal buffers,
Vec spare capacity and parsed plist storage are additional memory; the byte cap
is not a claim about a 1 MiB process-memory ceiling. The operational budgets
have not been validated against actual device ticket sizes or network timings.

## HTTPS evidence

Apple's [enterprise-network documentation](https://support.apple.com/en-lamr/101555)
lists `gs.apple.com` on TCP 443 (and, for software installation/restore, also 80).
The public [libtatsu TSS implementation at d8928042](https://github.com/libimobiledevice/libtatsu/blob/d8928042bcbb7048bc87a994d3e84c29eacf2f32/src/tss.c)
selects this exact HTTPS controller URL first. These are documentation/source
evidence of HTTPS support, checked 2026-11-07, not a successful live TSS call.
libtatsu also disables peer-certificate verification and permits HTTP fallbacks;
this patch does neither. Actual Apple TLS-chain compatibility and a successful
DDI ticket remain **UNRUN** device/network validation gates.

## Pure synthetic verification

After `python3 prepare_upstream.py` prepares the hash-verified pinned source:

```sh
cargo test --locked --test tss_http
```

The harness compiles the actual prepared HTTP source and runs in-memory tests
for exact/over-limit fixed and EOF bodies, declared-length overflow/truncation,
chunked framing/truncation, header limits, ambiguous framing, a single virtual
30-second deadline, and stream drop on a stalled-read timeout. The harness has
no TLS feature of its own and does not exercise TLS; the production dependency
is compiled separately with its existing `ring` feature. No server, device,
real pairing, actual TSS submission, model or engine is used.
