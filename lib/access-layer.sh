readonly ACCESS_REMOTE_UNIT=talos-access
readonly ACCESS_REMOTE_BIN=/usr/local/lib/talos-access
readonly ACCESS_REMOTE_ETC=/etc/talos-access
readonly ACCESS_CONNECT_TIMEOUT=180
readonly ACCESS_FINGERPRINT_PATTERN='^SHA256:[A-Za-z0-9+/]{43}$'

ACCESS_STATE="$LAB_STATE/access"

access_key() {
  printf '%s/ssh/id_ed25519' "$ACCESS_STATE"
}

access_known_hosts() {
  printf '%s/ssh/known_hosts' "$ACCESS_STATE"
}

access_load_config() {
  lab_load_config
  mkdir -p "$ACCESS_STATE/ssh" "$HOST_STATE/bin"
  chmod 700 "$ACCESS_STATE" "$ACCESS_STATE/ssh"
}

access_use_target() {
  PVE_SSH="root@$(cf_access_hostname)"
  PVE_SSH_KEY="$(access_key)"
  PVE_SSH_KNOWN_HOSTS="$(access_known_hosts)"
  PVE_SSH_ACCESS="$ACCESS_STATE/service-token.env"
  pve_access_env
}

access_ensure_key() {
  [[ -s "$(access_key)" ]] && return 0
  ssh-keygen -q -t ed25519 -N '' -C talos-lab-access -f "$(access_key)"
  log "SSH key for the site host created at $(access_key).pub"
}

access_render_ingress() {
  jq -nc --arg host "$(cf_access_hostname)" '[{hostname: $host, service: "ssh://localhost:22"}, {service: "http_status:404"}]'
}

access_ensure_service_token() {
  local raw id secret
  if [[ -n "$CF_ACCESS_TOKEN_ID" && -s "$ACCESS_STATE/service-token.env" && "$(cat "$ACCESS_STATE/service-token-id" 2>/dev/null)" == "$CF_ACCESS_TOKEN_ID" ]]; then
    return 0
  fi
  if [[ -n "$CF_ACCESS_TOKEN_ID" ]]; then
    cf_query zero-trust access service-tokens delete "$CF_ACCESS_TOKEN_ID" --force >/dev/null || return 1
    log "service token $CF_ACCESS_NAME replaced, because its secret is not stored in $ACCESS_STATE"
  fi
  raw="$(cf_query zero-trust access service-tokens create --name "$CF_ACCESS_NAME")" || return 1
  id="$(jq -r '(.result // .) | .client_id // empty' <<<"$raw" 2>/dev/null)"
  secret="$(jq -r '(.result // .) | .client_secret // empty' <<<"$raw" 2>/dev/null)"
  CF_ACCESS_TOKEN_ID="$(jq -r '(.result // .) | .id // empty' <<<"$raw" 2>/dev/null)"
  local LAB_SCRUB="$secret"
  [[ -n "$id" && -n "$secret" && -n "$CF_ACCESS_TOKEN_ID" ]] || {
    fail "Cloudflare returned a service token in an unexpected format, with keys $(jq -c '(.result // .) | keys' <<<"$raw" 2>/dev/null)"
    return 1
  }
  (
    umask 077
    printf 'TUNNEL_SERVICE_TOKEN_ID=%s\nTUNNEL_SERVICE_TOKEN_SECRET=%s\n' "$id" "$secret" >"$ACCESS_STATE/service-token.env"
    printf '%s\n' "$CF_ACCESS_TOKEN_ID" >"$ACCESS_STATE/service-token-id"
  )
  ACCESS_TOKEN_CHANGED=1
  log "service token $CF_ACCESS_NAME created"
}

access_render_app() {
  jq -nc --arg name "$CF_ACCESS_NAME" --arg domain "$(cf_access_hostname)" --arg token "$CF_ACCESS_TOKEN_ID" '{
    name: $name,
    domain: $domain,
    type: "self_hosted",
    session_duration: "24h",
    app_launcher_visible: false,
    policies: [{name: $name, decision: "non_identity", include: [{service_token: {token_id: $token}}]}]
  }'
}

access_ensure_app() {
  if [[ -n "$CF_ACCESS_APP_ID" && -z "${ACCESS_TOKEN_CHANGED:-}" ]]; then
    return 0
  fi
  if [[ -n "$CF_ACCESS_APP_ID" ]]; then
    cf_query zero-trust access applications delete "$CF_ACCESS_APP_ID" --force >/dev/null || return 1
  fi
  cf_query zero-trust access applications create --body "$(access_render_app)" >/dev/null || return 1
  log "Access application $CF_ACCESS_NAME admits only service token $CF_ACCESS_NAME to $(cf_access_hostname)"
}

