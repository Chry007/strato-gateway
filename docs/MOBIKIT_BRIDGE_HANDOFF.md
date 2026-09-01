# Mobikit bridge handoff

This is a later, separate Mobikit task. Do not perform it from the shared-gateway repository.

After a pushed gateway release is deployed and `ops/verify-strato.ps1` passes, create a normal versioned Mobikit release in the Mobikit repository that does all of the following through Mobikit's own deployment and rollback process:

1. Declare external network `strato-ingress` and attach only Mobikit's Caddy service to it. Do not attach the Mobikit app or database.
2. Add this route before Mobikit's final 404 fallback, preserving the URI:

   ```caddyfile
   handle /apps/* {
       reverse_proxy strato-app-gateway:8080
   }
   ```

3. Keep Mobikit's `/mobikitcrm/*` routes, certificates, volumes, private networks, Compose identity, and 80/443 bindings unchanged.
4. Extend Mobikit's server-side verifier to prove `/mobikitcrm/` still works, its identities are unchanged, Caddy alone publishes 80/443, Caddy is on `strato-ingress`, an unknown `/apps/*` request reaches the gateway and returns its recognizable header plus 404, and the gateway publishes no host ports.
5. Add these non-secret labels to Mobikit's Caddy service and verify them against the release being deployed: `com.strato.mobikit.bridge.contract=1`, `com.strato.mobikit.bridge.release=<release identity>`, and `com.strato.mobikit.bridge.commit=<40-character commit>`. App preflight uses these labels as the live bridge identity.
6. Add Mobikit release/rollback compatibility evidence so a pre-bridge Mobikit release cannot be selected while gateway registrations exist.
7. Deploy with Mobikit's own clean-commit, pushed-release, backup, verification, and rollback rules.

Only after that release verifies should the bridge task write `/var/snap/docker/common/strato-apps/gateway/INGRESS_READY.json`, atomically under the global lock, with this exact small schema:

```json
{
  "schemaVersion": 1,
  "publicNamespace": "/apps/",
  "gatewayProject": "strato-app-gateway",
  "gatewayRelease": "<yyyyMMddTHHmmssZ>",
  "gatewayCommit": "<40 lowercase hex>",
  "mobikitBridgeRelease": "<Mobikit release identity>",
  "mobikitBridgeCommit": "<40 lowercase hex>",
  "verifiedAt": "<UTC ISO-8601 timestamp>"
}
```

The public proof is an unknown `/apps/*` response with status 404 and header `X-Strato-App-Gateway: strato-app-gateway`. Ordinary app deployment must fail closed until the marker identities and that live proof agree.

Exact next step: open the Mobikit project and implement a dedicated, versioned ingress-bridge release using the route and checks above; do not manually edit the active Mobikit Caddyfile.
