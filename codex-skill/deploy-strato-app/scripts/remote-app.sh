#!/usr/bin/env bash
set -Eeuo pipefail

readonly STRATO_ROOT="/var/snap/docker/common/strato-apps"
readonly APPS_ROOT="${STRATO_ROOT}/apps"
readonly INCOMING_ROOT="${STRATO_ROOT}/incoming"
readonly GLOBAL_LOCK="${STRATO_ROOT}/.operation.lock"
readonly GATEWAY_CURRENT="${STRATO_ROOT}/gateway/current"
readonly GATEWAY_ROUTES="${STRATO_ROOT}/gateway/routes"
readonly GATEWAY_REGISTRATIONS="${STRATO_ROOT}/gateway/registrations"
readonly EDGE_NETWORK="strato-app-edge"
readonly INGRESS_NETWORK="strato-ingress"
readonly DOCKER_BIN="/snap/bin/docker"
readonly PUBLIC_ORIGIN="https://h2769124.stratoserver.net"
readonly GATEWAY_HEADER="X-Strato-App-Gateway: strato-app-gateway"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

validate_slug() {
  local value="${1:-}"
  [[ "${value}" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "Invalid app slug."
  case "${value}" in
    mobikitcrm|gateway|infra|system) die "Reserved app slug." ;;
  esac
}

validate_release() {
  [[ "${1:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || die "Invalid release identifier."
}

validate_commit() {
  [[ "${1:-}" =~ ^[0-9a-f]{40}$ ]] || die "Invalid commit identity."
}

validate_hash() {
  [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]] || die "Invalid archive hash."
}

require_runtime() {
  [[ "$(id -u)" == "0" ]] || die "Run this helper as root."
  [[ -x "${DOCKER_BIN}" ]] || die "Canonical Snap Docker is unavailable."
  for command_name in flock realpath sha256sum python3 curl tar; do
    command -v "${command_name}" >/dev/null 2>&1 || die "${command_name} is required."
  done
  [[ -d "${STRATO_ROOT}" && ! -L "${STRATO_ROOT}" ]] || die "Shared STRATO root is unavailable."
  [[ -d "${APPS_ROOT}" && ! -L "${APPS_ROOT}" ]] || die "Shared app root is unavailable."
  [[ -d "${INCOMING_ROOT}" && ! -L "${INCOMING_ROOT}" ]] || die "Shared incoming directory is unavailable."
  [[ -f "${GLOBAL_LOCK}" && ! -L "${GLOBAL_LOCK}" ]] || die "Global operation lock is unavailable."
  [[ -x "${GATEWAY_CURRENT}/server/verify-app-prerequisites.sh" ]] || die "Gateway app prerequisite helper is unavailable."
  [[ -x "${GATEWAY_CURRENT}/server/manage-route.sh" ]] || die "Gateway route helper is unavailable."
}

verify_shared_prerequisites() {
  "${GATEWAY_CURRENT}/server/verify-app-prerequisites.sh" >/dev/null
}

set_app_paths() {
  slug="$1"
  validate_slug "${slug}"
  app_root="${APPS_ROOT}/${slug}"
  releases_root="${app_root}/releases"
  ready_root="${app_root}/ready"
  staging_root="${app_root}/staging"
  data_root="${app_root}/data"
  secrets_root="${app_root}/secrets"
  app_lock="${app_root}/.operation.lock"
  compose_project="strato-${slug}"
  network_alias="strato-${slug}-web"
}

acquire_operation_locks() {
  exec {global_lock_fd}>"${GLOBAL_LOCK}"
  flock -w 60 "${global_lock_fd}" || die "Timed out waiting for the shared STRATO lock."
  export STRATO_GLOBAL_LOCK_FD="${global_lock_fd}"

  [[ ! -L "${app_root}" ]] || die "App root must not be a symlink."
  if [[ ! -e "${app_root}" ]]; then
    install -d -m 0755 -o root -g root "${app_root}"
  fi
  [[ -d "${app_root}" && "$(realpath -e -- "${app_root}")" == "${app_root}" ]] || die "App root is invalid."
  install -d -m 0755 -o root -g root "${releases_root}" "${ready_root}" "${staging_root}"
  install -d -m 0750 -o root -g root "${data_root}"
  install -d -m 0700 -o root -g root "${secrets_root}"
  for directory in "${releases_root}" "${ready_root}" "${staging_root}" "${data_root}" "${secrets_root}"; do
    [[ -d "${directory}" && ! -L "${directory}" && "$(realpath -e -- "${directory}")" == "${directory}" ]] \
      || die "App directory is invalid: ${directory}"
  done
  [[ ! -L "${app_lock}" ]] || die "App lock must not be a symlink."
  if [[ ! -e "${app_lock}" ]]; then
    ( umask 077; : > "${app_lock}" )
  fi
  [[ -f "${app_lock}" && ! -L "${app_lock}" ]] || die "App lock is invalid."
  chmod 0600 "${app_lock}"
  exec {app_lock_fd}>"${app_lock}"
  flock -w 60 "${app_lock_fd}" || die "Timed out waiting for the app lock."
}

resolve_release() {
  local release_id="$1"
  validate_release "${release_id}"
  local path="${releases_root}/${release_id}"
  [[ -d "${path}" && ! -L "${path}" ]] || die "Release does not exist: ${release_id}"
  [[ "$(realpath -e -- "${path}")" == "${path}" ]] || die "Release path is not canonical."
  printf '%s\n' "${path}"
}

current_release_dir() {
  if [[ ! -e "${app_root}/current" && ! -L "${app_root}/current" ]]; then
    return 0
  fi
  [[ -L "${app_root}/current" ]] || die "App current pointer is not a symlink."
  local path
  path="$(realpath -e -- "${app_root}/current")"
  [[ "${path}" =~ ^${releases_root}/[0-9]{8}T[0-9]{6}Z$ ]] || die "App current pointer escapes its release root."
  printf '%s\n' "${path}"
}

switch_current() {
  local release_dir="$1"
  local release_id
  release_id="$(basename -- "${release_dir}")"
  [[ "${release_dir}" == "${releases_root}/${release_id}" ]] || die "Refusing a non-canonical current target."
  rm -f -- "${app_root}/current.next"
  ln -s "releases/${release_id}" "${app_root}/current.next"
  mv -Tf -- "${app_root}/current.next" "${app_root}/current"
}

read_release_manifest() {
  local release_dir="$1"
  local manifest_path="${release_dir}/.strato/deploy.json"
  [[ -f "${manifest_path}" && ! -L "${manifest_path}" ]] || die "Release manifest is missing."
  mapfile -t manifest_fields < <(python3 - "${manifest_path}" "${slug}" <<'PY'
import json, re, sys
from pathlib import Path

path, expected_slug = sys.argv[1:]
data = json.loads(Path(path).read_text(encoding="utf-8-sig"))
if data.get("schemaVersion") != 1 or data.get("slug") != expected_slug:
    raise SystemExit("release manifest identity mismatch")
port = data.get("internalPort")
if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65535:
    raise SystemExit("invalid internal port")
health = data.get("healthPath")
if not isinstance(health, str) or not re.fullmatch(r"/[A-Za-z0-9._~/:@+\-]*", health):
    raise SystemExit("invalid health path")
if ".." in health or "//" in health or "?" in health or "#" in health:
    raise SystemExit("non-canonical health path")
mode = data.get("pathMode", "strip")
if mode not in {"strip", "preserve"}:
    raise SystemExit("invalid path mode")
print(port)
print(health)
print(mode)
PY
  )
  [[ "${#manifest_fields[@]}" == "3" ]] || die "Could not read release manifest."
  target_port="${manifest_fields[0]}"
  target_health="${manifest_fields[1]}"
  target_mode="${manifest_fields[2]}"
  target_public_health="/apps/${slug}${target_health}"
  if [[ "${target_mode}" == "strip" ]]; then
    target_upstream_health="${target_health}"
  else
    target_upstream_health="${target_public_health}"
  fi
}

read_release_commit() {
  local release_dir="$1"
  local release_record="${release_dir}/RELEASE.json"
  [[ -f "${release_record}" && ! -L "${release_record}" ]] || die "Release identity record is missing."
  python3 - "${release_record}" <<'PY'
import json, re, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
value = data.get("sourceCommit")
if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{40}", value):
    raise SystemExit("invalid release commit")
print(value)
PY
}

compose_for() {
  local release_dir="$1"
  local release_id
  release_id="$(basename -- "${release_dir}")"
  shift
  (
    cd -- "${release_dir}"
    env STRATO_RELEASE="${release_id}" STRATO_APP_ROOT="${app_root}" \
      "${DOCKER_BIN}" compose --project-name "${compose_project}" \
        --file "${release_dir}/compose.strato.yaml" "$@"
  )
}

validate_compose() {
  local release_dir="$1"
  local release_id config_path
  release_id="$(basename -- "${release_dir}")"
  [[ -f "${release_dir}/compose.strato.yaml" && ! -L "${release_dir}/compose.strato.yaml" ]] \
    || die "compose.strato.yaml is missing."
  config_path="$(mktemp "${staging_root}/compose-${release_id}.XXXXXX.json")"
  chmod 0600 "${config_path}"
  compose_for "${release_dir}" config --no-env-resolution --format json > "${config_path}"
  python3 - "${config_path}" "${slug}" "${release_id}" "${target_port}" "${app_root}" <<'PY'
import json, sys
from pathlib import Path

path, slug, release, port, app_root = sys.argv[1:]
model = json.loads(Path(path).read_text(encoding="utf-8"))
services = model.get("services") or {}
web = services.get("web")
if not isinstance(web, dict):
    raise SystemExit("Compose must define service web")
edge = "strato-app-edge"
ai = "strato-ai-internal"
ingress = "strato-ingress"
alias = f"strato-{slug}-web"
for service_name, service in services.items():
    if service.get("ports"):
        raise SystemExit(f"{service_name} publishes a host port")
    if service.get("network_mode") == "host":
        raise SystemExit(f"{service_name} uses host networking")
    if service.get("container_name"):
        raise SystemExit(f"{service_name} sets container_name")
    memberships = service.get("networks") or {}
    if isinstance(memberships, list):
        memberships = {name: None for name in memberships}
    if ingress in memberships:
        raise SystemExit(f"{service_name} joins strato-ingress")
    if edge in memberships and service_name != "web":
        raise SystemExit(f"only web may join strato-app-edge")
    if ai in memberships:
        if service_name != "web" or (service.get("labels") or {}).get("com.strato.ai.client") != slug:
            raise SystemExit("central AI access requires the web service's explicit client label")
        if memberships[ai] and memberships[ai].get("aliases"):
            raise SystemExit("AI clients cannot declare shared service aliases")
    for mount in service.get("volumes") or []:
        if not isinstance(mount, dict):
            continue
        mount_type = mount.get("type")
        source = mount.get("source") or ""
        if mount_type == "volume":
            raise SystemExit("named volumes are not app-root persistent data")
        if mount_type == "bind" and not (
            source == f"{app_root}/data" or source.startswith(f"{app_root}/data/") or
            source == f"{app_root}/secrets" or source.startswith(f"{app_root}/secrets/")
        ):
            raise SystemExit("bind mounts must come from the app data or secrets directory")
memberships = web.get("networks") or {}
if isinstance(memberships, list):
    memberships = {name: None for name in memberships}
if edge not in memberships:
    raise SystemExit("web must join strato-app-edge")
edge_membership = memberships[edge] or {}
if edge_membership.get("aliases") != [alias]:
    raise SystemExit("web must declare only its derived edge alias")
if web.get("image") != f"strato-{slug}-web:{release}":
    raise SystemExit("web image must use the release-specific app tag")
if str(port) not in [str(value) for value in (web.get("expose") or [])]:
    raise SystemExit("web must expose the manifest internal port")
networks = model.get("networks") or {}
edge_model = networks.get(edge) or {}
if edge_model.get("name") != edge or not edge_model.get("external"):
    raise SystemExit("strato-app-edge must be the fixed external network")
for key, network in networks.items():
    if key == edge:
        continue
    network = network or {}
    if key == ai:
        if network.get("name") != ai or not network.get("external"):
            raise SystemExit("central AI must use its fixed external internal network")
        continue
    if network.get("external"):
        raise SystemExit("other external networks are forbidden")
    name = network.get("name") or ""
    if not name.startswith(f"strato-{slug}_"):
        raise SystemExit("private networks must belong to this Compose project")
PY
  if python3 -c 'import json,sys; sys.exit(0 if "strato-ai-internal" in json.load(open(sys.argv[1])).get("networks",{}) else 1)' "${config_path}"; then
    [[ "$("${DOCKER_BIN}" network inspect --format '{{.Internal}}/{{index .Labels "com.strato.ai.owner"}}' strato-ai-internal)" == true/strato-ai ]] \
      || die "Central AI network is missing or does not have the required internal ownership."
  fi
  rm -f -- "${config_path}"
}

gateway_container_id() {
  local ids
  ids="$("${DOCKER_BIN}" ps -q \
    --filter 'label=com.docker.compose.project=strato-app-gateway' \
    --filter 'label=com.docker.compose.service=gateway')"
  [[ "$(printf '%s\n' "${ids}" | sed '/^$/d' | wc -l)" == "1" ]] || die "Gateway container is not uniquely running."
  printf '%s\n' "${ids}"
}

web_container_id() {
  local ids
  ids="$("${DOCKER_BIN}" ps -aq \
    --filter "label=com.docker.compose.project=${compose_project}" \
    --filter 'label=com.docker.compose.service=web')"
  [[ "$(printf '%s\n' "${ids}" | sed '/^$/d' | wc -l)" == "1" ]] || die "App web container is not unique."
  printf '%s\n' "${ids}"
}

verify_runtime() {
  local release_dir="$1"
  local release_id web_id running networks ports aliases image
  release_id="$(basename -- "${release_dir}")"
  web_id="$(web_container_id)"
  running="$("${DOCKER_BIN}" inspect --format '{{.State.Running}}' "${web_id}")"
  [[ "${running}" == "true" ]] || die "App web container is not running."
  ports="$("${DOCKER_BIN}" port "${web_id}")"
  [[ -z "${ports}" ]] || die "App unexpectedly publishes a host port."
  networks="$("${DOCKER_BIN}" inspect --format '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' "${web_id}")"
  grep -Fxq "${EDGE_NETWORK}" <<< "${networks}" || die "App web container is not on strato-app-edge."
  ! grep -Fxq "${INGRESS_NETWORK}" <<< "${networks}" || die "App web container joined strato-ingress."
  aliases="$("${DOCKER_BIN}" inspect --format '{{json (index .NetworkSettings.Networks "strato-app-edge").Aliases}}' "${web_id}")"
  grep -Fq "\"${network_alias}\"" <<< "${aliases}" || die "App web alias is missing."
  image="$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${web_id}")"
  [[ "${image}" == "strato-${slug}-web:${release_id}" ]] || die "App web image is not the selected release."

  local gateway_id url attempt
  gateway_id="$(gateway_container_id)"
  url="http://${network_alias}:${target_port}${target_upstream_health}"
  for attempt in $(seq 1 30); do
    if "${DOCKER_BIN}" exec "${gateway_id}" wget -T 10 -q -O /dev/null "${url}" >/dev/null 2>&1; then
      printf '%s\n' "${web_id}"
      return 0
    fi
    sleep 2
  done
  die "Internal application health probe failed."
}

route_upsert() {
  "${GATEWAY_CURRENT}/server/manage-route.sh" upsert \
    "${slug}" "${network_alias}" "${target_port}" "${target_mode}" "${target_public_health}" >/dev/null
}

route_remove() {
  "${GATEWAY_CURRENT}/server/manage-route.sh" remove "${slug}" >/dev/null
}

verify_route_record() {
  local registration="${GATEWAY_REGISTRATIONS}/${slug}.json"
  local route="${GATEWAY_ROUTES}/${slug}.caddy"
  [[ -f "${registration}" && ! -L "${registration}" && -f "${route}" && ! -L "${route}" ]] \
    || die "App route allocation is missing."
  python3 - "${registration}" "${route}" "${slug}" "${network_alias}" "${target_port}" "${target_mode}" <<'PY'
import hashlib, json, sys
from pathlib import Path

registration_path, route_path, slug, alias, port, mode = sys.argv[1:]
data = json.loads(Path(registration_path).read_text(encoding="utf-8"))
expected = {
    "schemaVersion": 1,
    "slug": slug,
    "publicPath": f"/apps/{slug}/",
    "composeProject": f"strato-{slug}",
    "networkAlias": alias,
    "internalPort": int(port),
    "pathMode": mode,
}
for key, value in expected.items():
    if data.get(key) != value:
        raise SystemExit(f"route registration mismatch: {key}")
route_hash = hashlib.sha256(Path(route_path).read_bytes()).hexdigest()
if data.get("routeSha256") != route_hash:
    raise SystemExit("route hash mismatch")
print(route_hash)
PY
}

verify_public() {
  local headers status
  headers="$(mktemp "${staging_root}/headers.XXXXXX")"
  chmod 0600 "${headers}"
  status="$(curl --silent --show-error --max-time 15 --dump-header "${headers}" \
    --output /dev/null --write-out '%{http_code}' "${PUBLIC_ORIGIN}${target_public_health}")"
  [[ "${status}" =~ ^2[0-9]{2}$ ]] || { rm -f -- "${headers}"; die "Public app health returned HTTP ${status}."; }
  grep -Fiq "${GATEWAY_HEADER}" "${headers}" || { rm -f -- "${headers}"; die "Public app response lacks the gateway header."; }
  rm -f -- "${headers}"
}

write_ready_record() {
  local release_dir="$1"
  local release_id commit route_hash next
  release_id="$(basename -- "${release_dir}")"
  commit="$(read_release_commit "${release_dir}")"
  route_hash="$(verify_route_record)"
  next="${ready_root}/.${release_id}.next"
  printf '{"schemaVersion":1,"release":"%s","sourceCommit":"%s","routeSha256":"%s"}\n' \
    "${release_id}" "${commit}" "${route_hash}" > "${next}"
  chmod 0644 "${next}"
  mv -Tf -- "${next}" "${ready_root}/${release_id}.json"
}

verify_ready_record() {
  local release_dir="$1"
  local release_id commit marker
  release_id="$(basename -- "${release_dir}")"
  commit="$(read_release_commit "${release_dir}")"
  marker="${ready_root}/${release_id}.json"
  [[ -f "${marker}" && ! -L "${marker}" ]] || die "Release is not marked ready: ${release_id}"
  python3 - "${marker}" "${release_id}" "${commit}" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if data.get("schemaVersion") != 1 or data.get("release") != sys.argv[2] or data.get("sourceCommit") != sys.argv[3]:
    raise SystemExit("ready record does not match release")
PY
}

start_release() {
  local release_dir="$1"
  local release_id expected_image
  release_id="$(basename -- "${release_dir}")"
  expected_image="strato-${slug}-web:${release_id}"
  "${DOCKER_BIN}" image inspect "${expected_image}" >/dev/null 2>&1 || die "Release image is unavailable: ${expected_image}"
  compose_for "${release_dir}" up -d --no-build --pull never --remove-orphans
}

stop_release() {
  local release_dir="$1"
  compose_for "${release_dir}" rm --force --stop
}

clear_current_if_target() {
  local release_dir="$1"
  rm -f -- "${app_root}/current.next"
  if [[ -L "${app_root}/current" && "$(realpath -e -- "${app_root}/current")" == "${release_dir}" ]]; then
    rm -f -- "${app_root}/current"
  fi
}

restore_previous_runtime_and_route() {
  local previous_dir="$1"
  read_release_manifest "${previous_dir}"
  validate_compose "${previous_dir}"
  start_release "${previous_dir}"
  verify_runtime "${previous_dir}" >/dev/null
  route_upsert
  verify_route_record >/dev/null
  verify_public
  verify_shared_prerequisites
}

prepare_release() {
  local release_id="$1" commit="$2" archive="$3" archive_hash="$4"
  local final_dir="${releases_root}/${release_id}"
  local stage_dir="${staging_root}/${release_id}.new"
  [[ "${archive}" =~ ^${INCOMING_ROOT}/${slug}-${release_id}-[0-9a-f]{32}\.tar$ ]] || die "Unexpected upload path."
  [[ -f "${archive}" && ! -L "${archive}" ]] || die "Release archive is missing."
  [[ "$(sha256sum -- "${archive}" | awk '{print $1}')" == "${archive_hash}" ]] || die "Release archive hash mismatch."
  [[ ! -e "${final_dir}" && ! -L "${final_dir}" ]] || die "Release already exists."
  [[ ! -e "${stage_dir}" && ! -L "${stage_dir}" ]] || die "Release staging path already exists."
  install -d -m 0700 -o root -g root "${stage_dir}"
  while IFS= read -r member; do
    [[ -n "${member}" ]] || continue
    [[ "${member}" != /* && "${member}" != ".." && "${member}" != ../* && "${member}" != */../* ]] \
      || die "Unsafe archive member."
  done < <(tar -tf "${archive}")
  tar -xf "${archive}" --no-same-owner --no-same-permissions -C "${stage_dir}"
  [[ -f "${stage_dir}/.strato/deploy.json" && -f "${stage_dir}/compose.strato.yaml" ]] \
    || die "Release archive lacks deployment files."
  printf '{"schemaVersion":1,"release":"%s","sourceCommit":"%s","archiveSha256":"%s"}\n' \
    "${release_id}" "${commit}" "${archive_hash}" > "${stage_dir}/RELEASE.json"
  chmod 0644 "${stage_dir}/RELEASE.json"
  chmod -R a-w "${stage_dir}"
  mv -- "${stage_dir}" "${final_dir}"
  printf '%s\n' "${final_dir}"
}

action="${1:-}"
shift || true
require_runtime

case "${action}" in
  preflight)
    (( $# == 1 )) || die "Usage: preflight <slug>"
    set_app_paths "$1"
    verify_shared_prerequisites
    printf '{"status":"ready","slug":"%s","serverRoot":"%s"}\n' "${slug}" "${app_root}"
    ;;

  deploy)
    (( $# == 8 )) || die "Usage: deploy <slug> <release> <commit> <port> <health> <mode> <archive> <sha256>"
    set_app_paths "$1"
    release_id="$2"
    source_commit="$3"
    requested_port="$4"
    requested_health="$5"
    requested_mode="$6"
    archive_path="$7"
    archive_hash="$8"
    validate_release "${release_id}"
    validate_commit "${source_commit}"
    validate_hash "${archive_hash}"
    [[ "${requested_port}" =~ ^[0-9]{1,5}$ ]] || die "Invalid requested port."
    [[ "${requested_mode}" == "strip" || "${requested_mode}" == "preserve" ]] || die "Invalid requested path mode."
    [[ "${archive_path}" =~ ^${INCOMING_ROOT}/${slug}-${release_id}-[0-9a-f]{32}\.tar$ ]] || die "Unexpected upload path."
    trap 'rm -f -- "${archive_path}"' EXIT
    verify_shared_prerequisites
    acquire_operation_locks
    verify_shared_prerequisites
    previous_dir="$(current_release_dir)"
    if [[ -z "${previous_dir}" && -e "${GATEWAY_REGISTRATIONS}/${slug}.json" ]]; then
      die "A route already exists but this app has no current release."
    fi
    candidate_dir="$(prepare_release "${release_id}" "${source_commit}" "${archive_path}" "${archive_hash}")"
    read_release_manifest "${candidate_dir}"
    [[ "${target_port}" == "${requested_port}" && "${target_health}" == "${requested_health}" && "${target_mode}" == "${requested_mode}" ]] \
      || die "Transferred release manifest differs from the validated local manifest."
    validate_compose "${candidate_dir}"

    runtime_changed=false
    route_changed=false
    current_changed=false
    completed=false
    recover_deploy() {
      local status=$?
      local recovery_status=0
      trap - EXIT INT TERM HUP
      set +e
      rm -f -- "${archive_path}"
      if [[ "${completed}" != true ]]; then
        rm -f -- "${ready_root}/${release_id}.json" "${ready_root}/.${release_id}.next"
        if [[ -n "${previous_dir}" && ( "${runtime_changed}" == true || "${route_changed}" == true || "${current_changed}" == true ) ]]; then
          ( restore_previous_runtime_and_route "${previous_dir}" && switch_current "${previous_dir}" ) || recovery_status=$?
        elif [[ -z "${previous_dir}" ]]; then
          if [[ "${route_changed}" == true && ( -e "${GATEWAY_ROUTES}/${slug}.caddy" || -e "${GATEWAY_REGISTRATIONS}/${slug}.json" ) ]]; then
            ( route_remove ) || recovery_status=$?
          fi
          if [[ "${runtime_changed}" == true ]]; then
            ( stop_release "${candidate_dir}" ) || recovery_status=$?
          fi
          if [[ "${current_changed}" == true ]]; then
            ( clear_current_if_target "${candidate_dir}" ) || recovery_status=$?
          fi
        fi
      fi
      if (( recovery_status != 0 )); then
        printf 'ERROR: Deployment failed and automatic app rollback also failed.\n' >&2
        exit 70
      fi
      (( status != 0 )) || status=1
      exit "${status}"
    }
    trap recover_deploy EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    compose_for "${candidate_dir}" build
    runtime_changed=true
    start_release "${candidate_dir}"
    verify_runtime "${candidate_dir}" >/dev/null
    route_changed=true
    route_upsert
    route_hash="$(verify_route_record)"
    verify_public
    verify_shared_prerequisites
    write_ready_record "${candidate_dir}"
    current_changed=true
    switch_current "${candidate_dir}"
    completed=true
    trap - EXIT INT TERM HUP
    rm -f -- "${archive_path}"
    web_id="$(web_container_id)"
    image="$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${web_id}")"
    printf '{"status":"deployed","slug":"%s","release":"%s","sourceCommit":"%s","serverRoot":"%s","composeProject":"%s","image":"%s","routeSha256":"%s","pathMode":"%s","publicUrl":"%s/apps/%s/"}\n' \
      "${slug}" "${release_id}" "${source_commit}" "${app_root}" "${compose_project}" "${image}" "${route_hash}" "${target_mode}" "${PUBLIC_ORIGIN}" "${slug}"
    ;;

  verify)
    (( $# == 1 )) || die "Usage: verify <slug>"
    set_app_paths "$1"
    verify_shared_prerequisites
    current_dir="$(current_release_dir)"
    [[ -n "${current_dir}" ]] || die "App has no current release."
    release_id="$(basename -- "${current_dir}")"
    verify_ready_record "${current_dir}"
    read_release_manifest "${current_dir}"
    validate_compose "${current_dir}"
    web_id="$(verify_runtime "${current_dir}")"
    route_hash="$(verify_route_record)"
    verify_public
    source_commit="$(read_release_commit "${current_dir}")"
    image="$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "${web_id}")"
    printf '{"status":"healthy","slug":"%s","release":"%s","sourceCommit":"%s","serverRoot":"%s","composeProject":"%s","container":"%s","image":"%s","routeSha256":"%s","pathMode":"%s","internalHealth":"ok","publicHealth":"ok","publicUrl":"%s/apps/%s/"}\n' \
      "${slug}" "${release_id}" "${source_commit}" "${app_root}" "${compose_project}" "${web_id}" "${image}" "${route_hash}" "${target_mode}" "${PUBLIC_ORIGIN}" "${slug}"
    ;;

  rollback)
    (( $# == 2 )) || die "Usage: rollback <slug> <release>"
    set_app_paths "$1"
    target_release="$2"
    validate_release "${target_release}"
    verify_shared_prerequisites
    acquire_operation_locks
    verify_shared_prerequisites
    original_dir="$(current_release_dir)"
    [[ -n "${original_dir}" ]] || die "App has no current release to roll back."
    target_dir="$(resolve_release "${target_release}")"
    [[ "${target_dir}" != "${original_dir}" ]] || die "Requested release is already current."
    verify_ready_record "${target_dir}"
    read_release_manifest "${target_dir}"
    validate_compose "${target_dir}"

    runtime_changed=false
    current_changed=false
    completed=false
    recover_rollback() {
      local status=$?
      local recovery_status=0
      trap - EXIT INT TERM HUP
      set +e
      if [[ "${completed}" != true && "${runtime_changed}" == true ]]; then
        ( restore_previous_runtime_and_route "${original_dir}" && switch_current "${original_dir}" ) || recovery_status=$?
      fi
      if (( recovery_status != 0 )); then
        printf 'ERROR: Rollback failed and restoring the original runtime also failed.\n' >&2
        exit 70
      fi
      (( status != 0 )) || status=1
      exit "${status}"
    }
    trap recover_rollback EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    runtime_changed=true
    start_release "${target_dir}"
    verify_runtime "${target_dir}" >/dev/null
    route_upsert
    route_hash="$(verify_route_record)"
    verify_public
    verify_shared_prerequisites
    current_changed=true
    switch_current "${target_dir}"
    completed=true
    trap - EXIT INT TERM HUP
    source_commit="$(read_release_commit "${target_dir}")"
    image="$("${DOCKER_BIN}" inspect --format '{{.Config.Image}}' "$(web_container_id)")"
    printf '{"status":"rolled-back","slug":"%s","release":"%s","sourceCommit":"%s","serverRoot":"%s","composeProject":"%s","image":"%s","routeSha256":"%s","pathMode":"%s","publicUrl":"%s/apps/%s/"}\n' \
      "${slug}" "${target_release}" "${source_commit}" "${app_root}" "${compose_project}" "${image}" "${route_hash}" "${target_mode}" "${PUBLIC_ORIGIN}" "${slug}"
    ;;

  *) die "Action must be preflight, deploy, verify, or rollback." ;;
esac
