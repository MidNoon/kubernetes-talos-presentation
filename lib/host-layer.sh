readonly HOST_SDN_ZONE=talab
readonly HOST_VNET=talabnet
readonly HOST_SUBNET=10.88.0.0/24
readonly HOST_GATEWAY=10.88.0.1
readonly HOST_DHCP_START=10.88.0.100
readonly HOST_DHCP_END=10.88.0.199
readonly HOST_OMNI_VERSION=v1.13.3
readonly HOST_DEX_IMAGE=ghcr.io/dexidp/dex@sha256:65b72ca0f4b0bf6d4ada84ec21da8851782563404ac7b8f926923d27ceced9ab
readonly HOST_DEX_SHA256=e73fe3d2c9efc03551c62fcc5694acec8db1f36a79110f30070d2dc84c2951d1
readonly HOST_CLOUDFLARED_VERSION=2026.11.0
readonly HOST_CLOUDFLARED_SHA256=51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd
readonly HOST_OMNI_API_PORT=8080
readonly HOST_OMNI_K8S_PORT=8095
readonly HOST_OMNI_METRICS_PORT=2122
readonly HOST_DEX_PORT=5556
readonly HOST_MACHINE_API_PORT=8090
readonly HOST_WIREGUARD_PORT=50180
readonly HOST_TUNNEL_NAME=talos-lab-host
readonly HOST_HOST_LABELS=(omni kube auth pve)
readonly HOST_REMOTE_BIN=/usr/local/lib/talos-lab
readonly HOST_REMOTE_ETC=/etc/talos-lab
readonly HOST_REMOTE_DATA=/var/lib/talos-lab/omni
readonly HOST_SERVICES=(talos-lab-dex talos-lab-cloudflared talos-lab-omni)
readonly HOST_READY_TIMEOUT=300

HOST_STATE="$LAB_STATE/host"

host_name() {
  printf '%s.%s' "$1" "$LAB_TUNNEL_ZONE"
}

HOST_OMNI_FORWARD=""

host_omni_forward_close() {
  pve_ssh_forward_close "$HOST_STATE/omni-forward.sock"
  HOST_OMNI_FORWARD=""
}

host_omni_forward_open() {
  local port
  [[ -n "$HOST_OMNI_FORWARD" ]] && return 0
  for port in $(seq 18080 18099); do
    if pve_ssh_forward_open "$HOST_STATE/omni-forward.sock" "127.0.0.1:$port:127.0.0.1:$HOST_OMNI_API_PORT"; then
      HOST_OMNI_FORWARD="http://127.0.0.1:$port"
      lab_on_exit host_omni_forward_close
      return 0
    fi
  done
  fail "could not forward a local port from 18080 to 18099 to Omni on $PVE_SSH"
}

host_omnictl() {
  local key="$HOST_STATE/omni-service-account.key"
  [[ -s "$key" ]] || {
    fail "Omni service account key missing at $key, run ./lab host up first"
    return 1
  }
  host_omni_forward_open || return 1
  OMNI_ENDPOINT="$HOST_OMNI_FORWARD" OMNI_SERVICE_ACCOUNT_KEY="$(<"$key")" \
    timeout "${LAB_OMNI_TIMEOUT:-120}" "$HOST_STATE/bin/omnictl/omnictl-linux-amd64" "$@"
}

host_omni_release_file() {
  local name="$1" target="$2" sums="$HOST_STATE/bin/omni.sha256sum.txt"
  if [[ ! -s "$sums" ]]; then
    curl --fail --silent --show-error --location --output "$sums" \
      "https://github.com/siderolabs/omni/releases/download/$HOST_OMNI_VERSION/sha256sum.txt"
  fi
  [[ -x "$target" ]] && return 0
  log "downloading $name $HOST_OMNI_VERSION"
  curl --fail --silent --show-error --location --output "$target.part" \
    "https://github.com/siderolabs/omni/releases/download/$HOST_OMNI_VERSION/$name"
  [[ "$(sha256sum "$target.part" | cut -d' ' -f1)" == "$(awk -v n="$name" '$2 == n {print $1}' "$sums")" ]] ||
    die "$name does not match the published sha256sum.txt for $HOST_OMNI_VERSION"
  chmod 755 "$target.part"
  mv "$target.part" "$target"
}

