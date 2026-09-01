#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

(( $# == 4 )) || die "Usage: deploy-gateway.sh <archive> <release-id> <commit> <sha256>"
archive_path="$1"
release_id="$2"
source_commit="$3"
expected_archive_sha="$4"

require_root
require_runtime
validate_release_id "${release_id}"
validate_commit "${source_commit}"
validate_sha256 "${expected_archive_sha}"
[[ "${archive_path}" =~ ^/var/tmp/strato-app-gateway-${release_id}-[0-9a-f]{32}\.tar\.gz$ ]] \
  || die "Upload path is outside the allowed gateway staging pattern."
assert_regular_file "${archive_path}"
[[ "$(sha256_file "${archive_path}")" == "${expected_archive_sha}" ]] || die "Uploaded archive hash mismatch."

acquire_global_lock 60
ensure_gateway_layout

mobikit_before="$(mobikit_fingerprint)"
assert_mobikit_public_owner

release_dir="${GATEWAY_RELEASES}/${release_id}"
[[ ! -e "${release_dir}" && ! -L "${release_dir}" ]] || die "Gateway release already exists: ${release_id}"

nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "${nonce}" =~ ^[0-9a-f]{32}$ ]] || die "Could not generate a staging nonce."
staging_dir="${GATEWAY_STAGING}/deploy-${release_id}-${nonce}"
mkdir -m 0700 -- "${staging_dir}"
[[ "$(realpath -e -- "${staging_dir}")" == "${staging_dir}" ]] || die "Staging path is not canonical."

previous_dir=""
if [[ -L "${GATEWAY_ROOT}/current" ]]; then
  previous_dir="$(resolve_current_release)"
fi

runtime_mutated=false
current_switched=false
ready_written=false
completed=false

cleanup_exact_staging() {
  if [[ -n "${staging_dir:-}" && -d "${staging_dir}" && ! -L "${staging_dir}" ]]; then
    local resolved
    resolved="$(realpath -e -- "${staging_dir}")"
    [[ "${resolved}" =~ ^${GATEWAY_STAGING}/deploy-${release_id}-[0-9a-f]{32}$ ]] \
      || die "Refusing unsafe staging cleanup."
    rm -rf -- "${resolved}"
  fi
}

recover() {
  local status=$?
  local recovery_status=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ "${completed}" != true ]]; then
    note "Gateway deployment failed; restoring the previous runtime."
    if [[ "${ready_written}" == true && -f "${release_dir}/RELEASE_READY" ]]; then
      chmod u+w "${release_dir}/RELEASE_READY" 2>/dev/null
      rm -f -- "${release_dir}/RELEASE_READY" || recovery_status=$?
    fi
    if [[ "${runtime_mutated}" == true ]]; then
      if [[ -n "${previous_dir}" ]]; then
        if compose_for_release "${previous_dir}" up --detach --force-recreate --no-build --pull never \
          && "${previous_dir}/server/verify-gateway.sh" --release "${previous_dir}"; then
          if [[ "${current_switched}" == true ]]; then
            ( switch_current_release "${previous_dir}" ) || recovery_status=$?
          fi
        else
          recovery_status=1
        fi
      else
        compose_for_release "${release_dir}" stop gateway || recovery_status=$?
        compose_for_release "${release_dir}" rm --force --stop gateway || recovery_status=$?
        rm -f -- "${GATEWAY_ROOT}/current.next" || recovery_status=$?
        if [[ "${current_switched}" == true ]]; then
          rm -f -- "${GATEWAY_ROOT}/current" || recovery_status=$?
        fi
      fi
    fi
  fi
  if (( recovery_status != 0 )); then
    note "Automatic gateway recovery failed; preserving staging evidence for manual reconciliation."
    exit 70
  fi
  ( cleanup_exact_staging ) || recovery_status=$?
  rm -f -- "${archive_path}" || recovery_status=$?
  if (( recovery_status != 0 )); then
    note "Gateway recovery succeeded but exact staging cleanup failed."
    exit 70
  fi
  exit "${status}"
}
trap recover EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

