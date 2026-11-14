#!/usr/bin/env bash
# Host-side helper for the devbox Podman image.
#
#   ./devbox.sh build [extra podman build args]   build the image
#   ./devbox.sh run [extra podman run args]       start the container (always restarting)
#   ./devbox.sh install-service                   run it as a systemd (Quadlet) service, start on boot
#   ./devbox.sh ssh                               ssh into it
#   ./devbox.sh shell                             shell via podman exec
#   ./devbox.sh logs | status | stop | rm
#
# Settings (environment variables):
#   DEVBOX_IMAGE     image name             (default: localhost/devbox:latest)
#   DEVBOX_NAME      container name         (default: devbox)
#   DEVBOX_PORT      host port for SSH      (default: 2222)
#   DEVBOX_BIND      host address to bind   (default: 0.0.0.0 = reachable from the LAN;
#                    use 127.0.0.1 for local-only access)
#   DEVBOX_PUBKEY    public key file(s) to authorize, colon separated
#                    (default: all ~/.ssh/*.pub)
#   DEVBOX_PASSWORD  optional password for the dev user (enables password login)
#   DEVBOX_WORKSPACE host directory to use as ~/workspace instead of the
#                    devbox-workspace volume, e.g. DEVBOX_WORKSPACE=~/code
#   DEVBOX_MOUNTS    extra host directories, comma separated
#                    "host:container[:options]"; a relative container path is
#                    taken relative to /home/dev, e.g.
#                    DEVBOX_MOUNTS="~/src:src,~/datasets:/data:ro"
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

IMAGE="${DEVBOX_IMAGE:-localhost/devbox:latest}"
NAME="${DEVBOX_NAME:-devbox}"
PORT="${DEVBOX_PORT:-2222}"
BIND="${DEVBOX_BIND:-0.0.0.0}"
USER_IN_BOX="dev"
UID_IN_BOX=1000
GID_IN_BOX=1000
KEYS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/devbox"
KEYS_FILE="$KEYS_DIR/authorized_keys"

die() { echo "error: $*" >&2; exit 1; }