host_load_config() {
  local var
  lab_load_config
  cf_load_config
  for var in LAB_OMNI_EULA_NAME LAB_OMNI_EULA_EMAIL; do
    [[ -n "${!var:-}" ]] || die "config does not set $var, which Omni needs to start"
  done
  pve_load_target || exit 1
  mkdir -p "$HOST_STATE"
}

host_fetch_binaries() {
  local dir="$HOST_STATE/bin" cid platform
  mkdir -p "$dir/omnictl"
  host_omni_release_file omni-linux-amd64 "$dir/omni"
  for platform in darwin-amd64 darwin-arm64 linux-amd64 linux-arm64 windows-amd64.exe; do
    host_omni_release_file "omnictl-$platform" "$dir/omnictl/omnictl-$platform"
  done
  if [[ ! -x "$dir/dex" ]]; then
    log "extracting dex from $HOST_DEX_IMAGE"
    docker pull --quiet "$HOST_DEX_IMAGE" >/dev/null
    cid="$(docker create "$HOST_DEX_IMAGE")"
    docker cp --quiet "$cid:/usr/local/bin/dex" "$dir/dex.part"
    docker rm --force "$cid" >/dev/null
    [[ "$(sha256sum "$dir/dex.part" | cut -d' ' -f1)" == "$HOST_DEX_SHA256" ]] ||
      die "dex binary from $HOST_DEX_IMAGE does not match $HOST_DEX_SHA256"
    chmod 755 "$dir/dex.part"
    mv "$dir/dex.part" "$dir/dex"
  fi
  if [[ ! -x "$dir/cloudflared" ]]; then
    log "downloading cloudflared $HOST_CLOUDFLARED_VERSION"
    curl --fail --silent --show-error --location --output "$dir/cloudflared.part" \
      "https://github.com/cloudflare/cloudflared/releases/download/$HOST_CLOUDFLARED_VERSION/cloudflared-linux-amd64"
    [[ "$(sha256sum "$dir/cloudflared.part" | cut -d' ' -f1)" == "$HOST_CLOUDFLARED_SHA256" ]] ||
      die "cloudflared-linux-amd64 does not match $HOST_CLOUDFLARED_SHA256"
    chmod 755 "$dir/cloudflared.part"
    mv "$dir/cloudflared.part" "$dir/cloudflared"
  fi
}

host_random_password() {
  openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | cut -c1-16
}

host_ensure_user() {
  local username="$1" users="$HOST_STATE/users.tsv" password hash
  touch "$users"
  if awk -F'\t' -v u="$username" '$1 == u {found = 1} END {exit !found}' "$users"; then
    return 0
  fi
  password="$(host_random_password)"
  hash="$(uv run --quiet --with bcrypt python -c 'import bcrypt, sys; print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(10)).decode())' "$password")"
  [[ "$hash" == '$2'* ]] || die "could not hash the password for $username"
  printf '%s\t%s\t%s\t%s\t%s\n' "$username" "$username@$LAB_TUNNEL_ZONE" "$password" "$hash" "$(uuidgen)" >>"$users"
}

host_ensure_secrets() {
  local gnupg fingerprint
  [[ -s "$HOST_STATE/account-id" ]] || uuidgen >"$HOST_STATE/account-id"
  [[ -s "$HOST_STATE/dex-client-secret" ]] || openssl rand -hex 32 >"$HOST_STATE/dex-client-secret"
  if [[ ! -s "$HOST_STATE/omni.asc" ]]; then
    gnupg="$(mktemp -d)"
    GNUPGHOME="$gnupg" gpg --batch --quiet --passphrase '' --quick-generate-key \
      "Omni etcd encryption <omni@talos-lab.invalid>" rsa4096 cert never 2>/dev/null
    fingerprint="$(GNUPGHOME="$gnupg" gpg --with-colons --list-keys omni@talos-lab.invalid 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')"
    [[ -n "$fingerprint" ]] || die "could not generate the Omni etcd encryption key"
    GNUPGHOME="$gnupg" gpg --batch --quiet --passphrase '' --quick-add-key "$fingerprint" rsa4096 encr never 2>/dev/null
    GNUPGHOME="$gnupg" gpg --batch --quiet --export-secret-key --armor omni@talos-lab.invalid >"$HOST_STATE/omni.asc"
    gpgconf --homedir "$gnupg" --kill all 2>/dev/null || true
    rm -rf "$gnupg"
    [[ -s "$HOST_STATE/omni.asc" ]] || die "could not export the Omni etcd encryption key"
  fi
  host_ensure_user instructor
}

