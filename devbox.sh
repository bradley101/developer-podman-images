#!/usr/bin/env bash
# Host-side helper for the devbox Podman image.
#
#   ./devbox.sh build [extra podman build args]   build the image
#   ./devbox.sh run                               start the container (always restarting)
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
set -euo pipefail

cd "$(dirname "$(readlink -f "$0")")"

IMAGE="${DEVBOX_IMAGE:-localhost/devbox:latest}"
NAME="${DEVBOX_NAME:-devbox}"
PORT="${DEVBOX_PORT:-2222}"
BIND="${DEVBOX_BIND:-0.0.0.0}"
USER_IN_BOX="dev"
KEYS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/devbox"
KEYS_FILE="$KEYS_DIR/authorized_keys"

die() { echo "error: $*" >&2; exit 1; }

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
  podman container exists "$NAME" && die "container '$NAME' already exists (./devbox.sh rm to remove it)"
  local args=(
    --detach
    --name "$NAME"
    --hostname "$NAME"
    --restart always
    --publish "$BIND:$PORT:22"
    --volume "$NAME-workspace:/home/$USER_IN_BOX/workspace"
    --volume "$NAME-hostkeys:/etc/ssh/hostkeys"
    --volume "$KEYS_DIR:/etc/devbox:ro,Z"
    # gdb / strace / lldb / perf need ptrace & perf events
    --cap-add SYS_PTRACE
    --cap-add PERFMON
    --security-opt seccomp=unconfined
  )
  [[ -n "${DEVBOX_PASSWORD:-}" ]] && args+=(--env "DEV_PASSWORD=$DEVBOX_PASSWORD")
  podman run "${args[@]}" "$IMAGE"
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
  local dir
  if [[ $EUID -eq 0 ]]; then dir=/etc/containers/systemd; else dir="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"; fi
  mkdir -p "$dir"
  sed -e "s|@IMAGE@|$IMAGE|g" -e "s|@NAME@|$NAME|g" -e "s|@PORT@|$PORT|g" \
      -e "s|@BIND@|$BIND|g" -e "s|@KEYS_DIR@|$KEYS_DIR|g" -e "s|@USER@|$USER_IN_BOX|g" \
      quadlet/devbox.container > "$dir/$NAME.container"
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
  run)              cmd_run ;;
  install-service)  cmd_install_service ;;
  ssh)              shift; exec ssh -p "$PORT" -o StrictHostKeyChecking=accept-new "$USER_IN_BOX@localhost" "$@" ;;
  shell)            exec podman exec -it --user "$USER_IN_BOX" "$NAME" bash -l ;;
  logs)             exec podman logs -f "$NAME" ;;
  status)           podman ps -a --filter "name=^$NAME\$"; podman healthcheck run "$NAME" && echo healthy ;;
  stop)             podman stop "$NAME" ;;
  rm)               podman rm -f "$NAME" ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