access_render_bootstrap() {
  local key token url
  key="$(<"$(access_key).pub")"
  token="$(<"$ACCESS_STATE/connector-token")"
  url="https://github.com/cloudflare/cloudflared/releases/download/$HOST_CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  cat <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\$(id -u)" == 0 ]] || { echo "run this as root" >&2; exit 1; }
missing=()
command -v curl >/dev/null || missing+=(curl ca-certificates)
[[ -x /usr/sbin/sshd ]] || missing+=(openssh-server)
if ((\${#missing[@]} > 0)); then
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "\${missing[@]}"
fi
install -d -m 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
grep -qxF '$key' /root/.ssh/authorized_keys || printf '%s\n' '$key' >>/root/.ssh/authorized_keys
install -d -m 755 $ACCESS_REMOTE_BIN
curl -fsSL -o $ACCESS_REMOTE_BIN/cloudflared.part $url
printf '%s  %s\n' $HOST_CLOUDFLARED_SHA256 $ACCESS_REMOTE_BIN/cloudflared.part | sha256sum --check --quiet
chmod 755 $ACCESS_REMOTE_BIN/cloudflared.part
mv $ACCESS_REMOTE_BIN/cloudflared.part $ACCESS_REMOTE_BIN/cloudflared
install -d -m 700 $ACCESS_REMOTE_ETC
(umask 077 && printf 'TUNNEL_TOKEN=%s\n' '$token' >$ACCESS_REMOTE_ETC/tunnel.env)
cat >/etc/systemd/system/$ACCESS_REMOTE_UNIT.service <<'UNIT'
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
EnvironmentFile=$ACCESS_REMOTE_ETC/tunnel.env
ExecStart=$ACCESS_REMOTE_BIN/cloudflared tunnel --no-autoupdate run
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now $ACCESS_REMOTE_UNIT
systemctl enable --now ssh
sleep 5
systemctl is-active --quiet $ACCESS_REMOTE_UNIT
printf 'access ready, host key %s\n' "\$(ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub | awk '{print \$2}')"
EOF
}

access_up() {
  local before after
  access_load_config
  before="$(cf_snapshot_access_others)" || exit 1
  access_ensure_key
  host_fetch_verified cloudflared "$HOST_CLOUDFLARED_SHA256" "$HOST_STATE/bin/cloudflared" 755 \
    "https://github.com/cloudflare/cloudflared/releases/download/$HOST_CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  (
    LAB_TUNNEL_NAME="$CF_ACCESS_NAME"
    LAB_TUNNEL_HOSTNAME="$(cf_access_hostname)"
    tunnel_ensure || exit 1
    access_render_ingress >"$ACCESS_STATE/tunnel-ingress.json"
    tunnel_set_ingress "$ACCESS_STATE/tunnel-ingress.json" || exit 1
    tunnel_ensure_dns || exit 1
    tunnel_store_connector_token "$ACCESS_STATE/connector-token" || exit 1
  ) || exit 1
  chmod 600 "$ACCESS_STATE/connector-token"
  cf_lookup_access || exit 1
  access_ensure_service_token || exit 1
  access_ensure_app || exit 1
  (
    umask 077
    access_render_bootstrap >"$ACCESS_STATE/bootstrap.sh"
  )
  after="$(cf_snapshot_access_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during access up. Before: $before. After: $after"
  log "access ready at $(cf_access_hostname). Run $ACCESS_STATE/bootstrap.sh as root on the site host, then ./lab access verify with the host key it prints"
}

access_record_host_key() {
  local expected="$1" scratch="$ACCESS_STATE/ssh/known_hosts.new" deadline=$((SECONDS + ACCESS_CONNECT_TIMEOUT)) seen output
  [[ "$expected" =~ $ACCESS_FINGERPRINT_PATTERN ]] ||
    die "no host key is recorded for $(cf_access_hostname). Pass the host key the bootstrap printed: ./lab access verify SHA256:..."
  pve_ssh_options
  until : >"$scratch" && output="$(ssh -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$scratch" -o HostKeyAlgorithms=ssh-ed25519 \
    "${PVE_SSH_OPTIONS[@]}" "$PVE_SSH" true 2>&1)"; do
    ((SECONDS < deadline)) || die "could not reach $PVE_SSH through Cloudflare Access within ${ACCESS_CONNECT_TIMEOUT}s: $output"
    sleep 5
  done
  seen="$(ssh-keygen -lf "$scratch" | awk '{print $2}')"
  if [[ "$seen" != "$expected" ]]; then
    rm -f "$scratch"
    die "$(cf_access_hostname) presented host key $seen, not $expected. Nothing was recorded"
  fi
  mv "$scratch" "$(access_known_hosts)"
  log "host key $seen recorded for $(cf_access_hostname)"
}

