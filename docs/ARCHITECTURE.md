# Shared application gateway architecture

The project deliberately provides one small shared Caddy hop, not a platform. Mobikit remains the public TLS edge during the transitional phase. A later Mobikit release will forward `/apps/*` unchanged over `strato-ingress` to this gateway.

## Traffic and isolation

```text
internet
  -> Mobikit Caddy :80/:443                     (unchanged in this project)
     -> /mobikitcrm/* -> Mobikit application
     -> /apps/*      -> strato-app-gateway:8080 (later bridge)

strato-ingress:  Mobikit Caddy <-> shared gateway only
strato-app-edge: shared gateway <-> one web service per registered app
private network: one Compose-scoped network per app and never shared
```

The gateway has no `ports` mapping. It listens on 8080 inside Docker, adds `X-Strato-App-Gateway: strato-app-gateway`, exposes an internal `/_gateway/health` endpoint, and returns 404 for every unmatched request, including unknown `/apps/*` paths.

## Server layout

```text
/var/snap/docker/common/strato-apps/
|-- .operation.lock
|-- incoming/
|-- apps/<slug>/
|   |-- .operation.lock
|   |-- current -> releases/<release-id>/
|   |-- releases/<release-id>/
|   |-- data/
|   `-- secrets/
`-- gateway/
    |-- current -> releases/<release-id>/
    |-- releases/<release-id>/
    |   |-- Caddyfile
    |   |-- compose.gateway.yaml
    |   |-- server/
    |   |-- RELEASE.json
    |   |-- RELEASE_IMAGE_ID
    |   `-- RELEASE_READY
    |-- routes/<slug>.caddy
    |-- registrations/<slug>.json
    `-- staging/
```

Release identifiers are UTC `yyyyMMddTHHmmssZ`. Release configuration and helpers become read-only after activation. Stable routes and registrations survive gateway release changes and rollback.

## Gateway release transaction

`ops/deploy-strato.ps1` proves a clean pushed Git revision, runs static tests, archives only `gateway/` and `ops/server/` from that commit, verifies the transfer hash, and invokes the uploaded committed server helper. Under the global lock, that helper validates paths, creates or validates the two external networks, validates the complete Caddy configuration with the pinned image, starts the fixed Compose project without implicit build/pull, and runs the independent verifier. Only then does it switch `current` and mark the release ready. Failure restores the previous ready release and leaves the failed candidate for diagnosis.

`ops/rollback-strato.ps1` selects one exact ready release, validates it first, and performs the same locked start/verify/symlink transaction. It never changes routes or application data.

## Route transaction

`ops/server/manage-route.sh` accepts only a canonical slug, the derived alias `strato-<slug>-web`, a numeric container port, `strip` or `preserve`, and a canonical public verification path. It confirms that exactly one running app web container owns the alias on `strato-app-edge`, has no host ports, and is not on `strato-ingress`.

The helper builds a complete candidate route directory in a unique staging directory, pairs every route with one registration, validates the full Caddyfile using the active immutable gateway image, then atomically renames the new route and registration into place and reloads only the gateway. It verifies gateway health, header, unknown-route 404, and the app health path. Any failure restores the prior pair (or removes only a failed first allocation), revalidates, and reloads the previous gateway configuration.

`strip` uses Caddy `handle_path`, so `/apps/example/health` reaches the upstream as `/health`. `preserve` uses `handle`, so the upstream receives `/apps/example/health`. Both modes redirect `/apps/example` to `/apps/example/`.

## Application contract

Each app owns Compose project `strato-<slug>`, server root `apps/<slug>/`, immutable releases, stable data/secrets, app lock, and private Compose-scoped networks. Only its web service joins `strato-app-edge` with alias `strato-<slug>-web`. The reusable skill validates `.strato/deploy.json`, release provenance, Compose isolation, payload selection, tests/build, health, route activation, and code/route rollback. It does not create registries, service discovery, CI, audit containers, or a second public proxy.
