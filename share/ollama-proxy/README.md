# ollama-proxy — a query-only front door for a local Ollama

Optional, and separate from Draugr proper: nothing here imports `lib/common.sh`, reads a Draugr
config or needs a mound. It exists because [`DRAUGR_HOST_PORTS`](../../docs/CONFIG.md) makes it easy
to let a sandbox reach a service on your machine, and Ollama is the service people want first — and
the one with the least to stop them.

## What problem this solves

Ollama has **no authentication and no read-only mode**. Anything that can reach port 11434 can also:

| | |
|---|---|
| `POST /api/pull`, `/api/push` | fetch and publish models over your network |
| `POST /api/create` | build a model — and read local files while doing it |
| `POST /api/copy`, `DELETE /api/delete` | rewrite and destroy what you have installed |
| `POST /api/blobs/<digest>` | arbitrary blob upload |

So "let the agent use my GPU" and "let the agent delete my models" are the same permission. This puts
nginx in front with a default-deny allowlist, and separates them.

## The arrangement

```
Ollama        127.0.0.1:11434    loopback only — nothing off-host can reach it
this proxy    0.0.0.0:11435      the only way in, query-only
your sandbox  DRAUGR_HOST_PORTS="11435"
```

This is **less** exposed than binding Ollama itself to `0.0.0.0`, not more: the management API ends up
with no listener that anything outside the host can reach. If you set `OLLAMA_HOST=0.0.0.0` earlier to
make Ollama reachable from a mound, undo it — this replaces it.

## Use

```bash
sudo apt install nginx          # see the warning below
./ollama-proxy start            # starts, and waits until it actually answers
./ollama-proxy status           # is the proxy up, is Ollama up behind it
./ollama-proxy stop
./ollama-proxy config           # print the rendered config, and validate it
```

Everything is overridable by environment variable: `OLLAMA_PROXY_LISTEN` (default `0.0.0.0`),
`OLLAMA_PROXY_PORT` (`11435`), `OLLAMA_PROXY_UPSTREAM` (`127.0.0.1:11434`), `OLLAMA_PROXY_STATE`
(`$XDG_STATE_HOME/ollama-proxy`), `OLLAMA_PROXY_TEMPLATE`.

> **`apt install nginx` starts a system nginx on port 80** under systemd. That is the distribution's
> doing, not this script's. `sudo systemctl disable --now nginx` if you do not want it — this proxy
> does not use it and does not need it running.

### Starting it automatically

Use the `post-up` hook rather than a config key — it already runs on the host, at every `dr-up`,
and it is trust-checked:

```bash
# .draugr/hooks/post-up
#!/usr/bin/env bash
~/path/to/ollama-proxy start
```

`start` is idempotent and waits for the listener before returning, so it is safe on every start and
will not race a request that follows it.

## It will not disturb another nginx

It runs a **private instance** — its own prefix, config, pid file, logs and temp paths, as an
ordinary user, touching nothing under `/etc/nginx`. Measured on nginx 1.28.3:

- `nginx -T` on this config resolves **zero** references to `/etc/nginx`
- a system instance on `:80` and this one on `:11435` serve **at the same time**
- `-s quit` here stops **only** this one; the system instance keeps serving

The one thing that would couple them is installing a site into `/etc/nginx/sites-enabled/` — shared
master process, and a mistake here would break *their* reload. This deliberately never does that.

## What is allowed

Measured end to end against the real thing:

```
GET  /healthz                200      nginx itself, no upstream — the readiness probe
GET  /api/version            200      POST /api/pull                 403
GET  /api/tags               200      POST /api/create               403
POST /api/chat               200      POST /api/push                 403
POST /v1/chat/completions    200      POST /api/copy                 403
GET  /v1/models              200      DELETE /api/delete             403
                                      POST /api/blobs/sha256:abc     403
GET  /api/chat               403      GET  /api/anything-new-later   403
POST /api/tags               403
```

The last two columns are the point. Methods are enforced, and **an endpoint Ollama has not shipped
yet is refused by default** — the config is an allowlist, so a future release cannot widen it behind
your back.

`/v1/` is passed through whole because that surface carries no management verbs at all: `/v1/models`
answers, `chat/completions`, `completions` and `embeddings` exist as POST, and `/v1/files` is a 404 —
Ollama does not implement the file or fine-tune half of the OpenAI API. If your application speaks
the OpenAI protocol, delete the `/api/` locations and keep only that one: it is a smaller allowlist
to be right about.

Allowing `/api/chat` does not smuggle in downloads. Verified on 0.32.14: a request naming a model
that is not installed returns `{"error":"model '...' not found"}` and does **not** pull it.

## One thing that will bite you

Ollama checks the `Host` header and answers **403** when it does not look local — a defence against
DNS rebinding. nginx's default for a named upstream is the upstream's *name*, which fails that check,
so the config sets `proxy_set_header Host` to the address it is actually connecting to.

Worth knowing because of the order it appears in: while Ollama was still listening on `0.0.0.0` the
same proxied request was allowed. Binding it to loopback — the hardening that makes this proxy worth
having at all — is what exposes the missing header. A stub upstream will not reproduce it either.

## What this does not solve

- **Resource exhaustion.** Every allowed request is legitimate, and an application can still pin your
  GPU indefinitely or repeatedly load your largest model. nginx can rate-limit; it cannot fix this.
- **Which model.** Path filtering cannot see the JSON body, so it cannot restrict one model over
  another. That needs njs, Lua, or a small purpose-written proxy.
- **Prompt content as a channel.** Anything the application can read, it can put in a prompt. That is
  inherent in giving it inference at all.

For a genuinely untrusted application, add a second layer that does not depend on this allowlist
being perfect: Ollama runs as its own user, so making its model tree read-only to that user turns
pull, create and delete into filesystem failures whatever reaches the API. The cost is that you must
flip it back to install a model yourself.
