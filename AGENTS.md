# Shared STRATO gateway authority

This repository is the sole source and lifecycle authority for the standalone shared application gateway on `root@h2769124.stratoserver.net`.

## In scope

- Compose project `strato-app-gateway`.
- External networks `strato-ingress` and `strato-app-edge`.
- `/var/snap/docker/common/strato-apps/`, except app-owned content below `apps/<slug>/`.
- Gateway releases, the stable `routes/` and `registrations/` directories, and the reusable `deploy-strato-app` Codex skill.

## Protected boundary

Mobikit owns `/var/snap/docker/common/mobikitcrm/`, Compose project `mobikitcrm`, every `mobikitcrm*` Docker resource, `/mobikitcrm/`, and host ports 80/443. Never edit, stop, recreate, attach, detach, reload, or deploy any Mobikit resource from this repository. Read-only identity and health checks are allowed. The later Mobikit bridge is a separate Mobikit release described in `docs/MOBIKIT_BRIDGE_HANDOFF.md`.

Until that bridge exists, this gateway publishes no host ports and `/apps/*` is intentionally not public.

## Required invariants

- Every gateway mutation holds `/var/snap/docker/common/strato-apps/.operation.lock` with `flock`; persistent lock files are never removed or bypassed.
- Gateway releases are immutable beneath `gateway/releases/<yyyyMMddTHHmmssZ>/`; `gateway/current` changes only after verification.
- Generated app routes and registrations stay in the stable `gateway/routes/` and `gateway/registrations/` directories.
- A route change validates the complete candidate Caddy configuration before activation, installs files with atomic renames, reloads only `strato-app-gateway`, verifies behavior, and restores the previous pair on failure.
- The gateway joins both shared external networks, listens only on container port 8080, and has no host port binding.
- Apps may join `strato-app-edge` only through their unique web alias. They never join `strato-ingress`, publish public host ports, use another app's Compose project, or share another app's private network.
- For the authorized central AI integration, a web service with its explicit `com.strato.ai.client` label may additionally join `strato-ai-internal` without aliases. That internal network belongs to the independent `strato-ai-service` project; the app skill only verifies its identity and never creates or mutates it.
- Secrets and persistent data remain server-side outside release directories. Never print secret values or inspect environment contents.
- Never use Docker pruning, broad recursive deletion, recursive synchronization against a server root, or `docker compose down -v`.
- Production verification uses server-side HTTP probes, never a browser.

## Release gate

Run `pwsh -NoProfile -File tests/Run-StaticTests.ps1`. Production deployment additionally requires a clean committed `HEAD`, a real configured upstream remote, and a freshly fetched upstream commit equal to `HEAD`. Do not invent a remote or weaken this gate. Transfer only the committed gateway payload selected by `ops/deploy-strato.ps1`.

When changing the reusable skill, update `codex-skill/deploy-strato-app/`, validate it with the bundled skill validator, run its tests, and install it with `ops/install-global-skill.ps1`. The repository copy is canonical.
