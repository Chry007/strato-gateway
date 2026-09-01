#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

action="${1:-}"
case "${action}" in
  upsert)
    (( $# == 6 )) || die "Usage: manage-route.sh upsert <slug> <alias> <port> <strip|preserve> <public-health-path>"
    slug="$2"
    alias_name="$3"
    port="$4"
    path_mode="$5"
    verify_path="$6"
    ;;
  remove)
    (( $# == 2 )) || die "Usage: manage-route.sh remove <slug>"
    slug="$2"
    alias_name=""
    port=""
    path_mode=""
    verify_path=""
    ;;
  *) die "Route action must be upsert or remove." ;;
esac

require_root
require_runtime
validate_slug "${slug}"

if [[ "${action}" == "upsert" ]]; then
  [[ "${alias_name}" == "strato-${slug}-web" ]] || die "Alias must be the derived strato-<slug>-web value."
  validate_port "${port}"
  [[ "${path_mode}" == "strip" || "${path_mode}" == "preserve" ]] || die "Path mode must be strip or preserve."
  verify_path_pattern="^/apps/${slug}/[A-Za-z0-9._~/:@+-]*$"
  [[ "${verify_path}" =~ ${verify_path_pattern} ]] || die "Verification path is outside the allocated app path."
  [[ "${verify_path}" != *".."* && "${verify_path}" != *"//"* && "${verify_path}" != *"?"* && "${verify_path}" != *"#"* ]] \
    || die "Verification path is not canonical."
fi

use_inherited_or_acquire_global_lock
assert_canonical_dir "${GATEWAY_ROUTES}"
assert_canonical_dir "${GATEWAY_REGISTRATIONS}"
assert_canonical_dir "${GATEWAY_STAGING}"
current_dir="$(resolve_current_release)"
container_id="$(gateway_container_id)"
image_ref="$(release_image_ref "${current_dir}")"
"${current_dir}/server/verify-gateway.sh"

if [[ "${action}" == "upsert" ]]; then
  "${DOCKER_BIN}" network inspect "${APP_NETWORK}" >/dev/null 2>&1 || die "Application edge network is missing."
  matching_container=""
  match_count=0
  while IFS= read -r candidate_id; do
    [[ -n "${candidate_id}" ]] || continue
    aliases="$("${DOCKER_BIN}" inspect --format '{{json (index .NetworkSettings.Networks "strato-app-edge").Aliases}}' "${candidate_id}")"
    if grep -Fq "\"${alias_name}\"" <<< "${aliases}"; then
      matching_container="${candidate_id}"
      ((match_count += 1))
    fi
  done < <("${DOCKER_BIN}" network inspect --format '{{range $id, $_ := .Containers}}{{println $id}}{{end}}' "${APP_NETWORK}")
  (( match_count == 1 )) || die "Expected exactly one container owning alias ${alias_name}."
  [[ "$("${DOCKER_BIN}" inspect --format '{{.State.Running}}' "${matching_container}")" == "true" ]] || die "Registered app web container is not running."
  [[ "$("${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' "${matching_container}")" == "strato-${slug}" ]] \
    || die "Alias owner does not belong to Compose project strato-${slug}."
  [[ "$("${DOCKER_BIN}" inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "${matching_container}")" == "web" ]] \
    || die "Alias owner must be the app's web service."
  app_networks="$("${DOCKER_BIN}" inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "${matching_container}")"
  ! grep -Fxq "${FRONT_NETWORK}" <<< "${app_networks}" || die "Applications must never join strato-ingress."
  [[ -z "$("${DOCKER_BIN}" port "${matching_container}")" ]] || die "Applications must not publish host ports."

  for registration in "${GATEWAY_REGISTRATIONS}"/*.json; do
    [[ -e "${registration}" ]] || break
    assert_regular_file "${registration}"
    other_slug="$(basename -- "${registration}" .json)"
    if [[ "${other_slug}" != "${slug}" ]] && grep -Fq "\"networkAlias\":\"${alias_name}\"" "${registration}"; then
      die "Network alias is already allocated to ${other_slug}."
    fi
  done
fi

live_route="${GATEWAY_ROUTES}/${slug}.caddy"
live_registration="${GATEWAY_REGISTRATIONS}/${slug}.json"
had_route=false
had_registration=false
[[ -f "${live_route}" && ! -L "${live_route}" ]] && had_route=true
[[ -f "${live_registration}" && ! -L "${live_registration}" ]] && had_registration=true
[[ "${had_route}" == "${had_registration}" ]] || die "Route and registration are orphaned for ${slug}."
if [[ "${action}" == "remove" && "${had_route}" != true ]]; then
  die "No route allocation exists for ${slug}."
fi

nonce="$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "${nonce}" =~ ^[0-9a-f]{32}$ ]] || die "Could not generate a route staging nonce."
staging_dir="${GATEWAY_STAGING}/route-${slug}-${nonce}"
candidate_routes="${staging_dir}/routes"
candidate_registrations="${staging_dir}/registrations"
mkdir -m 0700 -- "${staging_dir}"
mkdir -m 0700 -- "${candidate_routes}" "${candidate_registrations}"
[[ "$(realpath -e -- "${staging_dir}")" == "${staging_dir}" ]] || die "Route staging path is not canonical."

cleanup_exact_staging() {
  if [[ -d "${staging_dir}" && ! -L "${staging_dir}" ]]; then
    local resolved
    resolved="$(realpath -e -- "${staging_dir}")"
    [[ "${resolved}" =~ ^${GATEWAY_STAGING}/route-${slug}-[0-9a-f]{32}$ ]] || die "Refusing unsafe route staging cleanup."
    rm -rf -- "${resolved}"
  fi
}
trap cleanup_exact_staging EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

shopt -s nullglob
for route_file in "${GATEWAY_ROUTES}"/*.caddy; do
  assert_regular_file "${route_file}"
  existing_slug="$(basename -- "${route_file}" .caddy)"
  validate_slug "${existing_slug}"
  registration_file="${GATEWAY_REGISTRATIONS}/${existing_slug}.json"
  assert_regular_file "${registration_file}"
  if [[ "${existing_slug}" != "${slug}" ]]; then
    cp -- "${route_file}" "${candidate_routes}/${existing_slug}.caddy"
    cp -- "${registration_file}" "${candidate_registrations}/${existing_slug}.json"
  else
    cp -- "${route_file}" "${staging_dir}/previous.caddy"
    cp -- "${registration_file}" "${staging_dir}/previous.json"
  fi
done
for registration_file in "${GATEWAY_REGISTRATIONS}"/*.json; do
  assert_regular_file "${registration_file}"
  existing_slug="$(basename -- "${registration_file}" .json)"
  assert_regular_file "${GATEWAY_ROUTES}/${existing_slug}.caddy"
done

if [[ "${action}" == "upsert" ]]; then
  "${SCRIPT_DIR}/render-route.sh" "${slug}" "${alias_name}" "${port}" "${path_mode}" > "${candidate_routes}/${slug}.caddy"
  route_hash="$(sha256_file "${candidate_routes}/${slug}.caddy")"
  printf '{"schemaVersion":1,"slug":"%s","publicPath":"/apps/%s/","composeProject":"strato-%s","networkAlias":"%s","internalPort":%s,"pathMode":"%s","routeSha256":"%s"}\n' \
    "${slug}" "${slug}" "${slug}" "${alias_name}" "${port}" "${path_mode}" "${route_hash}" \
    > "${candidate_registrations}/${slug}.json"
fi

# Validate the complete candidate configuration before touching the stable route directory.
"${DOCKER_BIN}" run --rm --network none --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
  --security-opt no-new-privileges \
  --mount "type=bind,src=${current_dir}/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
  --mount "type=bind,src=${candidate_routes},dst=/etc/caddy/routes,readonly" \
  "${image_ref}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

installed=false
completed=false

reload_gateway() {
  compose_for_release "${current_dir}" exec --no-TTY gateway \
    caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
}

restore_previous_pair() {
  local next_route="${GATEWAY_ROUTES}/.${slug}.${nonce}.restore"
  local next_registration="${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.restore"
  if [[ "${had_route}" == true ]]; then
    cp -- "${staging_dir}/previous.caddy" "${next_route}"
    cp -- "${staging_dir}/previous.json" "${next_registration}"
    chmod 0644 "${next_route}" "${next_registration}"
    mv -Tf -- "${next_registration}" "${live_registration}"
    mv -Tf -- "${next_route}" "${live_route}"
  else
    rm -f -- "${live_route}" "${live_registration}"
  fi
}

recover() {
  local status=$?
  local restore_status=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ "${completed}" != true && "${installed}" == true ]]; then
    note "Route verification failed; restoring the previous allocation for ${slug}."
    restore_previous_pair || restore_status=$?
    "${DOCKER_BIN}" run --rm --network none --read-only --cap-drop ALL --cap-add NET_BIND_SERVICE \
      --security-opt no-new-privileges \
      --mount "type=bind,src=${current_dir}/Caddyfile,dst=/etc/caddy/Caddyfile,readonly" \
      --mount "type=bind,src=${GATEWAY_ROUTES},dst=/etc/caddy/routes,readonly" \
      "${image_ref}" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null || restore_status=$?
    reload_gateway || restore_status=$?
    "${current_dir}/server/verify-gateway.sh" || restore_status=$?
  fi
  if (( restore_status != 0 )); then
    note "Automatic route restoration failed; preserving evidence at ${staging_dir}."
    exit 70
  fi
  rm -f -- \
    "${GATEWAY_ROUTES}/.${slug}.${nonce}.next" \
    "${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.next" \
    "${GATEWAY_ROUTES}/.${slug}.${nonce}.restore" \
    "${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.restore"
  cleanup_exact_staging
  exit "${status}"
}
trap recover EXIT

if [[ "${action}" == "upsert" ]]; then
  next_route="${GATEWAY_ROUTES}/.${slug}.${nonce}.next"
  next_registration="${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.next"
  installed=true
  cp -- "${candidate_routes}/${slug}.caddy" "${next_route}"
  cp -- "${candidate_registrations}/${slug}.json" "${next_registration}"
  chmod 0644 "${next_route}" "${next_registration}"
  mv -Tf -- "${next_registration}" "${live_registration}"
  mv -Tf -- "${next_route}" "${live_route}"
else
  installed=true
  mv -- "${live_registration}" "${staging_dir}/removed.json"
  mv -- "${live_route}" "${staging_dir}/removed.caddy"
fi

reload_gateway
"${current_dir}/server/verify-gateway.sh"

if [[ "${action}" == "upsert" ]]; then
  probe_output="$(gateway_http_response "${container_id}" "${verify_path}" 2>&1)"
  probe_status_line="${probe_output%%$'\n'*}"
  probe_status_line="${probe_status_line%$'\r'}"
  [[ "${probe_status_line}" =~ ^HTTP/[0-9.]+[[:space:]]2[0-9]{2}([[:space:]]|$) ]] \
    || die "Routed application health did not return 2xx."
  grep -Eiq '^X-Strato-App-Gateway:[[:space:]]*strato-app-gateway[[:space:]]*$' <<< "${probe_output}" \
    || die "Routed response lacks the gateway header."
else
  set +e
  probe_output="$(gateway_http_response "${container_id}" "/apps/${slug}/" 2>&1)"
  probe_status=$?
  set -e
  [[ "${probe_status}" == "0" ]] || die "Removed-route HTTP probe failed."
  probe_status_line="${probe_output%%$'\n'*}"
  probe_status_line="${probe_status_line%$'\r'}"
  [[ "${probe_status_line}" =~ ^HTTP/[0-9.]+[[:space:]]404([[:space:]]|$) ]] || die "Removed route does not return 404."
  grep -Eiq '^X-Strato-App-Gateway:[[:space:]]*strato-app-gateway[[:space:]]*$' <<< "${probe_output}" \
    || die "Removed-route response lacks the gateway header."
fi

completed=true
trap - EXIT INT TERM HUP
rm -f -- \
  "${GATEWAY_ROUTES}/.${slug}.${nonce}.next" \
  "${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.next" \
  "${GATEWAY_ROUTES}/.${slug}.${nonce}.restore" \
  "${GATEWAY_REGISTRATIONS}/.${slug}.${nonce}.restore"
cleanup_exact_staging
if [[ "${action}" == "upsert" ]]; then
  printf '{"status":"installed","slug":"%s","publicPath":"/apps/%s/","routeSha256":"%s","pathMode":"%s"}\n' \
    "${slug}" "${slug}" "${route_hash}" "${path_mode}"
else
  printf '{"status":"removed","slug":"%s","publicPath":"/apps/%s/"}\n' "${slug}" "${slug}"
fi