access_verify() {
  local expected="${1:-}" identity
  access_load_config
  access_use_target || exit 1
  if ! ssh-keygen -F "$(cf_access_hostname)" -f "$(access_known_hosts)" >/dev/null 2>&1; then
    access_record_host_key "$expected"
  elif [[ -n "$expected" ]] && ! ssh-keygen -lf "$(access_known_hosts)" | awk '{print $2}' | grep -qxF "$expected"; then
    die "$(cf_access_hostname) is recorded with host key $(ssh-keygen -lf "$(access_known_hosts)" | awk '{print $2}' | paste -sd' '), not $expected"
  fi
  identity="$(pve_ssh 'printf "%s, %s, %s\n" "$(hostname)" "$(. /etc/os-release && printf %s "$PRETTY_NAME")" "$(pveversion 2>/dev/null || printf "no Proxmox VE")"')" ||
    die "could not run a command on $PVE_SSH through Cloudflare Access"
  log "reached $identity through $(cf_access_hostname) with Cloudflare Access"
}

access_ssh() {
  access_load_config
  access_use_target || exit 1
  pve_ssh "$@"
}

access_down() {
  local before after pubkey leftovers=()
  access_load_config
  before="$(cf_snapshot_access_others)" || exit 1
  if [[ -s "$(access_known_hosts)" && -s "$ACCESS_STATE/service-token.env" ]] && access_use_target && pve_ssh true 2>/dev/null; then
    pubkey="$(awk '{print $2}' "$(access_key).pub")"
    pve_ssh "systemd-run --quiet --collect --on-active=5 /bin/sh -c $(printf '%q' "systemctl disable --now $ACCESS_REMOTE_UNIT; rm -f /etc/systemd/system/$ACCESS_REMOTE_UNIT.service; systemctl daemon-reload; rm -rf $ACCESS_REMOTE_BIN $ACCESS_REMOTE_ETC; sed -i '\\|$pubkey|d' /root/.ssh/authorized_keys")" ||
      die "could not schedule removal of the access connector on $PVE_SSH"
    log "the site host removes its access connector and our key in 5 seconds"
  else
    log "the site host is not reachable through $(cf_access_hostname), removing the Cloudflare side only"
  fi
  cf_lookup_access || exit 1
  if [[ -n "$CF_ACCESS_APP_ID" ]]; then
    cf_query zero-trust access applications delete "$CF_ACCESS_APP_ID" --force >/dev/null || exit 1
    log "Access application $CF_ACCESS_NAME removed"
  fi
  if [[ -n "$CF_ACCESS_TOKEN_ID" ]]; then
    cf_query zero-trust access service-tokens delete "$CF_ACCESS_TOKEN_ID" --force >/dev/null || exit 1
    log "service token $CF_ACCESS_NAME removed"
  fi
  (
    LAB_TUNNEL_NAME="$CF_ACCESS_NAME"
    LAB_TUNNEL_HOSTNAME="$(cf_access_hostname)"
    tunnel_remove_dns || exit 1
    tunnel_remove || exit 1
  ) || exit 1
  rm -f "$ACCESS_STATE/connector-token" "$ACCESS_STATE/service-token.env" "$ACCESS_STATE/service-token-id" \
    "$ACCESS_STATE/bootstrap.sh" "$ACCESS_STATE/tunnel-ingress.json" "$(access_known_hosts)"
  cf_lookup_access || exit 1
  [[ -z "$CF_ACCESS_APP_ID" ]] || leftovers+=("Access application $CF_ACCESS_APP_ID")
  [[ -z "$CF_ACCESS_TOKEN_ID" ]] || leftovers+=("service token $CF_ACCESS_TOKEN_ID")
  (
    LAB_TUNNEL_NAME="$CF_ACCESS_NAME"
    LAB_TUNNEL_HOSTNAME="$(cf_access_hostname)"
    cf_lookup_tunnel && cf_lookup_dns_record || exit 1
    [[ -z "$CF_LAB_TUNNEL_ID" && -z "$CF_LAB_DNS_RECORD_ID" ]]
  ) || leftovers+=("tunnel or DNS record for $(cf_access_hostname)")
  ((${#leftovers[@]} == 0)) || die "access teardown left resources behind: ${leftovers[*]}"
  after="$(cf_snapshot_access_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during access down. Before: $before. After: $after"
  log "access removed, the key pair stays at $(access_key)"
}
