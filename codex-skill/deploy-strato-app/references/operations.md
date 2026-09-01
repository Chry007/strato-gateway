# Application operations

Read this before deploying, verifying, or rolling back an app.

## Entry points

Run the installed skill scripts from the application repository:

```powershell
pwsh -NoProfile -File <skill>/scripts/validate-project.ps1
pwsh -NoProfile -File <skill>/scripts/deploy-app.ps1
pwsh -NoProfile -File <skill>/scripts/verify-app.ps1
pwsh -NoProfile -File <skill>/scripts/rollback-app.ps1 -Release 20260901T120000Z
```

Scaffolding is optional:

```powershell
pwsh -NoProfile -File <skill>/scripts/scaffold-project.ps1 `
  -Slug example -InternalPort 3000 -ReleaseInclude 'package.json,package-lock.json,src'
```

Review the generated Compose file and replace the deliberately failing check-script placeholder with the app's real test/build commands.

## Deploy

The deploy entrypoint validates the manifest, requires a clean branch whose `HEAD` equals its freshly fetched upstream, runs `ops/check-strato.ps1`, checks Git again, and calls the gateway prerequisite check before packaging. It then creates a normal `git archive` containing only `releaseInclude` and transfers it over strict non-interactive SSH to the fixed STRATO host.

The server first calls the stable gateway prerequisite check. Under the global lock and then the app lock it creates the app's stable `releases/`, `ready/`, `data/`, `secrets/`, and `staging/` directories, extracts a new immutable release, validates Compose isolation, builds the release-tagged image, starts the fixed Compose project, and probes the upstream from the gateway container.

Only then does it call the gateway's route helper. It checks public HTTPS behavior from the server and switches `current` only after success. If anything fails after runtime activation, it recreates the previous ready release and route. A failed first deployment removes its route and stops its runtime without deleting volumes or the failed release.

## Verify and roll back

Verification checks the current ready record, Compose model, running release image, absence of host ports and ingress membership, edge alias, internal HTTP, route hash, gateway header, and public HTTPS health.

Rollback selects an exact release already marked ready, starts its retained image with the same stable data/secrets, restores its route settings, verifies internal and public health, and atomically changes `current`. If rollback fails, it restores the original runtime and route.

Code rollback never restores data. Do not use `docker compose down -v`, Docker pruning, or broad recursive deletion.
