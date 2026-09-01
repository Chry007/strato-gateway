# Eventual public-edge cutover

This is a future migration, not part of the internal-gateway or Mobikit-bridge tasks.

The target state moves TLS and ports 80/443 to this repository's gateway. Mobikit then becomes an ordinary routed workload on `strato-app-edge`, still served at `/mobikitcrm/` and still owning its data, secrets, releases, private network, and application lifecycle.

Plan the cutover as a coordinated maintenance release:

1. Add public-domain/TLS configuration and 80/443 bindings to a new gateway release, but do not start it while Mobikit owns those ports.
2. Prepare a Mobikit release that removes only its public Caddy role, exposes the Mobikit web service to `strato-app-edge` under a unique alias, and preserves `/mobikitcrm/` behavior and all private state.
3. Back up and verify Mobikit through its own process. Snapshot both current release identities and define an ordered rollback that cannot leave two port owners or no port owner.
4. Under the global gateway lock and Mobikit's own operation lock, stop the old public Caddy, activate the public gateway, activate the Mobikit route, and verify certificates, redirects, health, WebSockets, uploads, and unknown-path 404 behavior with server-side probes.
5. Verify exactly one owner of TCP 80, TCP 443, and UDP 443; no app publishes another public port; all existing app registrations still work.
6. Keep the previous compatible gateway and Mobikit releases until the cutover has passed an observation period. Rollback is a coordinated reverse operation, never an independent `docker compose down -v`.

Before implementation, update both repositories' contracts to assign certificate storage, backup, verification, and compatibility ownership explicitly. Do not reuse Mobikit release files, images, scripts, or Compose project in the shared gateway.
