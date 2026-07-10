# bearer-openai

A thin, gateway-agnostic OpenAI-compatible client for enterprise LLM gateways
that authenticate with an `Authorization: Bearer <token>` credential instead of
an OpenAI-style API key.

Many enterprise gateways expose an OpenAI-compatible `/chat/completions` surface
but front it with a long-lived, manually-rotated bearer token. The OpenAI SDK
already sends `Authorization: Bearer <api_key>`, so most of the work is just
setting `base_url` and passing the token as `api_key`. This package adds the two
things that bare approach lacks:

1. **Token sourcing** — treats the token as swappable config (constructor arg →
   named env var → fallback `BEARER_OPENAI_TOKEN`), never hard-coded, so
   rotation is a restart, not a code change. Missing token fails at construction.
2. **Loud 401 handling** — a rejected token raises `TokenRejectedError` with an
   actionable "needs manual rotation" message instead of disappearing into a
   generic retry loop.

It is **vendor-neutral by design**: no base URLs, no model identifiers, no
routing logic. The consuming application supplies those.

## Install

```bash
pip install bearer-openai
```

## Usage

```python
from bearer_openai import BearerClient

client = BearerClient(
    base_url="https://api.example-gateway.ai",  # you supply this
    env_var="MY_GATEWAY_TOKEN",                 # optional; falls back to BEARER_OPENAI_TOKEN
)

resp = client.chat_completions_create(
    model="some-model-id",                      # you supply this
    messages=[{"role": "user", "content": "Hello"}],
)
print(resp.choices[0].message.content)
```

`chat_completions_create` wraps `chat.completions.create` and translates HTTP 401
into `TokenRejectedError`. The full OpenAI SDK surface (`client.chat`,
`client.models`, streaming, etc.) remains available for everything else.

An `AsyncBearerClient` with an awaitable `chat_completions_create` is provided
for async callers.

## Errors

- `TokenNotConfiguredError` — no token found at construction time.
- `TokenRejectedError` — gateway returned 401; rotate the token and restart.
- `BearerOpenAIError` — base class for both.

## License

MIT
