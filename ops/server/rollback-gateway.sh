#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

check_only=false
if [[ "${1:-}" == "--check-only" ]]; then
  check_only=true
  shift
fi
(( $# == 1 )) || die "Usage: rollback-gateway.sh [--check-only] <release-id>"
target_id="$1"

require_root
require_runtime
validate_release_id "${target_id}"
target_dir="$(resolve_release_dir "${target_id}")"
assert_regular_file "${target_dir}/RELEASE_READY"
[[ "$(tr -d '\r\n' < "${target_dir}/RELEASE_READY")" == "${target_id}" ]] || die "Target release is not ready."

target_image="$(release_image_ref "${target_dir}")"
"${DOCKER_BIN}" image inspect "${target_image}" >/dev/null 2>&1 || die "Target release image is not retained locally."
target_image_id="$("${DOCKER_BIN}" image inspect --format '{{.Id}}' "${target_image}")"
[[ "${target_image_id}" == "$(tr -d '\r\n' < "${target_dir}/RELEASE_IMAGE_ID")" ]] || die "Target release image identity mismatch."
assert_regular_file "${target_dir}/RELEASE_CONFIG_SHA256"
expected_config_sha="$(tr -d '\r\n' < "${target_dir}/RELEASE_CONFIG_SHA256")"
validate_sha256 "${expected_config_sha}"
observed_config_sha="$( (sha256sum "${target_dir}/Caddyfile" "${target_dir}/compose.gateway.yaml") | sha256sum | awk '{print $1}' )"
[[ "${observed_config_sha}" == "${expected_config_sha}" ]] || die "Target release configuration identity mismatch."

compose_for_release "${target_dir}" config --quiet
"${DOCKER_BIN}" run --rm --network none --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --mount "type=bind,src=${target_dir}/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,src=${GATEWAY_ROUTES},dst=/etc/caddy/routes,readonly" \
  "${target_image}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

if [[ "${check_only}" == true ]]; then
  printf '{"status":"ready","releaseId":"%s","imageId":"%s"}\n' "${target_id}" "${target_image_id}"
  exit 0
fi

acquire_global_lock 60
current_dir="$(resolve_current_release)"
current_id="$(basename -- "${current_dir}")"
if [[ "${current_id}" == "${target_id}" ]]; then
  "${current_dir}/server/verify-gateway.sh"
  printf '{"status":"unchanged","releaseId":"%s"}\n' "${target_id}"
  exit 0
fi

# Recheck the target and shared routes after acquiring the mutation lock.
target_dir="$(resolve_release_dir "${target_id}")"
assert_regular_file "${target_dir}/RELEASE_READY"
target_image="$(release_image_ref "${target_dir}")"
target_image_id="$("${DOCKER_BIN}" image inspect --format '{{.Id}}' "${target_image}")"
[[ "${target_image_id}" == "$(tr -d '\r\n' < "${target_dir}/RELEASE_IMAGE_ID")" ]] || die "Target release image identity changed."
expected_config_sha="$(tr -d '\r\n' < "${target_dir}/RELEASE_CONFIG_SHA256")"
validate_sha256 "${expected_config_sha}"
observed_config_sha="$( (sha256sum "${target_dir}/Caddyfile" "${target_dir}/compose.gateway.yaml") | sha256sum | awk '{print $1}' )"
[[ "${observed_config_sha}" == "${expected_config_sha}" ]] || die "Target release configuration identity changed."
compose_for_release "${target_dir}" config --quiet
"${DOCKER_BIN}" run --rm --network none --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --mount "type=bind,src=${target_dir}/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,src=${GATEWAY_ROUTES},dst=/etc/caddy/routes,readonly" \
  "${target_image}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

mobikit_before="$(mobikit_fingerprint)"
assert_mobikit_public_owner
runtime_mutated=false
current_switched=false
completed=false

recover() {
  local status=$?
  local recovery_status=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ "${completed}" != true && "${runtime_mutated}" == true ]]; then
    note "Gateway rollback target failed; restoring ${current_id}."
    if compose_for_release "${current_dir}" up --detach --force-recreate --no-build --pull never \
      && "${current_dir}/server/verify-gateway.sh" --release "${current_dir}"; then
      if [[ "${current_switched}" == true ]]; then
        ( switch_current_release "${current_dir}" ) || recovery_status=$?
      fi
    else
      recovery_status=1
    fi
  fi
  if (( recovery_status != 0 )); then
    note "Automatic gateway rollback recovery failed; manual reconciliation is required."
    exit 70
  fi
  exit "${status}"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

runtime_mutated=true
compose_for_release "${target_dir}" up --detach --force-recreate --no-build --pull never
"${target_dir}/server/verify-gateway.sh" --release "${target_dir}"
current_switched=true
switch_current_release "${target_dir}"
"${target_dir}/server/verify-gateway.sh"

mobikit_after="$(mobikit_fingerprint)"
[[ "${mobikit_after}" == "${mobikit_before}" ]] || die "Mobikit container or image identity changed during gateway rollback."

completed=true
trap - EXIT INT TERM HUP
printf '{"status":"rolled-back","fromRelease":"%s","releaseId":"%s","imageId":"%s"}\n' \
  "${current_id}" "${target_id}" "${target_image_id}"
