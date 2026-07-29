#!/usr/bin/env bash
# Delete the box and, optionally, the image it was built from.
set -euo pipefail
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

codebox_check_docker

state="$(codebox_container_state)"
if [ -n "$state" ]; then
  printf 'Delete container "%s" (state: %s)? Everything inside it will be lost. [y/N] ' \
    "$CODEBOX_INSTANCE" "$state" >&2
  read -r ans
  if [ "$ans" = y ] || [ "$ans" = Y ]; then
    docker rm -f "$CODEBOX_INSTANCE" >/dev/null
    codebox_info "Container deleted."
  else
    codebox_info "Left the container in place."
  fi
else
  codebox_info "Container '$CODEBOX_INSTANCE' does not exist; nothing to delete."
fi

if docker image inspect "$CODEBOX_DOCKER_IMAGE" >/dev/null 2>&1; then
  printf 'Also delete the image "%s"? The next create rebuilds it. [y/N] ' \
    "$CODEBOX_DOCKER_IMAGE" >&2
  read -r ans2
  if [ "$ans2" = y ] || [ "$ans2" = Y ]; then
    docker rmi "$CODEBOX_DOCKER_IMAGE" >/dev/null 2>&1 || \
      codebox_warn "could not delete the image (another container may still use it)."
    codebox_info "Image deleted."
  else
    codebox_info "Left the image in place."
  fi
fi