# Fills the global array MOUNTS with "host:container:options" entries for
# DEVBOX_WORKSPACE and DEVBOX_MOUNTS (host paths made absolute, ~ expanded).
MOUNTS=()
WORKSPACE_MOUNT="$NAME-workspace:/home/$USER_IN_BOX/workspace"
prepare_mounts() {
  local specs=() spec host ctr opts
  [[ -n "${DEVBOX_WORKSPACE:-}" ]] && specs+=("$DEVBOX_WORKSPACE:/home/$USER_IN_BOX/workspace")
  if [[ -n "${DEVBOX_MOUNTS:-}" ]]; then
    local extra=(); IFS=, read -r -a extra <<< "$DEVBOX_MOUNTS"; specs+=("${extra[@]}")
  fi
  for spec in "${specs[@]}"; do
    spec="${spec#"${spec%%[![:space:]]*}"}"; spec="${spec%"${spec##*[![:space:]]}"}"   # trim
    [[ -z "$spec" ]] && continue
    IFS=: read -r host ctr opts <<< "$spec"
    [[ -n "$host" && -n "$ctr" ]] || die "bad mount '$spec' (expected host:container[:options])"
    host="${host/#\~/$HOME}"
    [[ -d "$host" || -f "$host" ]] || die "mount source does not exist: $host"
    host="$(readlink -f "$host")"
    [[ "$ctr" == /* ]] || ctr="/home/$USER_IN_BOX/$ctr"
    # Rootful podman does not remap UIDs: dev (uid 1000) can only write to
    # host files owned by uid 1000.
    if [[ $EUID -eq 0 && "$(stat -c %u "$host")" != "$UID_IN_BOX" && ",$opts," != *,ro,* ]]; then
      echo "warning: $host is owned by uid $(stat -c %u "$host"), but dev in the container is uid $UID_IN_BOX;" >&2
      echo "         it will not be writable. Use rootless podman (recommended), or rebuild with" >&2
      echo "         ./devbox.sh build --build-arg USER_UID=$(stat -c %u "$host") --build-arg USER_GID=$(stat -c %g "$host")" >&2
      echo "         and set UID_IN_BOX/GID_IN_BOX in devbox.sh to match." >&2
    fi
    # SELinux (Fedora/RHEL): relabel so the container may access it, unless
    # options were given or it is the whole home directory.
    if [[ -z "$opts" && "$host" != "$(readlink -f "$HOME")" ]]; then opts=z; fi
    if [[ "$ctr" == "/home/$USER_IN_BOX/workspace" ]]; then
      WORKSPACE_MOUNT="$host:$ctr${opts:+:$opts}"
    else
      MOUNTS+=("$host:$ctr${opts:+:$opts}")
    fi
  done
}

# Rootless podman maps your host user to root inside the container, so files
# in bind-mounted directories would not be writable by "dev". keep-id maps
# your host user to dev (uid 1000) instead; files dev creates are owned by you.
USERNS=""
if [[ $EUID -ne 0 ]]; then USERNS="keep-id:uid=$UID_IN_BOX,gid=$GID_IN_BOX"; fi

# Collect the public keys that may log in into a dedicated file that is
# mounted read-only into the container.
prepare_keys() {
  mkdir -p "$KEYS_DIR"
  chmod 0755 "$KEYS_DIR"   # sshd StrictModes: must not be group/world writable
  local files=()
  if [[ -n "${DEVBOX_PUBKEY:-}" ]]; then
    IFS=: read -r -a files <<< "$DEVBOX_PUBKEY"
  else
    shopt -s nullglob; files=("$HOME"/.ssh/*.pub); shopt -u nullglob
  fi
  : > "$KEYS_FILE.tmp"
  for f in "${files[@]}"; do [[ -f "$f" ]] && cat "$f" >> "$KEYS_FILE.tmp"; done
  [[ -f "$KEYS_FILE" ]] && cat "$KEYS_FILE" >> "$KEYS_FILE.tmp"
  sort -u "$KEYS_FILE.tmp" | sed '/^$/d' > "$KEYS_FILE"; rm -f "$KEYS_FILE.tmp"
  chmod 0644 "$KEYS_FILE"
  if [[ ! -s "$KEYS_FILE" && -z "${DEVBOX_PASSWORD:-}" ]]; then
    echo "warning: no public key found (create one with: ssh-keygen -t ed25519)," >&2
    echo "         and DEVBOX_PASSWORD is not set - SSH login will not be possible." >&2
  fi
}

cmd_build() {
  # --format docker keeps the HEALTHCHECK (the OCI format drops it)
  podman build --format docker -t "$IMAGE" -f Containerfile "$@" .
}

cmd_run() {
  prepare_keys
  prepare_mounts
  podman container exists "$NAME" && die "container '$NAME' already exists (./devbox.sh rm to remove it)"
  local args=(
    --detach
    --name "$NAME"
    --hostname "$NAME"
    --restart always
    --publish "$BIND:$PORT:22"
    --volume "$WORKSPACE_MOUNT"
    --volume "$NAME-hostkeys:/etc/ssh/hostkeys"
    --volume "$KEYS_DIR:/etc/devbox:ro,Z"
    # gdb / strace / lldb / perf need ptrace & perf events
    --cap-add SYS_PTRACE
    --cap-add PERFMON
    --security-opt seccomp=unconfined
  )
  local m
  for m in "${MOUNTS[@]}"; do args+=(--volume "$m"); done
  [[ -n "$USERNS" ]] && args+=(--userns "$USERNS")
  [[ -n "${DEVBOX_PASSWORD:-}" ]] && args+=(--env "DEV_PASSWORD=$DEVBOX_PASSWORD")
  podman run "${args[@]}" "$@" "$IMAGE"
  for m in "$WORKSPACE_MOUNT" "${MOUNTS[@]}"; do
    [[ "$m" == /* ]] && echo "mounted ${m%%:*} -> $(cut -d: -f2 <<< "$m")"
  done
  echo
  echo "devbox is running. Connect with:"
  echo "  ssh -p $PORT $USER_IN_BOX@localhost"
  echo
  echo "Note: --restart=always restarts it when it exits. To also start it at boot"
  echo "(rootless podman), either run: systemctl --user enable --now podman-restart.service"
  echo "or use ./devbox.sh install-service (recommended)."
}

cmd_install_service() {
  prepare_keys
  prepare_mounts
  local dir
  if [[ $EUID -eq 0 ]]; then dir=/etc/containers/systemd; else dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"; fi
  mkdir -p "$dir"
  sed -e "s|@IMAGE@|$IMAGE|g" -e "s|@NAME@|$NAME|g" -e "s|@PORT@|$PORT|g" \
      -e "s|@BIND@|$BIND|g" -e "s|@KEYS_DIR@|$KEYS_DIR|g" -e "s|@USER@|$USER_IN_BOX|g" \
      -e "s|^Volume=$NAME-workspace:/home/$USER_IN_BOX/workspace$|Volume=$WORKSPACE_MOUNT|" \
      quadlet/devbox.container > "$dir/$NAME.container"
  local extra=() m
  for m in "${MOUNTS[@]}"; do extra+=("Volume=$m"); done
  [[ -n "$USERNS" ]] && extra+=("UserNS=$USERNS")
  # insert after the last Volume= line of the [Container] section
  if ((${#extra[@]})); then
    printf '%s\n' "${extra[@]}" > "$dir/.$NAME.extra"
    sed -i "/^Volume=.*\/etc\/devbox:/r $dir/.$NAME.extra" "$dir/$NAME.container"
    rm -f "$dir/.$NAME.extra"
  fi
  if [[ -n "${DEVBOX_PASSWORD:-}" ]]; then
    # stored as a podman secret instead of plain text in the unit file
    printf '%s' "$DEVBOX_PASSWORD" | podman secret create --replace "$NAME-password" -
    sed -i "/^\[Container\]/a Secret=$NAME-password,type=env,target=DEV_PASSWORD" "$dir/$NAME.container"
  fi
  echo "installed $dir/$NAME.container"

  if podman container exists "$NAME"; then
    echo "removing the existing '$NAME' container (volumes are kept)"
    podman rm -f "$NAME" >/dev/null
  fi

  local sc=(systemctl); [[ $EUID -ne 0 ]] && sc+=(--user)
  "${sc[@]}" daemon-reload
  "${sc[@]}" start "$NAME.service"
  if [[ $EUID -ne 0 ]]; then
    # let the user's services run without an active login session (i.e. at boot)
    loginctl enable-linger "$USER" 2>/dev/null || echo "hint: run 'sudo loginctl enable-linger $USER' to start at boot"
  fi
  "${sc[@]}" --no-pager status "$NAME.service" || true
  echo
  echo "Connect with: ssh -p $PORT $USER_IN_BOX@localhost"
}

case "${1:-}" in
  build)            shift; cmd_build "$@" ;;
  run)              shift; cmd_run "$@" ;;
  install-service)  cmd_install_service ;;
  ssh)              shift; exec ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER_IN_BOX@localhost" "$@" ;;
  shell)            exec podman exec -it --user "$USER_IN_BOX" "$NAME" bash -l ;;
  logs)             exec podman logs -f "$NAME" ;;
  status)           podman ps -a --filter "name=^$NAME\$"; podman healthcheck run "$NAME" && echo healthy ;;
  stop)             podman stop "$NAME" ;;
  rm)               podman rm -f "$NAME" ;;
  *) sed -n '2,/^set /{/^#/p}' "$0"; exit 1 ;;
esac
