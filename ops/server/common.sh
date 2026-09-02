#!/usr/bin/env bash
set -Eeuo pipefail

readonly STRATO_ROOT="/var/snap/docker/common/strato-apps"
readonly GATEWAY_ROOT="${STRATO_ROOT}/gateway"
readonly GATEWAY_RELEASES="${GATEWAY_ROOT}/releases"
readonly GATEWAY_ROUTES="${GATEWAY_ROOT}/routes"
readonly GATEWAY_REGISTRATIONS="${GATEWAY_ROOT}/registrations"
readonly GATEWAY_STAGING="${GATEWAY_ROOT}/staging"
readonly GLOBAL_LOCK="${STRATO_ROOT}/.operation.lock"
readonly GATEWAY_PROJECT="strato-app-gateway"
readonly FRONT_NETWORK="strato-ingress"
readonly APP_NETWORK="strato-app-edge"
readonly GATEWAY_ALIAS="strato-app-gateway"
readonly GATEWAY_PORT="8080"
readonly CADDY_IMAGE="docker.io/library/caddy:2.10.2-alpine@sha256:d8c17a862962def15cde69863a3a463f25a2664942eafd7bdbf050e9c3116b83"
readonly EXPECTED_HEADER="X-Strato-App-Gateway: strato-app-gateway"

readonly DOCKER_BIN="/snap/bin/docker"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

note() {
  printf '%s\n' "$*" >&2
}

require_root() {
  [[ "$(id -u)" == "0" ]] || die "This helper must run as root."
}

require_runtime() {
  [[ -x "${DOCKER_BIN}" ]] || die "Canonical Snap Docker was not found at ${DOCKER_BIN}."
  command -v flock >/dev/null 2>&1 || die "flock is required."
  command -v realpath >/dev/null 2>&1 || die "realpath is required."
  command -v sha256sum >/dev/null 2>&1 || die "sha256sum is required."
  command -v timeout >/dev/null 2>&1 || die "timeout is required."
  command -v head >/dev/null 2>&1 || die "head is required."
  command -v awk >/dev/null 2>&1 || die "awk is required."
}

validate_release_id() {
  [[ "${1:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "Invalid release identifier."
}

validate_commit() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || die "Invalid Git commit identity."
}

validate_sha256() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]] || die "Invalid SHA-256 identity."
}

