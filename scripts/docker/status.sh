#!/usr/bin/env bash
# Show the box's status.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
if [ -z "$state" ]; then
  codebox_info "container '$CODEBOX_INSTANCE' does not exist (image: $CODEBOX_DOCKER_IMAGE)."
  exit 0
fi

codebox_info "container '$CODEBOX_INSTANCE': $state"
docker ps -a --filter "name=^${CODEBOX_INSTANCE}$" \
  --format 'table {{.Names}}\t{{.State}}\t{{.Image}}\t{{.RunningFor}}\t{{.Ports}}'
