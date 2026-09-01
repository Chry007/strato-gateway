# Application project contract

Read this when onboarding or changing a non-Mobikit app.

## Files

The app repository needs only:

```text
.strato/deploy.json
Dockerfile
compose.strato.yaml
ops/check-strato.ps1
```

`ops/check-strato.ps1` has no arguments and runs from the repository root. Make it run the application's normal tests and production build. The shared skill supplies deploy, verify, rollback, transfer, locking, and remote lifecycle logic.

## Manifest

```json
{
  "schemaVersion": 1,
  "slug": "example",
  "internalPort": 3000,
  "healthPath": "/health",
  "pathMode": "strip",
  "persistence": "stateless",
  "releaseInclude": [
    ".strato/deploy.json",
    "Dockerfile",
    "compose.strato.yaml",
    "package.json",
    "package-lock.json",
    "src",
    "ops/check-strato.ps1"
  ]
}
```

`pathMode` may be omitted and defaults to `strip`. `releaseInclude` contains literal tracked repository-relative paths, not globs. Include everything the Docker build needs. Never include `.env` files, credentials, keys, production data, uploads, backups, dependency caches, or editor state. Committed build output is allowed when the Dockerfile actually needs it.

Slugs match `^[a-z][a-z0-9-]{1,30}$`; `mobikitcrm`, `gateway`, `infra`, and `system` are reserved. From the slug, the scripts derive the URL, server root, Compose project `strato-<slug>`, app lock, and edge alias `strato-<slug>-web`.

## Compose

Use service `web`, release image `strato-<slug>-web:${STRATO_RELEASE:?}`, and the fixed external network `strato-app-edge` with the sole declared alias `strato-<slug>-web`. Expose the manifest port inside Docker but publish no host ports. Never join `strato-ingress`.

Other services may use only Compose-project private networks. Bind persistent files only from `${STRATO_APP_ROOT}/data` and secret files only from `${STRATO_APP_ROOT}/secrets`; create their required server-side contents separately. Do not set `container_name` or use named volumes. The server validates the rendered Compose model before starting it.

The generic health check is an HTTP request from the gateway container. In `strip` mode the app serves `healthPath`; in `preserve` mode it serves `/apps/<slug><healthPath>`.