mapfile -t archive_members < <(tar -tzf "${archive_path}")
(( ${#archive_members[@]} > 0 )) || die "Gateway archive is empty."
for member in "${archive_members[@]}"; do
  case "${member}" in
    gateway/|ops/|ops/server/|gateway/Caddyfile|gateway/compose.gateway.yaml|ops/server/common.sh|ops/server/deploy-gateway.sh|ops/server/verify-gateway.sh|ops/server/rollback-gateway.sh|ops/server/manage-route.sh|ops/server/render-route.sh|ops/server/verify-app-prerequisites.sh) ;;
    *) die "Unexpected gateway archive member: ${member}" ;;
  esac
done

tar --extract --gzip --file "${archive_path}" --directory "${staging_dir}" \
  --no-same-owner --no-same-permissions

for file in \
  gateway/Caddyfile gateway/compose.gateway.yaml \
  ops/server/common.sh ops/server/deploy-gateway.sh ops/server/verify-gateway.sh \
  ops/server/rollback-gateway.sh ops/server/manage-route.sh ops/server/render-route.sh \
  ops/server/verify-app-prerequisites.sh; do
  assert_regular_file "${staging_dir}/${file}"
done

install -d -m 0755 -o root -g root "${release_dir}" "${release_dir}/server"
install -m 0444 -o root -g root "${staging_dir}/gateway/Caddyfile" "${release_dir}/Caddyfile"
install -m 0444 -o root -g root "${staging_dir}/gateway/compose.gateway.yaml" "${release_dir}/compose.gateway.yaml"
for helper in common.sh deploy-gateway.sh verify-gateway.sh rollback-gateway.sh manage-route.sh render-route.sh verify-app-prerequisites.sh; do
  install -m 0555 -o root -g root "${staging_dir}/ops/server/${helper}" "${release_dir}/server/${helper}"
done

ensure_network "${FRONT_NETWORK}" public-ingress
ensure_network "${APP_NETWORK}" application-edge

if ! "${DOCKER_BIN}" image inspect "${CADDY_IMAGE}" >/dev/null 2>&1; then
  "${DOCKER_BIN}" pull "${CADDY_IMAGE}" >/dev/null
fi
image_id="$("${DOCKER_BIN}" image inspect --format '{{.Id}}' "${CADDY_IMAGE}")"
validate_sha256 "${image_id#sha256:}"

config_sha="$( (sha256sum "${release_dir}/Caddyfile" "${release_dir}/compose.gateway.yaml") | sha256sum | awk '{print $1}' )"
cat > "${release_dir}/RELEASE.json" <<EOF
{"schemaVersion":1,"releaseId":"${release_id}","sourceCommit":"${source_commit}","archiveSha256":"${expected_archive_sha}","composeProject":"${GATEWAY_PROJECT}","image":"${CADDY_IMAGE}","imageId":"${image_id}","configSha256":"${config_sha}","frontNetwork":"${FRONT_NETWORK}","appNetwork":"${APP_NETWORK}","listenPort":${GATEWAY_PORT}}
EOF
printf '%s\n' "${image_id}" > "${release_dir}/RELEASE_IMAGE_ID"
printf '%s\n' "${config_sha}" > "${release_dir}/RELEASE_CONFIG_SHA256"
chmod 0444 "${release_dir}/RELEASE.json" "${release_dir}/RELEASE_IMAGE_ID" "${release_dir}/RELEASE_CONFIG_SHA256"

compose_for_release "${release_dir}" config --quiet
"${DOCKER_BIN}" run --rm --network none --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --mount "type=bind,src=${release_dir}/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,src=${GATEWAY_ROUTES},dst=/etc/caddy/routes,readonly" \
  "${CADDY_IMAGE}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

runtime_mutated=true
compose_for_release "${release_dir}" up --detach --force-recreate --no-build --pull never
"${release_dir}/server/verify-gateway.sh" --release "${release_dir}" --allow-unready

printf '%s\n' "${release_id}" > "${release_dir}/RELEASE_READY"
ready_written=true
chmod 0444 "${release_dir}/RELEASE_READY"
current_switched=true
switch_current_release "${release_dir}"

chmod 0555 "${release_dir}/server" "${release_dir}"
"${release_dir}/server/verify-gateway.sh"

mobikit_after="$(mobikit_fingerprint)"
[[ "${mobikit_after}" == "${mobikit_before}" ]] || die "Mobikit container or image identity changed during gateway deployment."

completed=true
trap - EXIT INT TERM HUP
cleanup_exact_staging
rm -f -- "${archive_path}"

printf '{"status":"deployed","releaseId":"%s","commit":"%s","imageId":"%s","serverPath":"%s","composeProject":"%s"}\n' \
  "${release_id}" "${source_commit}" "${image_id}" "${release_dir}" "${GATEWAY_PROJECT}"
