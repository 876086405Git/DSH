# Public lookup host verification

The lookup route is a narrow owner-only entry under the existing companion
bridge. The phone commits the task, revision, attempt and cumulative 2 Search /
2 Fetch limit in its existing SQLite store before using this route. The host
does not verify that remote database or own a second durable task store.

## Executable source/HTTP checks

From `runtime/..`, after replaying the exact lock/pin chain into inspection
sources, run:

```sh
DSH_LOOKUP_SOURCE=/absolute/path/dsh-web-deepseek-api/lib/index.js \
DSH_AUXILIARY_SOURCES=/absolute/path/verified-auxiliary-source-root \
DSH_CHAT_USAGE_SOURCES=/absolute/path/verified-auxiliary-source-root \
DSH_LOOKUP_WINDOW=1 \
node --test --test-timeout=15000 \
  runtime/tests/companion-lookup-source-http.test.mjs \
  runtime/tests/companion-lookup-http.test.mjs \
  runtime/tests/companion-chat-usage-source.test.mjs \
  runtime/tests/companion-auxiliary.test.mjs \
  runtime/tests/companion-route.test.mjs
```

Both source fixtures verify SHA-256 against the repository pins before using
the provider code. Missing environment variables produce explicit skipped
tests, not proof that the source path ran. A successful exit alone is
insufficient; record the passed, failed, cancelled, skipped and todo totals.

The E03 source root additionally contains `dsh-llm/index.lookup-window.js`
and `dsh-llm-deepseek/index.lookup-window.js`, replayed through
`companion-lookup-answer-window.diff`. `DSH_LOOKUP_WINDOW=1` runs the existing
ordinary-chat receipt/retry tests against these same final bytes; it does not
change a production environment or install dependencies.

The lookup tests compose the production HTTP route with the pinned Direct
Search/Fetch plugin, auth, serializer, dispatcher and decoder, using a numeric
loopback HTTP peer. The answer test composes that route with the pinned
LlmRuntime / DeepSeek adapter, serializer and SSE parser against another actual
loopback request. Cordis registration, session registry, owner admission and
credential services are explicit fixture services. The generic pi-ai case
runs its pinned adapter with a fixture `streamSimple`; it does not claim to
observe a real pi-ai network request. No full engine is booted here.

The shared answer prompt is
`tooling/companion/fixtures/public-lookup-answer.json`. Both production modes
compare their actual serialized request to this golden. Fixed test responses
prove transport behavior, not natural-language date, publisher or evidence
reasoning. Paid API, full engine, Dart/Flutter and device results are separate.

## Receipt boundaries

`dispatch` means the real `fetch` function was invoked; it is not a provider
billing confirmation. Generic adapters preserve nullable dispatch and distinct
runtime-normalized usage. The host invokes one prepared handle without retry;
the verified Direct / DeepSeek paths make one physical call, whereas generic
adapter internal physical retries remain unknown.

`provider-result.raw` streams the actual tool JSON once. Fetch page bodies and
answer input sources are not retained in the host receipt Map. GET explicitly
returns `bodyRetained:false`; its Fetch result contains only the requested URL.
Search retains at most five short URL/title/snippet metadata entries. Missing
body after a disconnect cannot establish not-sent, justify another fetch of the
same step, or supply evidence for a task result. The phone preserves the known
HTTP/dispatch facts and treats unavailable body material separately.

Tool `complete` means the JSON payload was fully parsed. Invalid result schema
can therefore be complete with `terminal:invalid_response`; malformed JSON or
interrupted body cannot. Non-2xx retains the known API status without inventing
its raw body. None of these transport states means the business task is done.

Only received fences are enforceable by this host. A phone-only revision change
cannot retroactively stop a call already made before its fence arrived. Old
revision receipts remain old revision receipts. Duplicate IDs and unavailable
prior instances are never proof of a free or unsent earlier request. The
bounded process-local metadata cache rejects new E attempts at capacity and
does not change ordinary chat behavior.

The host bounds the HTTP envelope to 64 KiB and sets answer output to 800 tokens.
Separately, E03 checks the complete serialized DeepSeek model body immediately
before fetch, using the same explicit heuristic as the phone. It rejects an
estimated input above 12k or, when the prepared model exposes a context window,
input plus the full 800 output reserve above that exact preparation's window.
The receipt's `inputBudget` contains only the estimate, output reserve, nullable
window, estimator name and coverage scope; it contains no model body or key.

Generic adapters are checked before handoff over the complete canonical
`system`/`messages` input. Their private final serialization is not observed:
`scope:adapter-input` does not claim `scope:provider-request`. Unknown context
remains null and does not create a provider gate. This heuristic is not exact
tokenization, a guaranteed tokenizer bound, or a billing receipt. The byte
limit is not substituted for token estimation. The phone still checks original
deadline and preserves partial evidence if full pages do not fit.
