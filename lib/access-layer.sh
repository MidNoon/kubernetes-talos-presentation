readonly ACCESS_REMOTE_UNIT=talos-access
readonly ACCESS_REMOTE_BIN=/usr/local/lib/talos-access
readonly ACCESS_REMOTE_ETC=/etc/talos-access
readonly ACCESS_CONNECT_TIMEOUT=180
readonly ACCESS_FINGERPRINT_PATTERN='^SHA256:[A-Za-z0-9+/]{43}$'
readonly ACCESS_SERVE_TIMEOUT=3600
readonly ACCESS_API_PORT=18006
readonly ACCESS_DISK_STORAGE=lab-disks
readonly ACCESS_DISK_PATH=/var/lib/lab-disks

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
  printf "#!/usr/bin/env bash\nset -- '%s' '%s'\n" "$(<"$(access_key).pub")" "$(<"$ACCESS_STATE/connector-token")"
  tail -n +2 "$LAB_ROOT/tools/access-bootstrap.sh"
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

access_serve_stop() {
  kill "${ACCESS_SERVE_PIDS[@]}" 2>/dev/null || true
  rm -f "$ACCESS_SERVE_DIR"/*
  rmdir "$ACCESS_SERVE_DIR" 2>/dev/null || true
}

access_serve() {
  local secret port url deadline log
  access_load_config
  [[ -s "$ACCESS_STATE/bootstrap.sh" ]] || die "no bootstrap at $ACCESS_STATE/bootstrap.sh, run ./lab access up first"
  secret="$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  ACCESS_SERVE_DIR="$(mktemp -d)"
  ACCESS_SERVE_PIDS=()
  log="$ACCESS_STATE/serve.log"
  lab_on_exit access_serve_stop
  install -m 600 "$ACCESS_STATE/bootstrap.sh" "$ACCESS_SERVE_DIR/$secret"
  : >"$ACCESS_SERVE_DIR/index.html"
  uv run python -u -m http.server 0 --bind 127.0.0.1 --directory "$ACCESS_SERVE_DIR" >"$log.http" 2>&1 &
  ACCESS_SERVE_PIDS+=($!)
  deadline=$((SECONDS + 30))
  until port="$(grep -oE 'port [0-9]+' "$log.http" | head -1 | cut -d' ' -f2)" && [[ -n "$port" ]]; do
    ((SECONDS < deadline)) || die "the local file server did not start: $(cat "$log.http")"
    sleep 1
  done
  "$HOST_STATE/bin/cloudflared" tunnel --no-autoupdate --url "http://127.0.0.1:$port" >"$log" 2>&1 &
  ACCESS_SERVE_PIDS+=($!)
  deadline=$((SECONDS + 60))
  until url="$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$log" | head -1)" && [[ -n "$url" ]]; do
    ((SECONDS < deadline)) || die "Cloudflare gave no quick tunnel address within 60s: $(tail -5 "$log")"
    sleep 1
  done
  deadline=$((SECONDS + 120))
  until [[ "$(lab_public_curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$url/" 2>/dev/null)" == 200 ]]; do
    ((SECONDS < deadline)) || die "$url did not answer within 120s: $(tail -5 "$log")"
    sleep 3
  done
  log "bootstrap served once for up to $((ACCESS_SERVE_TIMEOUT / 60)) minutes. On the site host, as root, run:"
  printf '\n  curl -fsSL %s/%s | bash\n\n' "$url" "$secret"
  deadline=$((SECONDS + ACCESS_SERVE_TIMEOUT))
  until grep -qE "\"GET /$secret HTTP/[0-9.]+\" 200" "$log.http"; do
    ((SECONDS < deadline)) || die "nobody fetched the bootstrap within $((ACCESS_SERVE_TIMEOUT / 60)) minutes"
    sleep 2
  done
  log "bootstrap fetched, the address is closed. Run ./lab access verify with the host key the site host printed"
}

access_render_target() {
  local node="$1" secret="$2" pin="$3"
  printf 'PVE_URL=%q\n' "https://127.0.0.1:$ACCESS_API_PORT"
  printf 'PVE_NODE=%q\n' "$node"
  printf 'PVE_TOKEN_ID=%q\n' "$PVE_API_USER!$PVE_API_TOKEN_NAME"
  printf 'PVE_TOKEN_SECRET=%q\n' "$secret"
  printf 'PVE_TLS_PIN=%q\n' "$pin"
  printf 'PVE_DISK_STORAGE=%q\n' "$ACCESS_DISK_STORAGE"
  printf 'PVE_SSH=%q\n' "root@$(cf_access_hostname)"
  printf 'PVE_SSH_KEY=%q\n' "$(access_key)"
  printf 'PVE_SSH_KNOWN_HOSTS=%q\n' "$(access_known_hosts)"
  printf 'PVE_SSH_ACCESS=%q\n' "$ACCESS_STATE/service-token.env"
}

access_target() {
  local target="$LAB_STATE/pve-target.env" remote node secret pin version
  access_load_config
  access_use_target || exit 1
  if [[ -e "$target" ]] && ! grep -qxF "PVE_SSH=$PVE_SSH" "$target"; then
    die "$target points at another Proxmox host ($(grep -E '^PVE_SSH=' "$target")). Move it aside first"
  fi
  remote="$(pve_remote USER="$PVE_API_USER" TOKEN="$PVE_API_TOKEN_NAME" ROLES="$PVE_API_ROLES" \
    STORAGE="$ACCESS_DISK_STORAGE" STORAGE_PATH="$ACCESS_DISK_PATH" <<'EOF'
set -euo pipefail
command -v pveum >/dev/null || { echo "Proxmox VE is not installed on $(hostname)" >&2; exit 1; }
pveum user list --output-format json | grep -q "\"userid\":\"$USER\"" || pveum user add "$USER"
pveum acl modify / --users "$USER" --roles "$ROLES"
pveum user token remove "$USER" "$TOKEN" >/dev/null 2>&1 || true
secret="$(pveum user token add "$USER" "$TOKEN" --privsep 0 --output-format json | sed -n 's/.*"value":"\([^"]*\)".*/\1/p')"
if ! grep -qxE "dir: $STORAGE" /etc/pve/storage.cfg 2>/dev/null; then
  install -d -m 700 "$STORAGE_PATH"
  pvesm add dir "$STORAGE" --path "$STORAGE_PATH" --content images,rootdir >/dev/null
fi
pin="$(openssl s_client -connect 127.0.0.1:8006 </dev/null 2>/dev/null | openssl x509 -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64)"
printf 'node=%s\nsecret=%s\npin=%s\n' "$(hostname)" "$secret" "$pin"
EOF
  )" || die "could not create the API token and storage on $PVE_SSH"
  node="$(sed -n 's/^node=//p' <<<"$remote")"
  secret="$(sed -n 's/^secret=//p' <<<"$remote")"
  pin="$(sed -n 's/^pin=//p' <<<"$remote")"
  local LAB_SCRUB="$secret"
  [[ -n "$node" && "$secret" =~ ^[0-9a-f-]{36}$ && "$pin" =~ ^[A-Za-z0-9+/]{43}=$ ]] ||
    die "the site host returned an unexpected node, token or pin: $(lab_scrub "$remote")"
  (
    umask 077
    access_render_target "$node" "$secret" "$pin" >"$target"
  )
  pve_load_target || exit 1
  version="$(pve_api GET /version | jq -r .data.version)" || exit 1
  log "$target reaches Proxmox $version on $node through Cloudflare Access, with VM disks on $ACCESS_DISK_STORAGE"
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
    pve_ssh "systemd-run --quiet --collect --on-active=5 /bin/sh -c $(printf '%q' "systemctl disable --now $ACCESS_REMOTE_UNIT; systemctl disable --now $CAMPUS_UNIT; nft delete table inet $CAMPUS_TABLE; rm -f /etc/systemd/system/$ACCESS_REMOTE_UNIT.service /etc/systemd/system/$CAMPUS_UNIT.service $CAMPUS_RULES $CAMPUS_OPEN; systemctl daemon-reload; rm -rf $ACCESS_REMOTE_BIN $ACCESS_REMOTE_ETC; sed -i '\\|$pubkey|d' /root/.ssh/authorized_keys")" ||
      die "could not schedule removal of the access connector on $PVE_SSH"
    log "the site host removes its access connector, its campus rules and our key in 5 seconds"
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
