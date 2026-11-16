#!/usr/bin/env bash
set -euo pipefail

CLOUDFLARED_VERSION=2026.11.0
CLOUDFLARED_SHA256=51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd
UNIT=talos-access
BIN=/usr/local/lib/talos-access
ETC=/etc/talos-access

main() {
  (($# == 2)) || { echo "usage: $0 '<ssh public key>' '<tunnel connector token>'" >&2; exit 2; }
  key="$1"
  token="$2"
  [[ "$key" =~ ^ssh-ed25519\ [A-Za-z0-9+/]+=*(\ .*)?$ ]] || { echo "the first argument is not an ssh-ed25519 public key" >&2; exit 2; }
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]{100,}$ ]] || { echo "the second argument is not a tunnel connector token" >&2; exit 2; }
  [[ "$(id -u)" == 0 ]] || { echo "run this as root" >&2; exit 1; }

  missing=()
  command -v curl >/dev/null || missing+=(curl ca-certificates)
  [[ -x /usr/sbin/sshd ]] || missing+=(openssh-server)
  if ((${#missing[@]} > 0)); then
    apt-get update -qq </dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" </dev/null
  fi

  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  chmod 600 /root/.ssh/authorized_keys
  grep -qxF "$key" /root/.ssh/authorized_keys || printf '%s\n' "$key" >>/root/.ssh/authorized_keys

  install -d -m 755 "$BIN"
  curl -fsSL -o "$BIN/cloudflared.part" "https://github.com/cloudflare/cloudflared/releases/download/$CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  printf '%s  %s\n' "$CLOUDFLARED_SHA256" "$BIN/cloudflared.part" | sha256sum --check --quiet
  chmod 755 "$BIN/cloudflared.part"
  mv "$BIN/cloudflared.part" "$BIN/cloudflared"

  install -d -m 700 "$ETC"
  (umask 077 && printf 'TUNNEL_TOKEN=%s\n' "$token" >"$ETC/tunnel.env")
  cat >"/etc/systemd/system/$UNIT.service" <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
EnvironmentFile=$ETC/tunnel.env
ExecStart=$BIN/cloudflared tunnel --no-autoupdate run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now "$UNIT"
  systemctl enable --now ssh
  sleep 5
  systemctl is-active --quiet "$UNIT" || { journalctl --no-pager --lines=30 --unit "$UNIT"; exit 1; }
  printf 'access ready, host key %s\n' "$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print $2}')"
}

main "$@"
