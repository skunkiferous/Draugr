# ollama-proxy: a query-only front door for a local Ollama

Optional, and separate from Draugr itself. Nothing here imports `lib/common.sh`, reads a Draugr
configuration, or needs a mound. It exists because [`DRAUGR_HOST_PORTS`](../../docs/CONFIG.md) lets
a sandbox reach a service on your machine. Ollama is the first service that people want, and it is
the one with the fewest protections.

## The problem

Ollama has **no authentication and no read-only mode**. Each client that can reach port 11434 can
also do these things:

| | |
|---|---|
| `POST /api/pull`, `/api/push` | get and publish models over your network |
| `POST /api/create` | build a model, and read local files while it does that |
| `POST /api/copy`, `DELETE /api/delete` | change and destroy what you installed |
| `POST /api/blobs/<digest>` | upload of any blob |

Thus "let the agent use my GPU" and "let the agent delete my models" are the same permission. This
puts nginx in front, with a default-deny allowlist, and separates them.

## The layout

```
Ollama        127.0.0.1:11434    loopback only. Nothing off the host can reach it
this proxy    0.0.0.0:11435      the only way in, query-only
your sandbox  DRAUGR_HOST_PORTS="11435"
```

This exposes **less** than an Ollama bound to `0.0.0.0`, not more. Nothing outside the host can
reach a listener for the management API. If you set `OLLAMA_HOST=0.0.0.0` before, so that a mound
can reach Ollama, remove it. This replaces it.

## Use

```bash
sudo apt install nginx          # see the warning below
./ollama-proxy start            # starts, and waits until it really answers
./ollama-proxy status           # is the proxy up, is Ollama up behind it
./ollama-proxy stop
./ollama-proxy config           # print the rendered config, and validate it
```

**It is not on your PATH, on purpose. You did not miss an installation step.** `install.sh` links
`bin/`, and only `bin/`. This tool is optional, does not depend on Draugr, and needs an nginx that
you possibly do not have. Thus a tool called Draugr must not put a generic `ollama-proxy` into your
PATH. For the same reason, `tests/executable-paths.sh` names this file alone. All else in `share/`
is examples, which must *not* be executable.

Thus the messages of Draugr name the full path. If the model does not answer, `dr-doctor` prints
it. If you prefer a short name, link it yourself:

```bash
ln -s "$PWD/ollama-proxy" ~/.local/bin/ollama-proxy
```

Environment variables can override each value: `OLLAMA_PROXY_LISTEN` (default `0.0.0.0`),
`OLLAMA_PROXY_PORT` (`11435`), `OLLAMA_PROXY_UPSTREAM` (`127.0.0.1:11434`), `OLLAMA_PROXY_STATE`
(`$XDG_STATE_HOME/ollama-proxy`), `OLLAMA_PROXY_TEMPLATE`.

> **`apt install nginx` starts a system nginx on port 80** under systemd. The distribution does
> that, not this script. If you do not want it, run `sudo systemctl disable --now nginx`. This proxy
> does not use it, and does not need it.

### Start it automatically

Use the `post-up` hook, not a configuration key. The hook already runs on the host at each `dr-up`,
and Draugr makes sure that it is trusted:

```bash
# .draugr/hooks/post-up
#!/usr/bin/env bash
~/path/to/ollama-proxy start
```

`start` is idempotent (safe to run twice). It waits for the listener before it returns. Thus it is
safe at each start, and a request that comes after it does not race it.

## It does not disturb another nginx

It runs a **private instance** as a normal user, with its own prefix, configuration, pid file, logs,
and temp paths. It touches nothing under `/etc/nginx`. Tests on nginx 1.28.3 showed this:

- `nginx -T` on this configuration finds **zero** references to `/etc/nginx`.
- A system instance on `:80` and this one on `:11435` serve **at the same time**.
- `-s quit` here stops **only** this one. The system instance continues to serve.

Only a site in `/etc/nginx/sites-enabled/` can couple them. Then they share the master process, and
a mistake here breaks the reload of *their* instance. This tool never does that, on purpose.

## What is allowed

A full test against a real Ollama gave:

```
GET  /healthz                200      nginx itself, no upstream: the readiness probe
GET  /api/version            200      POST /api/pull                 403
GET  /api/tags               200      POST /api/create               403
POST /api/chat               200      POST /api/push                 403
POST /v1/chat/completions    200      POST /api/copy                 403
GET  /v1/models              200      DELETE /api/delete             403
POST /v1/messages            200      POST /api/blobs/sha256:abc     403
GET  /api/chat               403      GET  /api/anything-new-later   403
POST /api/tags               403
```

The last two columns are the important part. The methods are enforced, and **the proxy refuses an
endpoint that Ollama did not ship yet**. The configuration is an allowlist, so a future release cannot
make it wider without your knowledge.

`/v1/` passes through whole, because that surface has no management verbs. `/v1/models` answers.
`chat/completions`, `completions`, and `embeddings` exist as POST. `/v1/files` is a 404, because
Ollama does not implement the file or fine-tune half of the OpenAI API. If your application uses the
OpenAI protocol, delete the `/api/` locations, and keep only that one. A smaller allowlist is easier
to keep correct.

That prefix now has a second protocol, so this proxy is more important than it looks. Since Ollama
0.14, `/v1/messages` is **the Messages API of Anthropic**, the endpoint that Claude Code uses. Thus
`location /v1/` already lets it in, and you can point a coding agent directly at this port with
`ANTHROPIC_BASE_URL`. A test on nginx 1.24.0 with Ollama 0.32.14 showed that `POST /v1/messages`
answers 200 through the unchanged allowlist. `/api/pull`, `/api/create`, and `/api/delete` stay 403.

See how that happened. Nobody added a rule for it. The prefix passed through whole, because it had
no management verbs, and a new protocol arrived in it. That is the allowlist as designed. It is also
the limit of its reasoning. "No management verbs today" is a claim about a surface that changes. It
is still true on 0.32.14. Test it again, and do not only trust it.

An allowed `/api/chat` does not let downloads in. A test on 0.32.14 showed that a request for a
model that is not installed returns `{"error":"model '...' not found"}`, and does **not** pull it.

## A trap

Ollama reads the `Host` header. If it does not look local, Ollama answers **403**. That is a defense
against DNS rebinding. For a named upstream, the nginx default is the *name* of the upstream, which
fails that test. Thus the configuration sets `proxy_set_header Host` to the address that it really
connects to.

The order of events is important. While Ollama still listened on `0.0.0.0`, the same proxied request
was allowed. The bind to loopback, the hardening that makes this proxy useful, exposes the missing
header. A stub upstream does not show it either.

## What this does not fix

- **Resource exhaustion.** Each allowed request is legitimate. An application can still keep your
  GPU busy forever, or load your largest model again and again. nginx can rate-limit, but it cannot
  fix this.
- **Which model.** A path filter cannot see the JSON body, so it cannot allow one model and refuse
  another. That needs njs, Lua, or a small proxy written for this purpose.
- **Prompt content as a channel.** The application can put all that it can read into a prompt. That
  is part of each inference access.

For an untrusted application, add a second layer that does not depend on a perfect allowlist. Ollama
runs as its own user. Make its model tree read-only for that user. Then pull, create, and delete fail
in the filesystem, whatever reaches the API. The cost: to install a model yourself, you must change
it back.