host_render_dex() {
  local users="$HOST_STATE/users.tsv"
  jq -n \
    --arg issuer "https://$(host_name auth)" \
    --arg listen "127.0.0.1:$HOST_DEX_PORT" \
    --arg secret "$(<"$HOST_STATE/dex-client-secret")" \
    --arg redirect "https://$(host_name omni)/oidc/consume" \
    --rawfile users "$users" \
    '{
      issuer: $issuer,
      storage: {type: "memory"},
      web: {http: $listen},
      oauth2: {skipApprovalScreen: true, passwordConnector: "local"},
      staticClients: [{id: "omni", name: "Omni", secret: $secret, redirectURIs: [$redirect]}],
      enablePasswordDB: true,
      staticPasswords: [
        $users | split("\n")[] | select(length > 0) | split("\t")
        | {username: .[0], email: .[1], hash: .[3], userID: .[4]}
      ]
    }'
}

host_render_omni_config() {
  jq -n --arg secret "$(<"$HOST_STATE/dex-client-secret")" '{auth: {oidc: {clientSecret: $secret}}}'
}

host_render_omni_unit() {
  cat <<EOF
[Unit]
After=network-online.target networking.service
Wants=network-online.target

[Service]
WorkingDirectory=$HOST_REMOTE_BIN
ExecStart=$HOST_REMOTE_BIN/omni \\
  --config-path=$HOST_REMOTE_ETC/omni.yaml \\
  --name=talos-lab \\
  --account-id=$(<"$HOST_STATE/account-id") \\
  --eula-accept-name="$LAB_OMNI_EULA_NAME" \\
  --eula-accept-email=$LAB_OMNI_EULA_EMAIL \\
  --private-key-source=file://$HOST_REMOTE_ETC/omni.asc \\
  --etcd-embedded-db-path=$HOST_REMOTE_DATA/etcd \\
  --sqlite-storage-path=$HOST_REMOTE_DATA/omni.db \\
  --bind-addr=127.0.0.1:$HOST_OMNI_API_PORT \\
  --advertised-api-url=https://$(host_name omni) \\
  --k8s-proxy-bind-addr=127.0.0.1:$HOST_OMNI_K8S_PORT \\
  --advertised-kubernetes-proxy-url=https://$(host_name kube) \\
  --metrics-bind-addr=127.0.0.1:$HOST_OMNI_METRICS_PORT \\
  --machine-api-bind-addr=$HOST_GATEWAY:$HOST_MACHINE_API_PORT \\
  --machine-api-advertised-url=grpc://$HOST_GATEWAY:$HOST_MACHINE_API_PORT \\
  --siderolink-wireguard-bind-addr=$HOST_GATEWAY:$HOST_WIREGUARD_PORT \\
  --siderolink-wireguard-advertised-addr=$HOST_GATEWAY:$HOST_WIREGUARD_PORT \\
  --auth-oidc-enabled \\
  --auth-oidc-provider-url=https://$(host_name auth) \\
  --auth-oidc-client-id=omni \\
  --auth-oidc-scopes=openid,profile,email \\
  --initial-users=instructor@$LAB_TUNNEL_ZONE \\
  --create-initial-service-account \\
  --initial-service-account-role=Admin \\
  --initial-service-account-lifetime=8760h \\
  --initial-service-account-key-path=$HOST_REMOTE_DATA/initial-service-account.key
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

host_render_dex_unit() {
  cat <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
LoadCredential=dex.json:$HOST_REMOTE_ETC/dex.json
ExecStart=$HOST_REMOTE_BIN/dex serve %d/dex.json
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

host_render_cloudflared_unit() {
  cat <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
DynamicUser=yes
EnvironmentFile=$HOST_REMOTE_ETC/cloudflared.env
ExecStart=$HOST_REMOTE_BIN/cloudflared tunnel --no-autoupdate --metrics 127.0.0.1:2000 run
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

host_stage() {
  local stage="$HOST_STATE/stage"
  rm -rf "$stage"
  mkdir -p "$stage/etc" "$stage/units"
  host_render_dex >"$stage/etc/dex.json"
  host_render_omni_config >"$stage/etc/omni.yaml"
  cp "$HOST_STATE/omni.asc" "$stage/etc/omni.asc"
  printf 'TUNNEL_TOKEN=%s\n' "$(<"$HOST_STATE/connector-token")" >"$stage/etc/cloudflared.env"
  host_render_omni_unit >"$stage/units/talos-lab-omni.service"
  host_render_dex_unit >"$stage/units/talos-lab-dex.service"
  host_render_cloudflared_unit >"$stage/units/talos-lab-cloudflared.service"
}

host_remote() {
  pve_ssh "$(printf '%q ' env "$@") bash -s"
}

host_prepare_packages() {
  host_remote <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
for source in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
  if [[ -f "$source" ]] && ! grep -qx 'Enabled: no' "$source"; then
    printf 'Enabled: no\n' >>"$source"
  fi
done
if ! dpkg-query -W -f '${Status}' dnsmasq 2>/dev/null | grep -q 'install ok installed'; then
  apt-get update -qq
  apt-get install -y -qq dnsmasq >/dev/null
fi
systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true
EOF
  log "host packages ready"
}

host_ensure_sdn() {
  local dns
  dns="$(pve_ssh "awk '/^nameserver/ {print \$2; exit}' /etc/resolv.conf")"
  [[ -n "$dns" ]] || die "the Proxmox host has no nameserver in /etc/resolv.conf"
  host_remote ZONE="$HOST_SDN_ZONE" VNET="$HOST_VNET" SUBNET="$HOST_SUBNET" GATEWAY="$HOST_GATEWAY" \
    DHCP_START="$HOST_DHCP_START" DHCP_END="$HOST_DHCP_END" DNS="$dns" <<'EOF'
set -euo pipefail
subnet_id="$ZONE-${SUBNET/\//-}"
if ! pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
  pvesh create /cluster/sdn/zones --zone "$ZONE" --type simple --dhcp dnsmasq --ipam pve >/dev/null
fi
if ! pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
  pvesh create /cluster/sdn/vnets --vnet "$VNET" --zone "$ZONE" >/dev/null
fi
if ! pvesh get "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null 2>&1; then
  pvesh create "/cluster/sdn/vnets/$VNET/subnets" --subnet "$SUBNET" --type subnet \
    --gateway "$GATEWAY" --snat 1 --dhcp-dns-server "$DNS" \
    --dhcp-range "start-address=$DHCP_START,end-address=$DHCP_END" >/dev/null
fi
pvesh set /cluster/sdn >/dev/null
for attempt in $(seq 1 60); do
  if ip -4 addr show dev "$VNET" 2>/dev/null | grep -q "inet $GATEWAY/"; then
    exit 0
  fi
  sleep 1
done
echo "vnet $VNET did not get $GATEWAY within 60s" >&2
ip -4 addr >&2
exit 1
EOF
  log "SDN zone $HOST_SDN_ZONE with vnet $HOST_VNET on $HOST_SUBNET, gateway $HOST_GATEWAY, DHCP and SNAT"
}

host_upload_binaries() {
  local name local_sum remote_sum
  pve_ssh "mkdir -p $HOST_REMOTE_BIN/omnictl $HOST_REMOTE_ETC $HOST_REMOTE_DATA && chmod 700 $HOST_REMOTE_ETC $HOST_REMOTE_DATA"
  for name in omni dex cloudflared omnictl/omnictl-{darwin-amd64,darwin-arm64,linux-amd64,linux-arm64,windows-amd64.exe}; do
    local_sum="$(sha256sum "$HOST_STATE/bin/$name" | cut -d' ' -f1)"
    remote_sum="$(pve_ssh "sha256sum $HOST_REMOTE_BIN/$name 2>/dev/null | cut -d' ' -f1" || true)"
    if [[ "$local_sum" != "$remote_sum" ]]; then
      pve_scp "$HOST_STATE/bin/$name" "$PVE_SSH:$HOST_REMOTE_BIN/$name.part"
      pve_ssh "chmod 755 $HOST_REMOTE_BIN/$name.part && mv $HOST_REMOTE_BIN/$name.part $HOST_REMOTE_BIN/$name"
      log "uploaded $name"
    fi
  done
}

host_install_stage() {
  pve_scp -r "$HOST_STATE/stage" "$PVE_SSH:/root/talos-lab-stage"
  host_remote ETC="$HOST_REMOTE_ETC" <<'EOF'
set -euo pipefail
trap 'rm -rf /root/talos-lab-stage' EXIT
for file in /root/talos-lab-stage/etc/*; do
  install -m 600 -o root -g root "$file" "$ETC/$(basename "$file")"
done
for unit in /root/talos-lab-stage/units/*; do
  install -m 644 -o root -g root "$unit" "/etc/systemd/system/$(basename "$unit")"
done
systemctl daemon-reload
EOF
}

host_restart() {
  pve_ssh "systemctl enable --quiet $* && systemctl restart $*"
}

host_service_logs() {
  local service
  for service in "${HOST_SERVICES[@]}"; do
    printf '== %s\n' "$service"
    pve_ssh "systemctl status --no-pager --lines=0 $service; journalctl --no-pager --lines=60 --unit $service" 2>&1 || true
  done
}

host_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/host-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  host_service_logs >"$dir/services.txt" 2>&1 || true
  pve_ssh "ip -4 addr; ip -4 route; ss -ltnup" >"$dir/network.txt" 2>&1 || true
  pve_ssh "pvesh get /cluster/sdn/vnets --output-format json-pretty; cat /etc/pve/sdn/*.cfg" >"$dir/sdn.txt" 2>&1 || true
  for label in "${HOST_HOST_LABELS[@]}"; do
    lab_public_curl --silent --show-error --max-time 15 --verbose --output /dev/null "https://$(host_name "$label")/" >"$dir/curl-$label.txt" 2>&1 || true
  done
  die "$reason. Context saved in $dir"
}

host_wait_local() {
  local name="$1" url="$2" deadline=$((SECONDS + HOST_READY_TIMEOUT))
  until pve_ssh "curl --silent --max-time 5 --output /dev/null $url"; do
    ((SECONDS < deadline)) || host_capture_failure "$name did not answer at $url on the host within ${HOST_READY_TIMEOUT}s"
    sleep 3
  done
  log "$name answering at $url on the host"
}

host_wait_public() {
  local name="$1" url="$2" deadline=$((SECONDS + HOST_READY_TIMEOUT)) code
  until code="$(lab_public_curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$url")" && [[ "$code" =~ ^[23] ]]; do
    ((SECONDS < deadline)) || host_capture_failure "$name did not answer publicly at $url within ${HOST_READY_TIMEOUT}s, last status ${code:-none}"
    sleep 5
  done
  log "$name answering publicly at $url with status $code"
}

host_snapshot_others() {
  local tunnels records hosts
  tunnels="$(cf_query tunnels list --is-deleted false --per-page 1000)" || return 1
  records="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --per-page 5000)" || return 1
  hosts="$(for label in "${HOST_HOST_LABELS[@]}"; do host_name "$label"; printf '\n'; done | jq -R . | jq -sc .)"
  jq -r --arg name "$HOST_TUNNEL_NAME" \
    '(if type == "object" and has("result") then .result else . end)[] | select(.name != $name) | "tunnel \(.id) \(.name)"' <<<"$tunnels" | sort || return 1
  jq -r --argjson hosts "$hosts" \
    '(if type == "object" and has("result") then .result else . end)[] | select(.name as $n | $hosts | index($n) | not) | "dns \(.id) \(.name) \(.type) \(.content)"' <<<"$records" | sort
}

host_tunnel_provision() {
  local ingress="$HOST_STATE/tunnel-ingress.json" label
  (
    LAB_TUNNEL_NAME="$HOST_TUNNEL_NAME"
    LAB_TUNNEL_TOKEN_FILE="$HOST_STATE/connector-token"
    cf_lookup_tunnel || exit 1
    if [[ -z "$CF_LAB_TUNNEL_ID" ]]; then
      cf_query tunnels create --name "$LAB_TUNNEL_NAME" --config-source cloudflare >/dev/null || exit 1
      cf_lookup_tunnel || exit 1
      [[ -n "$CF_LAB_TUNNEL_ID" ]] || die "tunnel $LAB_TUNNEL_NAME was not found after creating it"
      log "tunnel $LAB_TUNNEL_NAME created"
    fi
    jq -n \
      --arg omni "$(host_name omni)" --arg omni_service "http://127.0.0.1:$HOST_OMNI_API_PORT" \
      --arg kube "$(host_name kube)" --arg kube_service "http://127.0.0.1:$HOST_OMNI_K8S_PORT" \
      --arg auth "$(host_name auth)" --arg auth_service "http://127.0.0.1:$HOST_DEX_PORT" \
      --arg pve "$(host_name pve)" \
      '[
        {hostname: $omni, service: $omni_service},
        {hostname: $kube, service: $kube_service},
        {hostname: $auth, service: $auth_service},
        {hostname: $pve, service: "https://127.0.0.1:8006", originRequest: {noTLSVerify: true}},
        {service: "http_status:404"}
      ]' >"$ingress"
    cf_query tunnels config update "$CF_LAB_TUNNEL_ID" --tunnel-config-ingress "@$ingress" >/dev/null || exit 1
    for label in "${HOST_HOST_LABELS[@]}"; do
      LAB_TUNNEL_HOSTNAME="$(host_name "$label")"
      tunnel_ensure_dns
    done
    tunnel_store_connector_token
  ) || exit 1
}

host_tunnel_remove() {
  local label
  for label in "${HOST_HOST_LABELS[@]}"; do
    (
      LAB_TUNNEL_NAME="$HOST_TUNNEL_NAME"
      LAB_TUNNEL_HOSTNAME="$(host_name "$label")"
      tunnel_remove_current
    ) || exit 1
  done
}

host_fetch_service_account() {
  local key="$HOST_STATE/omni-service-account.key" deadline=$((SECONDS + HOST_READY_TIMEOUT))
  until pve_ssh "test -s $HOST_REMOTE_DATA/initial-service-account.key"; do
    ((SECONDS < deadline)) || host_capture_failure "Omni did not write its initial service account key within ${HOST_READY_TIMEOUT}s"
    sleep 3
  done
  pve_scp "$PVE_SSH:$HOST_REMOTE_DATA/initial-service-account.key" "$key"
  chmod 600 "$key"
  log "Omni service account key saved in $key"
}

host_up() {
  local before after
  host_load_config
  before="$(host_snapshot_others)" || exit 1
  host_fetch_binaries
  host_ensure_secrets
  host_prepare_packages
  host_ensure_sdn
  host_tunnel_provision
  host_upload_binaries
  host_stage
  host_install_stage
  host_restart talos-lab-dex talos-lab-cloudflared
  host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
  host_wait_public dex "https://$(host_name auth)/.well-known/openid-configuration"
  host_restart talos-lab-omni
  host_wait_local omni "http://127.0.0.1:$HOST_OMNI_API_PORT/"
  host_fetch_service_account
  host_verify
  after="$(host_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during host up. Before: $before. After: $after"
}

host_verify() {
  local service
  for service in "${HOST_SERVICES[@]}"; do
    pve_ssh "systemctl is-active --quiet $service" || host_capture_failure "$service is not active"
  done
  host_wait_public omni "https://$(host_name omni)/"
  host_wait_public dex "https://$(host_name auth)/.well-known/openid-configuration"
  host_wait_public proxmox "https://$(host_name pve)/"
  log "host verified: Omni at https://$(host_name omni), Proxmox at https://$(host_name pve), logins at https://$(host_name auth)"
}

host_down() {
  local before after leftovers=()
  host_load_config
  before="$(host_snapshot_others)" || exit 1
  host_remote SERVICES="${HOST_SERVICES[*]}" BIN="$HOST_REMOTE_BIN" ETC="$HOST_REMOTE_ETC" DATA="$(dirname "$HOST_REMOTE_DATA")" \
    ZONE="$HOST_SDN_ZONE" VNET="$HOST_VNET" SUBNET="$HOST_SUBNET" <<'EOF'
set -euo pipefail
subnet_id="$ZONE-${SUBNET/\//-}"
for service in $SERVICES; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$service.service"
done
systemctl daemon-reload
rm -rf "$BIN" "$ETC" "$DATA"
if pvesh get "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null
fi
if pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/vnets/$VNET" >/dev/null
fi
if pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/zones/$ZONE" >/dev/null
fi
pvesh set /cluster/sdn >/dev/null
EOF
  host_tunnel_remove
  rm -rf "$HOST_STATE/stage" "$HOST_STATE/connector-token" "$HOST_STATE/omni-service-account.key" "$HOST_STATE/tunnel-ingress.json"

  pve_ssh "systemctl list-unit-files 'talos-lab-*' --no-legend | grep -q ." && leftovers+=("talos-lab systemd units")
  pve_ssh "pvesh get /cluster/sdn/zones/$HOST_SDN_ZONE" >/dev/null 2>&1 && leftovers+=("SDN zone $HOST_SDN_ZONE")
  ((${#leftovers[@]} == 0)) || die "host teardown left resources behind: ${leftovers[*]}"
  after="$(host_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during host teardown. Before: $before. After: $after"
  log "host layer removed, other tunnels and DNS records unchanged"
}
