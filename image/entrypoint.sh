#!/usr/bin/env bash
# Container entrypoint: prepares SSH access and runs sshd in the foreground,
# which keeps the container running.
#
# Environment variables:
#   SSH_AUTHORIZED_KEYS   public key(s) to authorize for the dev user
#   DEV_PASSWORD          if set, sets the dev user's password and enables
#                         SSH password authentication (keys are preferred)
#   TZ                    time zone, e.g. Europe/Berlin
set -euo pipefail

USERNAME="${DEVBOX_USER:-dev}"
USER_HOME="$(getent passwd "$USERNAME" | cut -d: -f6)"

log() { echo "[devbox] $*"; }

# ---------------------------------------------------------------- host keys
install -d -m 0755 /etc/ssh/hostkeys /run/sshd
for type in ed25519 ecdsa rsa; do
  key="/etc/ssh/hostkeys/ssh_host_${type}_key"
  if [[ ! -f "$key" ]]; then
    log "generating $type host key"
    ssh-keygen -q -t "$type" -N '' -f "$key"
  fi
done

# ------------------------------------------------------- authorized keys
install -d -m 0700 -o "$USERNAME" -g "$USERNAME" "$USER_HOME/.ssh"
ak="$USER_HOME/.ssh/authorized_keys"
touch "$ak"
if [[ -n "${SSH_AUTHORIZED_KEYS:-}" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    grep -qxF "$line" "$ak" || echo "$line" >> "$ak"
  done <<< "$SSH_AUTHORIZED_KEYS"
fi
chown "$USERNAME:$USERNAME" "$ak"
chmod 0600 "$ak"

# ---------------------------------------------------------------- password
pw_conf=/etc/ssh/sshd_config.d/00-devbox-password.conf
if [[ -n "${DEV_PASSWORD:-}" ]]; then
  echo "$USERNAME:$DEV_PASSWORD" | chpasswd
  echo "PasswordAuthentication yes" > "$pw_conf"
  log "password authentication enabled for $USERNAME"
else
  echo "PasswordAuthentication no" > "$pw_conf"
fi
unset DEV_PASSWORD

if [[ ! -s "$ak" && ! -s /etc/devbox/authorized_keys ]] && grep -q "no" "$pw_conf"; then
  log "WARNING: no SSH public key and no DEV_PASSWORD configured - you will not be able to log in."
  log "         Pass -e SSH_AUTHORIZED_KEYS=\"\$(cat ~/.ssh/id_ed25519.pub)\" or mount a key file"
  log "         at /etc/devbox/authorized_keys."
fi

# ----------------------------------------------------------------- timezone
if [[ -n "${TZ:-}" && -e "/usr/share/zoneinfo/$TZ" ]]; then
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
  echo "$TZ" > /etc/timezone
fi

# A freshly created workspace volume is empty and root-owned: hand it to the
# dev user. Never touch a non-empty directory (it may be bind-mounted from
# the host).
ws="$USER_HOME/workspace"
if [[ -d "$ws" && "$(stat -c %u "$ws")" == 0 && -z "$(ls -A "$ws" 2>/dev/null)" ]]; then
  chown "$USERNAME:$USERNAME" "$ws" 2>/dev/null || true
fi

/usr/sbin/sshd -t
log "sshd listening on port 22 (user: $USERNAME)"

# Run anything passed as arguments (e.g. `podman run devbox bash -lc ...`),
# otherwise sshd in the foreground.
if [[ $# -gt 0 ]]; then
  exec "$@"
fi
exec /usr/sbin/sshd -D -e
