# Self-hosted OTA update server

A ready-to-run Docker Compose deployment of a self-hosted `expo-updates`
server. It is only needed when OTA is turned on: see [`docs/ota.md`](../../docs/ota.md)
for the toggle, the channel model and the publish flow.

## What is unverified here

`docker-compose.yml` and `.env.example` were written from the family's spec
with no network access, so **the image reference and the `EOO_*` variable names
have not been checked against a running server**:

| Item | Value used here | How to confirm |
| --- | --- | --- |
| Image | `ghcr.io/expo-open-ota/expo-open-ota:v2.0.0` | Upstream release page; pick a real tag, never `latest` |
| Variables | `EOO_BASE_URL`, `EOO_STORAGE_MODE`, `EOO_PRIVATE_KEY`, `EOO_TOKENS` | Upstream README's configuration table |
| Health path | `/health` | Upstream README |
| Publish CLI flags | `eoas publish --branch --rollout-percentage --non-interactive` | `npx eoas@<pinned version> publish --help` |

Upstream: <https://github.com/expo-open-ota/expo-open-ota>

Fix this file, `docker-compose.yml`, `.env.example` and the caveat in
`docs/ota.md` together the first time this is deployed for real. If the server
turns out not to fit, the documented fallback is Expo's hosted update service —
see the last section of `docs/ota.md`.

## Run it

```bash
cd deploy/ota
cp .env.example .env
$EDITOR .env          # base url, private key, tokens
docker compose up -d
docker compose logs -f ota
```

`EOO_PRIVATE_KEY` is the private half of the key pair whose certificate is
committed in the app repository (the template's is `certs/expo-updates-cert.pem`).
The template ships a placeholder certificate whose key was discarded: generate
your own pair first (`docs/ota.md`, "Generate your own code-signing key pair"),
or every client will reject every manifest.

## Reverse proxy and TLS

The container binds to `127.0.0.1` only. Terminate TLS in front of it (Caddy,
nginx, Traefik, a cloud load balancer) and forward to that loopback port:

```caddy
updates.example.com {
  reverse_proxy 127.0.0.1:3000
}
```

Two rules the client enforces, so the proxy must not break them:

- `EOO_BASE_URL` and the app's `EXPO_UPDATES_URL` must be byte-identical,
  including scheme and any path prefix. A redirect from `http` to `https`, or
  from a bare host to `www`, shows up as an update that silently never applies.
- The `expo-channel-name` and `expo-runtime-version` request headers must reach
  the server. A proxy that strips unknown headers serves the wrong channel's
  manifest — or none.

## Storage

`EOO_STORAGE_MODE=local` keeps updates in `./data` (the bind mount in
`docker-compose.yml`). `s3` uses the `AWS_*` / `S3_*` variables in `.env` and
works against S3, Cloudflare R2 and MinIO.

## Backup

Back up **both** halves or a rollback is not possible:

1. `./data` (or the S3/R2 bucket). It holds every update an installed client can
   still be asked to download, including the one you would roll back *to*.
2. `.env` — specifically `EOO_PRIVATE_KEY`. Losing the signing key means every
   installed app stops accepting updates until a new store build ships with a
   new certificate. Keep it in the same secret store as the release secrets, not
   only on the host.

```bash
docker compose stop ota
tar czf ota-data-$(date +%F).tar.gz data
docker compose start ota
```
