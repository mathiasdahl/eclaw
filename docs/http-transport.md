# HTTP transport and the multibyte request pitfall

eclaw talks to OpenRouter through Emacs’s built-in `url` library
(`url-retrieve-synchronously`). That stack is strict about outgoing request
encoding: **the full HTTP request string must be unibyte** (raw bytes). If any
part is a multibyte Emacs string, the request fails before it leaves Emacs with:

```text
Multibyte text in HTTP request: POST /api/v1/chat/completions HTTP/1.1
```

This error has bitten eclaw more than once. It is easy to reintroduce during
refactors because the JSON body *looks* encoded while headers or helper code
still pass multibyte strings into `url`.

## Why it happens

In modern Emacs, many “ASCII” strings are still **marked multibyte**:

- return values from `getenv` (including `OPENROUTER_API_KEY`)
- string literals and variables such as `eclaw-api-key`
- `json-encode` output when the payload contains Unicode (system prompt em
  dashes, tool descriptions, non-English user text, etc.)

Encoding only the JSON body with `encode-coding-string` is **necessary but not
sufficient**. Header values—especially `Authorization: Bearer …`—must be
unibyte too. When multibyte header values are concatenated into the request,
`url-http-create-request` rejects the whole message.

Symptoms:

- fails on the first chat turn, even for an English-only user prompt
- error appears in `*eclaw*` as `Error: Multibyte text in HTTP request: …`
- no HTTP status code from OpenRouter (the request never completes)

## The fix

Before calling `url-retrieve-synchronously`, encode **both**:

1. the POST body (`json-encode` → unibyte UTF-8), and  
2. every header **value** (unibyte UTF-8; header names stay ASCII).

Use `Content-Type: application/json; charset=utf-8`.

## Central functions (do not bypass)

All outgoing POST traffic must go through this chain:

```text
eclaw-chat / eclaw-send-request
  → eclaw-post-completion-request
    → eclaw--http-post          ; sets url-request-* only here
      → eclaw--utf8-unibyte-string
      → eclaw--http-unibyte-headers
      → eclaw--assert-http-unibyte-p
      → url-retrieve-synchronously
    → eclaw-get-response
```

| Function | Role |
|----------|------|
| `eclaw--http-post` | **Single gate** for `url-request-method`, `url-request-data`, `url-request-extra-headers` |
| `eclaw--utf8-unibyte-string` | Encode any string as unibyte UTF-8 bytes |
| `eclaw--http-unibyte-headers` | Map header alist values through the encoder |
| `eclaw--assert-http-unibyte-p` | Internal check: body and headers are unibyte before send |
| `eclaw-post-completion-request` | OpenRouter chat completions POST (public transport API) |
| `eclaw-send-request` | Build messages → payload → POST (convenience wrapper) |

**Do not** set `url-request-data` or `url-request-extra-headers` anywhere else
in eclaw. If you add another HTTP endpoint later, extend `eclaw--http-post` or
call it from a sibling wrapper—do not duplicate `url-retrieve-synchronously`
with raw strings.

## Checklist when touching HTTP code

- [ ] New POST path goes through `eclaw--http-post`
- [ ] No direct assignment to `url-request-data` / `url-request-extra-headers`
- [ ] Header values built with `concat`, `getenv`, or user/model text are encoded
- [ ] Body is passed as a normal string; `eclaw--http-post` handles encoding
- [ ] Smoke-test `M-x eclaw-agent-chat` after transport changes (any prompt)

## Related notes

- Response bodies are decoded in `eclaw-get-response` with `decode-coding-region`
  and `'utf-8` (separate concern from outgoing encoding).
- JSONL logging (`eclaw-append-json-log`) writes to disk only; it does not use
  `url`.
- When eclaw is split into `eclaw-http.el`, keep `eclaw--http-post` and the
  encoding helpers in that file as the only outbound HTTP surface.
