#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

require_root
require_runtime
command -v python3 >/dev/null 2>&1 || die "python3 is required for bridge identity validation."
command -v curl >/dev/null 2>&1 || die "curl is required for server-side public verification."

current_dir="$(resolve_current_release)"
"${current_dir}/server/verify-gateway.sh"

marker="${GATEWAY_ROOT}/INGRESS_READY.json"
assert_regular_file "${marker}"
mapfile -t bridge_fields < <(python3 - "${marker}" <<'PY'
import json, re, sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
expected = {
    "schemaVersion", "publicNamespace", "gatewayProject", "gatewayRelease",
    "gatewayCommit", "mobikitBridgeRelease", "mobikitBridgeCommit", "verifiedAt",
}
if set(data) != expected:
    raise SystemExit("bridge marker fields do not match the contract")
if data["schemaVersion"] != 1 or data["publicNamespace"] != "/apps/" or data["gatewayProject"] != "strato-app-gateway":
    raise SystemExit("bridge marker constants do not match")
if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", data["gatewayRelease"]):
    raise SystemExit("invalid gateway release")
if not re.fullmatch(r"[0-9a-f]{40}", data["gatewayCommit"]):
    raise SystemExit("invalid gateway commit")
if not re.fullmatch(r"[A-Za-z0-9._:-]{1,80}", data["mobikitBridgeRelease"]):
    raise SystemExit("invalid Mobikit bridge release")
if not re.fullmatch(r"[0-9a-f]{40}", data["mobikitBridgeCommit"]):
    raise SystemExit("invalid Mobikit bridge commit")
if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", data["verifiedAt"]):
    raise SystemExit("invalid verification timestamp")
for key in ("gatewayRelease", "gatewayCommit", "mobikitBridgeRelease", "mobikitBridgeCommit"):
    print(data[key])
PY
)
[[ "${#bridge_fields[@]}" == "4" ]] || die "Could not parse the bridge marker."
marker_gateway_release="${bridge_fields[0]}"
marker_gateway_commit="${bridge_fields[1]}"
marker_mobikit_release="${bridge_fields[2]}"
marker_mobikit_commit="${bridge_fields[3]}"

[[ "$(basename -- "${current_dir}")" == "${marker_gateway_release}" ]] || die "Bridge marker points to a different gateway release."
grep -Fq "\"sourceCommit\":\"${marker_gateway_commit}\"" "${current_dir}/RELEASE.json" || die "Bridge marker gateway commit mismatch."

mobikit_caddy_id="$("${DOCKER_BIN}" ps -q \
  --filter 'label=com.docker.compose.project=mobikitcrm' \
  --filter 'label=com.docker.compose.service=caddy')"
[[ "$(printf '%s\n' "${mobikit_caddy_id}" | sed '/^$/d' | wc -l)" == "1" ]] || die "Mobikit Caddy is not uniquely running."
[[ "$("${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.strato.mobikit.bridge.contract"}}' "${mobikit_caddy_id}")" == "1" ]] \
  || die "Mobikit Caddy lacks the bridge contract label."
[[ "$("${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.strato.mobikit.bridge.release"}}' "${mobikit_caddy_id}")" == "${marker_mobikit_release}" ]] \
  || die "Mobikit bridge release label mismatch."
[[ "$("${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.strato.mobikit.bridge.commit"}}' "${mobikit_caddy_id}")" == "${marker_mobikit_commit}" ]] \
  || die "Mobikit bridge commit label mismatch."

set +e
public_headers="$(curl --silent --show-error --max-time 15 --dump-header - --output /dev/null \
  'https://h2769124.stratoserver.net/apps/gateway/__readiness__')"
curl_status=$?
set -e
[[ "${curl_status}" == "0" ]] || die "Public gateway readiness probe failed."
grep -Eiq '^HTTP/[0-9.]+ 404([[:space:]]|$)' <<< "${public_headers}" || die "Public unknown-app probe did not return 404."
grep -Fiq "${EXPECTED_HEADER}" <<< "${public_headers}" || die "Public unknown-app probe did not reach the shared gateway."

printf '{"status":"ready","gatewayRelease":"%s","gatewayCommit":"%s","mobikitBridgeRelease":"%s","mobikitBridgeCommit":"%s"}\n' \
  "${marker_gateway_release}" "${marker_gateway_commit}" "${marker_mobikit_release}" "${marker_mobikit_commit}"
