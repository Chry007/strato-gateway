#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

release_dir=""
allow_unready=false

while (( $# > 0 )); do
  case "$1" in
    --release)
      (( $# >= 2 )) || die "--release requires a path."
      release_dir="$2"
      shift 2
      ;;
    --allow-unready)
      allow_unready=true
      shift
      ;;
    *) die "Unknown verify argument: $1" ;;
  esac
done

require_root
require_runtime

if [[ -z "${release_dir}" ]]; then
  release_dir="$(resolve_current_release)"
else
  release_id="$(basename -- "${release_dir}")"
  release_dir="$(resolve_release_dir "${release_id}")"
fi

release_id="$(basename -- "${release_dir}")"
validate_release_id "${release_id}"

assert_regular_file "${release_dir}/Caddyfile"
assert_regular_file "${release_dir}/compose.gateway.yaml"
assert_regular_file "${release_dir}/RELEASE.json"
assert_regular_file "${release_dir}/RELEASE_IMAGE_ID"
assert_regular_file "${release_dir}/RELEASE_CONFIG_SHA256"
if [[ "${allow_unready}" != true ]]; then
  assert_regular_file "${release_dir}/RELEASE_READY"
  [[ "$(tr -d '\r\n' < "${release_dir}/RELEASE_READY")" == "${release_id}" ]] || die "Release readiness marker does not match."
fi

assert_canonical_dir "${GATEWAY_ROUTES}"
assert_canonical_dir "${GATEWAY_REGISTRATIONS}"

ensure_network_readonly() {
  local name="$1"
  local purpose="$2"
  "${DOCKER_BIN}" network inspect "${name}" >/dev/null 2>&1 || die "Required network is missing: ${name}"
  [[ "$("${DOCKER_BIN}" network inspect --format '{{.Driver}}/{{.Scope}}' "${name}")" == "bridge/local" ]] \
    || die "Network ${name} is not a local bridge."
  [[ "$("${DOCKER_BIN}" network inspect --format '{{index .Labels "com.strato.shared"}}|{{index .Labels "com.strato.purpose"}}' "${name}")" == "true|${purpose}" ]] \
    || die "Network ${name} does not carry the gateway ownership labels."
}

ensure_network_readonly "${FRONT_NETWORK}" public-ingress
ensure_network_readonly "${APP_NETWORK}" application-edge

expected_config_sha="$(tr -d '\r\n' < "${release_dir}/RELEASE_CONFIG_SHA256")"
validate_sha256 "${expected_config_sha}"
observed_config_sha="$( (sha256sum "${release_dir}/Caddyfile" "${release_dir}/compose.gateway.yaml") | sha256sum | awk '{print $1}' )"
[[ "${observed_config_sha}" == "${expected_config_sha}" ]] || die "Gateway release configuration hash mismatch."

compose_for_release "${release_dir}" config --quiet

container_id="$(gateway_container_id)"
[[ "$("${DOCKER_BIN}" inspect --format '{{.State.Running}}' "${container_id}")" == "true" ]] || die "Gateway container is not running."

for _ in $(seq 1 30); do
  health="$("${DOCKER_BIN}" inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}missing{{end}}' "${container_id}")"
  [[ "${health}" == "healthy" ]] && break
  [[ "${health}" == "unhealthy" ]] && die "Gateway container is unhealthy."
  sleep 2
done
[[ "${health:-missing}" == "healthy" ]] || die "Gateway health deadline expired."

published="$("${DOCKER_BIN}" port "${container_id}")"
[[ -z "${published}" ]] || die "Gateway unexpectedly publishes a host port."

mapfile -t networks < <("${DOCKER_BIN}" inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "${container_id}" | sort)
[[ "${#networks[@]}" == "2" ]] || die "Gateway must join exactly two networks."
[[ "${networks[0]}" == "${APP_NETWORK}" && "${networks[1]}" == "${FRONT_NETWORK}" ]] || die "Gateway network membership is incorrect."

front_aliases="$("${DOCKER_BIN}" inspect --format '{{json (index .NetworkSettings.Networks "strato-ingress").Aliases}}' "${container_id}")"
grep -Fq '"strato-app-gateway"' <<< "${front_aliases}" || die "Gateway front-network alias is missing."

expected_image_id="$(tr -d '\r\n' < "${release_dir}/RELEASE_IMAGE_ID")"
validate_sha256 "${expected_image_id#sha256:}"
live_image_id="$("${DOCKER_BIN}" inspect --format '{{.Image}}' "${container_id}")"
[[ "${live_image_id}" == "${expected_image_id}" ]] || die "Live gateway image ID does not match the release."
[[ "$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${container_id}")" == "$(release_image_ref "${release_dir}")" ]] \
  || die "Live gateway image reference does not match the release."

mounts="$("${DOCKER_BIN}" inspect --format '{{range .Mounts}}{{printf "%s|%s|%t\n" .Source .Destination .RW}}{{end}}' "${container_id}")"
grep -Fqx "${release_dir}/Caddyfile|/etc/caddy/Caddyfile|false" <<< "${mounts}" || die "Gateway Caddyfile mount is incorrect."
grep -Fqx "${GATEWAY_ROUTES}|/etc/caddy/routes|false" <<< "${mounts}" || die "Gateway route mount is incorrect."
[[ "$(printf '%s\n' "${mounts}" | sed '/^$/d' | wc -l)" == "2" ]] || die "Gateway has an unexpected bind or volume mount."

shopt -s nullglob
route_files=("${GATEWAY_ROUTES}"/*.caddy)
registration_files=("${GATEWAY_REGISTRATIONS}"/*.json)
for route_file in "${route_files[@]}"; do
  assert_regular_file "${route_file}"
  slug="$(basename -- "${route_file}" .caddy)"
  validate_slug "${slug}"
  registration_file="${GATEWAY_REGISTRATIONS}/${slug}.json"
  assert_regular_file "${registration_file}"
  route_hash="$(sha256_file "${route_file}")"
  registration_text="$(tr -d '\r\n' < "${registration_file}")"
  registration_pattern="^\{\"schemaVersion\":1,\"slug\":\"${slug}\",\"publicPath\":\"/apps/${slug}/\",\"composeProject\":\"strato-${slug}\",\"networkAlias\":\"(strato-${slug}-web)\",\"internalPort\":([0-9]{1,5}),\"pathMode\":\"(strip|preserve)\",\"routeSha256\":\"${route_hash}\"\}$"
  [[ "${registration_text}" =~ ${registration_pattern} ]] || die "Registration does not match route ${slug}."
  "${release_dir}/server/render-route.sh" "${slug}" "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
    | cmp -s - "${route_file}" || die "Route ${slug} was not generated by the gateway helper."
done
for registration_file in "${registration_files[@]}"; do
  assert_regular_file "${registration_file}"
  slug="$(basename -- "${registration_file}" .json)"
  validate_slug "${slug}"
  assert_regular_file "${GATEWAY_ROUTES}/${slug}.caddy"
done

"${DOCKER_BIN}" exec "${container_id}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

probe() {
  local request_path="$1"
  local expected_status="$2"
  local output status status_line status_pattern
  set +e
  output="$(gateway_http_response "${container_id}" "${request_path}" 2>&1)"
  status=$?
  set -e
  [[ "${status}" == "0" ]] || die "HTTP probe failed for ${request_path}."
  status_line="${output%%$'\n'*}"
  status_line="${status_line%$'\r'}"
  status_pattern="^HTTP/[0-9.]+ ${expected_status}([[:space:]]|$)"
  [[ "${status_line}" =~ ${status_pattern} ]] || die "Unexpected HTTP status for ${request_path}."
  grep -Eiq '^X-Strato-App-Gateway:[[:space:]]*strato-app-gateway[[:space:]]*$' <<< "${output}" \
    || die "Gateway identity header is missing for ${request_path}."
}

probe "/_gateway/health" 200
probe "/apps/__gateway_unknown__/" 404

assert_mobikit_public_owner

printf '{"status":"ok","releaseId":"%s","containerId":"%s","imageId":"%s","networks":["%s","%s"],"hostPorts":[],"routes":%s}\n' \
  "${release_id}" "${container_id}" "${live_image_id}" "${FRONT_NETWORK}" "${APP_NETWORK}" "${#route_files[@]}"
