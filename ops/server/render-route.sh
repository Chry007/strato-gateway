#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=common.sh
source "${SCRIPT_DIR}/common.sh"

(( $# == 4 )) || die "Usage: render-route.sh <slug> <alias> <port> <strip|preserve>"
slug="$1"
alias_name="$2"
port="$3"
path_mode="$4"

validate_slug "${slug}"
[[ "${alias_name}" == "strato-${slug}-web" ]] || die "Alias must be the derived strato-<slug>-web value."
validate_port "${port}"
[[ "${path_mode}" == "strip" || "${path_mode}" == "preserve" ]] || die "Path mode must be strip or preserve."

printf 'redir /apps/%s /apps/%s/ 308\n\n' "${slug}" "${slug}"
if [[ "${path_mode}" == "strip" ]]; then
  printf 'handle_path /apps/%s/* {\n' "${slug}"
else
  printf 'handle /apps/%s/* {\n' "${slug}"
fi
printf '\treverse_proxy %s:%s {\n' "${alias_name}" "${port}"
printf '\t\theader_up X-Forwarded-Prefix "/apps/%s"\n' "${slug}"
printf '\t}\n'
printf '}\n'
