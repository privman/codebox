# Base image for a local codebox.
#
# Deliberately thin. It sets up only what vm/bootstrap.sh cannot do for itself — a
# sudo-capable non-root user, mirroring the login user on a GCP VM — and leaves the
# codebox layer (Claude Code, code-server, GitHub access, your repo) to bootstrap.sh at
# `codebox create` time. Both providers therefore install the same things the same way,
# and there is no second list to keep in sync.
FROM debian:12

ARG CODEBOX_USER=coder
ARG CODEBOX_UID=1000

# Only the essentials: bootstrap.sh installs the rest (git, gh, ripgrep, jq, tmux, ...).
# procps and iproute2 are here because bootstrap and the editor terminal expect ps/ss.
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      ca-certificates curl sudo procps iproute2 less locales \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --uid "${CODEBOX_UID}" --shell /bin/bash "${CODEBOX_USER}" \
 && printf '%s ALL=(ALL) NOPASSWD:ALL\n' "${CODEBOX_USER}" > /etc/sudoers.d/codebox \
 && chmod 0440 /etc/sudoers.d/codebox

COPY docker/entrypoint.sh /usr/local/bin/codebox-entrypoint
RUN chmod 0755 /usr/local/bin/codebox-entrypoint

# Marks the box as a container for bootstrap.sh, which skips the systemd-shaped parts
# (the code-server unit, the idle-suspend timer) when it sees this.
ENV CODEBOX_CONTAINER=1
ENV LANG=C.UTF-8

USER ${CODEBOX_USER}
WORKDIR /home/${CODEBOX_USER}
ENTRYPOINT ["/usr/local/bin/codebox-entrypoint"]
