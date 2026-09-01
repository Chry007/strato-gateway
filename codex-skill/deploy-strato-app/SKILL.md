---
name: deploy-strato-app
description: Scaffold, deploy, verify, roll back, or troubleshoot a small non-Mobikit Docker application at the owner's shared STRATO /apps/ gateway.
---

# Deploy a STRATO application

Use the scripts bundled with this skill as the deployment implementation. Keep each app project small: it owns `.strato/deploy.json`, `compose.strato.yaml`, `Dockerfile`, and `ops/check-strato.ps1`; it does not copy deployment or server lifecycle scripts into the repository.

## Boundaries

- Never use this workflow for Mobikit, `mobikitcrm`, `/mobikitcrm/`, or any Mobikit resource.
- The fixed host is `root@h2769124.stratoserver.net`. Do not add host, network, gateway, project, alias, or server-root overrides.
- The shared gateway owns route generation and shared networks. Apps invoke its deployed prerequisite and route helpers; they never edit Caddy or reload the gateway themselves.
- Production secrets and persistent data stay below the app's stable server `secrets/` and `data/` directories. Do not display or transfer secrets.
- Do not add a registry, CI framework, service discovery, audit container, custom package format, or per-app copy of this skill's lifecycle scripts.

Read [references/project-contract.md](references/project-contract.md) when scaffolding or changing the manifest/Compose file. Read [references/operations.md](references/operations.md) for a production operation.

## Practical workflow

1. Inspect the app and its `AGENTS.md`. Tailor `ops/check-strato.ps1` to run its actual tests and production build.
2. Scaffold only when needed with `scripts/scaffold-project.ps1`; inspect the Dockerfile to add every required committed path to `releaseInclude`.
3. Run `scripts/validate-project.ps1` locally.
4. Deploy with `scripts/deploy-app.ps1`. It runs the app check, requires a clean pushed commit, archives only `releaseInclude`, and performs the locked server transaction.
5. Verify with `scripts/verify-app.ps1`.
6. Roll back to an exact ready release with `scripts/rollback-app.ps1 -Release <yyyyMMddTHHmmssZ>`.

The deployed gateway bridge must already be ready. If its prerequisite helper rejects the bridge or public edge, stop; this skill never creates or repairs that bridge.

For stateful applications, code rollback deliberately keeps current data. Plan and authorize any schema migration, backup, or data restore in the application project; the generic scripts do not guess at data recovery.

## Report

Return the public URL, release and commit, app server root, Compose project, image, route hash/mode, internal and public health results, and the exact ready rollback release. If the pushed-commit or gateway prerequisite gate stops deployment, say clearly that production was not mutated.