validate_slug() {
  local slug="${1:-}"
  [[ "${slug}" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "Slug must match ^[a-z][a-z0-9-]{1,30}$."
  case "${slug}" in
    mobikitcrm|gateway|infra|system) die "Slug is reserved." ;;
  esac
}

validate_port() {
  local port="${1:-}"
  [[ "${port}" =~ ^[0-9]{1,5}$ ]] || die "Port must be numeric."
  (( 10#${port} >= 1 && 10#${port} <= 65535 )) || die "Port must be between 1 and 65535."
}

assert_regular_file() {
  local path="$1"
  [[ -f "${path}" && ! -L "${path}" ]] || die "Expected a regular non-symlink file: ${path}"
}

assert_canonical_dir() {
  local path="$1"
  [[ -d "${path}" && ! -L "${path}" ]] || die "Expected a non-symlink directory: ${path}"
  [[ "$(realpath -e -- "${path}")" == "${path}" ]] || die "Directory is not canonical: ${path}"
}

gateway_http_response() {
  local container_id="$1"
  local request_path="$2"
  [[ "${request_path}" == /* && "${request_path}" != *$'\r'* && "${request_path}" != *$'\n'* && "${request_path}" != *' '* ]] \
    || die "Gateway probe path is invalid."
  (
    set +e
    printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' "${request_path}" \
      | timeout 12 "${DOCKER_BIN}" exec -i "${container_id}" nc -w 10 127.0.0.1 "${GATEWAY_PORT}" \
      | head -c 16384 \
      | awk '{ if (!complete) print } /^\r?$/ { complete=1 } END { if (!complete) exit 2 }'
    probe_status=("${PIPESTATUS[@]}")
    # head intentionally closes a response beyond the inspection cap, so the
    # Docker client may receive SIGPIPE after complete headers were captured.
    (( probe_status[1] == 0 || probe_status[1] == 141 )) || exit "${probe_status[1]}"
    (( probe_status[3] == 0 )) || exit "${probe_status[3]}"
  )
}

ensure_bootstrap_root() {
  # Creating the global lock's parent is the unavoidable first bootstrap action.
  # mkdir is atomic; every subsequent gateway mutation holds the new global lock.
  [[ -d /var/snap/docker/common && ! -L /var/snap/docker/common ]] || die "Snap Docker common root is unavailable."
  [[ ! -L "${STRATO_ROOT}" ]] || die "Shared STRATO root must not be a symlink."
  if [[ ! -e "${STRATO_ROOT}" ]]; then
    install -d -m 0755 -o root -g root "${STRATO_ROOT}"
  fi
  assert_canonical_dir "${STRATO_ROOT}"
}

acquire_global_lock() {
  local wait_seconds="${1:-60}"
  ensure_bootstrap_root
  [[ ! -L "${GLOBAL_LOCK}" ]] || die "Global operation lock must not be a symlink."
  if [[ ! -e "${GLOBAL_LOCK}" ]]; then
    ( umask 077; : > "${GLOBAL_LOCK}" )
  fi
  assert_regular_file "${GLOBAL_LOCK}"
  chmod 0600 "${GLOBAL_LOCK}"
  exec {STRATO_GLOBAL_LOCK_FD}>"${GLOBAL_LOCK}"
  flock -w "${wait_seconds}" "${STRATO_GLOBAL_LOCK_FD}" || die "Timed out waiting for the global STRATO operation lock."
  export STRATO_GLOBAL_LOCK_FD
}

use_inherited_or_acquire_global_lock() {
  local inherited_fd="${STRATO_GLOBAL_LOCK_FD:-}"
  if [[ -n "${inherited_fd}" ]]; then
    [[ "${inherited_fd}" =~ ^[0-9]+$ ]] || die "Invalid inherited global lock descriptor."
    [[ -e "/proc/$$/fd/${inherited_fd}" ]] || die "Inherited global lock descriptor is not open."
    assert_regular_file "${GLOBAL_LOCK}"
    [[ "$(readlink -f -- "/proc/$$/fd/${inherited_fd}")" == "$(realpath -e -- "${GLOBAL_LOCK}")" ]] \
      || die "Inherited descriptor does not reference the global STRATO lock."
    flock -n "${inherited_fd}" || die "Inherited global lock descriptor is not locked."
  else
    acquire_global_lock 60
  fi
}

ensure_gateway_layout() {
  install -d -m 0755 -o root -g root \
    "${GATEWAY_ROOT}" "${GATEWAY_RELEASES}" "${GATEWAY_ROUTES}" \
    "${GATEWAY_REGISTRATIONS}" "${GATEWAY_STAGING}" "${STRATO_ROOT}/apps"
  install -d -m 0700 -o root -g root "${STRATO_ROOT}/incoming"
  assert_canonical_dir "${GATEWAY_ROOT}"
  assert_canonical_dir "${GATEWAY_RELEASES}"
  assert_canonical_dir "${GATEWAY_ROUTES}"
  assert_canonical_dir "${GATEWAY_REGISTRATIONS}"
  assert_canonical_dir "${GATEWAY_STAGING}"
}

ensure_network() {
  local name="$1"
  local purpose="$2"
  if "${DOCKER_BIN}" network inspect "${name}" >/dev/null 2>&1; then
    local driver scope labels
    driver="$("${DOCKER_BIN}" network inspect --format '{{.Driver}}' "${name}")"
    scope="$("${DOCKER_BIN}" network inspect --format '{{.Scope}}' "${name}")"
    [[ "${driver}" == "bridge" && "${scope}" == "local" ]] || die "Network ${name} has an unexpected driver or scope."
    labels="$("${DOCKER_BIN}" network inspect --format '{{index .Labels "com.strato.shared"}}|{{index .Labels "com.strato.purpose"}}' "${name}")"
    [[ "${labels}" == "true|${purpose}" ]] || die "Network ${name} is not owned by this gateway contract."
  else
    "${DOCKER_BIN}" network create --driver bridge \
      --label com.strato.shared=true --label "com.strato.purpose=${purpose}" "${name}" >/dev/null
  fi
}

compose_for_release() {
  local release_dir="$1"
  shift
  env GATEWAY_ROOT="${GATEWAY_ROOT}" GATEWAY_RELEASE_DIR="${release_dir}" \
    "${DOCKER_BIN}" compose --project-name "${GATEWAY_PROJECT}" \
      --file "${release_dir}/compose.gateway.yaml" "$@"
}

release_image_ref() {
  local release_dir="$1"
  local image_ref
  image_ref="$(sed -nE 's/^[[:space:]]*image:[[:space:]]*([^[:space:]]+)[[:space:]]*$/\1/p' "${release_dir}/compose.gateway.yaml")"
  [[ "$(printf '%s\n' "${image_ref}" | sed '/^$/d' | wc -l)" == "1" ]] || die "Release must declare exactly one gateway image."
  [[ "${image_ref}" =~ ^docker\.io/library/caddy:[a-zA-Z0-9._-]+@sha256:[0-9a-f]{64}$ ]] || die "Release Caddy image is not digest-pinned."
  printf '%s\n' "${image_ref}"
}

gateway_container_id() {
  local ids
  ids="$("${DOCKER_BIN}" ps -aq \
    --filter "label=com.docker.compose.project=${GATEWAY_PROJECT}" \
    --filter 'label=com.docker.compose.service=gateway')"
  [[ "$(printf '%s\n' "${ids}" | sed '/^$/d' | wc -l)" == "1" ]] || die "Expected exactly one gateway container."
  printf '%s\n' "${ids}"
}

resolve_release_dir() {
  local release_id="$1"
  validate_release_id "${release_id}"
  local candidate="${GATEWAY_RELEASES}/${release_id}"
  assert_canonical_dir "${candidate}"
  printf '%s\n' "${candidate}"
}

resolve_current_release() {
  [[ -L "${GATEWAY_ROOT}/current" ]] || die "Gateway current link is missing."
  local resolved
  resolved="$(realpath -e -- "${GATEWAY_ROOT}/current")"
  [[ "${resolved}" =~ ^${GATEWAY_RELEASES}/[0-9]{8}T[0-9]{6}Z$ ]] || die "Gateway current link escapes the releases directory."
  assert_canonical_dir "${resolved}"
  printf '%s\n' "${resolved}"
}

switch_current_release() {
  local release_dir="$1"
  local release_id
  release_id="$(basename -- "${release_dir}")"
  validate_release_id "${release_id}"
  [[ "${release_dir}" == "${GATEWAY_RELEASES}/${release_id}" ]] || die "Refusing a non-canonical release path."
  if [[ -e "${GATEWAY_ROOT}/current.next" || -L "${GATEWAY_ROOT}/current.next" ]]; then
    rm -f -- "${GATEWAY_ROOT}/current.next"
  fi
  ln -s "releases/${release_id}" "${GATEWAY_ROOT}/current.next"
  mv -Tf -- "${GATEWAY_ROOT}/current.next" "${GATEWAY_ROOT}/current"
}

mobikit_fingerprint() {
  local ids id
  ids="$("${DOCKER_BIN}" ps -aq --filter 'label=com.docker.compose.project=mobikitcrm' | sort)"
  [[ -n "${ids}" ]] || die "Mobikit containers were not found."
  while IFS= read -r id; do
    [[ -n "${id}" ]] || continue
    "${DOCKER_BIN}" inspect --format '{{.Id}} {{.Image}}' "${id}"
  done <<< "${ids}" | sort | sha256sum | awk '{print $1}'
}

assert_mobikit_public_owner() {
  local caddy_id
  caddy_id="$("${DOCKER_BIN}" ps -q \
    --filter 'label=com.docker.compose.project=mobikitcrm' \
    --filter 'label=com.docker.compose.service=caddy')"
  [[ "$(printf '%s\n' "${caddy_id}" | sed '/^$/d' | wc -l)" == "1" ]] || die "Mobikit Caddy is not uniquely running."
  local bindings
  bindings="$("${DOCKER_BIN}" port "${caddy_id}")"
  grep -Eq '^80/tcp -> ' <<< "${bindings}" || die "Mobikit Caddy no longer owns TCP 80."
  grep -Eq '^443/tcp -> ' <<< "${bindings}" || die "Mobikit Caddy no longer owns TCP 443."
  grep -Eq '^443/udp -> ' <<< "${bindings}" || die "Mobikit Caddy no longer owns UDP 443."
}

sha256_file() {
  sha256sum -- "$1" | awk '{print $1}'
}
