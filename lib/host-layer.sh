readonly HOST_SDN_ZONE=talab
readonly HOST_OMNI_VERSION=v1.13.3
readonly HOST_OMNICTL_PLATFORMS=(darwin-amd64 darwin-arm64 linux-amd64 linux-arm64 windows-amd64.exe)
readonly HOST_DEX_IMAGE=ghcr.io/dexidp/dex@sha256:65b72ca0f4b0bf6d4ada84ec21da8851782563404ac7b8f926923d27ceced9ab
readonly HOST_DEX_SHA256=e73fe3d2c9efc03551c62fcc5694acec8db1f36a79110f30070d2dc84c2951d1
readonly HOST_CLOUDFLARED_VERSION=2026.11.0
readonly HOST_CLOUDFLARED_SHA256=51f7c68b57ed7269164075d7e789efce5b59355982f06392deeb037d982a51fd
readonly HOST_KUBECTL_VERSION=v1.37.2
readonly HOST_KUBECTL_SHA256=c04487523e7aa7d1493f7808174c899db93d7a9cf57531420cd76b9bd415f8f4
readonly HOST_CODE_SERVER_VERSION=4.145.2
readonly HOST_CODE_SERVER_SHA256=2f6db6c3e8b733dd6b3aeee83532e148b2bae2e392353ba85452d03572348962
readonly HOST_PVE_REALM=lab
readonly HOST_DEX_PORT=5556
readonly HOST_TUNNEL_NAME=talos-lab-host
readonly HOST_REMOTE_BIN=/usr/local/lib/talos-lab
readonly HOST_REMOTE_ETC=/etc/talos-lab
readonly HOST_SERVICES=(talos-lab-dex talos-lab-cloudflared)
readonly HOST_READY_TIMEOUT=300
readonly HOST_CT_TEMPLATE_PATTERN='^debian-13-standard_[0-9.-]+_amd64\.tar\.zst$'

HOST_STATE="$LAB_STATE/host"
LAB_SEATS_STATE="$LAB_STATE/seats"

host_name() {
  printf '%s.%s' "$1" "$LAB_TUNNEL_ZONE"
}

host_load_config() {
  lab_load_config
  pve_load_target || exit 1
  mkdir -p "$HOST_STATE" "$LAB_SEATS_STATE"
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

host_fetch_binaries() {
  local dir="$HOST_STATE/bin" cid platform
  mkdir -p "$dir/omnictl"
  host_omni_release_file omni-linux-amd64 "$dir/omni"
  for platform in "${HOST_OMNICTL_PLATFORMS[@]}"; do
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
  host_fetch_verified cloudflared "$HOST_CLOUDFLARED_SHA256" "$dir/cloudflared" 755 \
    "https://github.com/cloudflare/cloudflared/releases/download/$HOST_CLOUDFLARED_VERSION/cloudflared-linux-amd64"
  host_fetch_verified kubectl "$HOST_KUBECTL_SHA256" "$dir/kubectl" 755 \
    "https://dl.k8s.io/release/$HOST_KUBECTL_VERSION/bin/linux/amd64/kubectl"
  host_fetch_verified code-server "$HOST_CODE_SERVER_SHA256" "$dir/code-server.tar.gz" 644 \
    "https://github.com/coder/code-server/releases/download/v$HOST_CODE_SERVER_VERSION/code-server-$HOST_CODE_SERVER_VERSION-linux-amd64.tar.gz"
}

host_fetch_verified() {
  local name="$1" sha256="$2" target="$3" mode="$4" url="$5"
  if [[ -f "$target" && "$(sha256sum "$target" | cut -d' ' -f1)" == "$sha256" ]]; then
    return 0
  fi
  log "downloading $name"
  curl --fail --silent --show-error --location --output "$target.part" "$url"
  [[ "$(sha256sum "$target.part" | cut -d' ' -f1)" == "$sha256" ]] || die "$name from $url does not match $sha256"
  chmod "$mode" "$target.part"
  mv "$target.part" "$target"
}

host_omnictl_local() {
  printf '%s/bin/omnictl/omnictl-linux-amd64' "$HOST_STATE"
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

host_remove_user() {
  local users="$HOST_STATE/users.tsv"
  [[ -f "$users" ]] || return 0
  awk -F'\t' -v u="$1" '$1 != u' "$users" >"$users.new"
  mv "$users.new" "$users"
}

host_user_password() {
  awk -F'\t' -v u="$1" '$1 == u {print $3}' "$HOST_STATE/users.tsv"
}

host_seat_numbers() {
  local dir
  for dir in "$LAB_SEATS_STATE"/seat[0-9][0-9]; do
    if [[ -d "$dir" ]]; then
      printf '%s\n' "${dir##*/seat}"
    fi
  done
}

host_ensure_secrets() {
  [[ -s "$HOST_STATE/dex-client-secret" ]] || openssl rand -hex 32 >"$HOST_STATE/dex-client-secret"
  [[ -s "$HOST_STATE/proxmox-client-secret" ]] || openssl rand -hex 32 >"$HOST_STATE/proxmox-client-secret"
  host_ensure_user instructor
}

host_render_dex() {
  local redirects number
  redirects="$(for number in $(host_seat_numbers); do printf 'https://%s/oidc/consume\n' "$(host_name "omni$number")"; done | jq -R . | jq -s -c .)"
  jq -n \
    --arg issuer "https://$(host_name auth)" \
    --arg listen "127.0.0.1:$HOST_DEX_PORT" \
    --arg secret "$(<"$HOST_STATE/dex-client-secret")" \
    --arg proxmox_secret "$(<"$HOST_STATE/proxmox-client-secret")" \
    --arg proxmox "https://$(host_name pve)" \
    --argjson redirects "$redirects" \
    --rawfile users "$HOST_STATE/users.tsv" \
    '{
      issuer: $issuer,
      storage: {type: "memory"},
      web: {http: $listen},
      oauth2: {skipApprovalScreen: true, passwordConnector: "local"},
      staticClients: [
        {id: "omni", name: "Omni", secret: $secret, redirectURIs: $redirects},
        {id: "proxmox", name: "Proxmox", secret: $proxmox_secret, redirectURIs: [$proxmox]}
      ],
      enablePasswordDB: true,
      staticPasswords: [
        $users | split("\n")[] | select(length > 0) | split("\t")
        | {username: .[0], email: .[1], hash: .[3], userID: .[4]}
      ]
    }'
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

host_install_file() {
  local mode="$1" path="$2"
  pve_ssh "install -D -m $mode -o root -g root /dev/stdin $path"
}

host_prepare() {
  local dns
  pve_remote ZONE="$HOST_SDN_ZONE" PATTERN="$HOST_CT_TEMPLATE_PATTERN" <<'EOF'
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
modprobe wireguard
printf 'wireguard\n' >/etc/modules-load.d/talos-lab.conf
if ! pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
  pvesh create /cluster/sdn/zones --zone "$ZONE" --type simple --dhcp dnsmasq --ipam pve >/dev/null
  pvesh set /cluster/sdn >/dev/null
fi
if ! pveam list local | awk '{print $1}' | sed 's|^local:vztmpl/||' | grep -qE "$PATTERN"; then
  pveam update >/dev/null
  template="$(pveam available --section system | awk '{print $2}' | grep -E "$PATTERN" | sort -V | tail -1)"
  [[ -n "$template" ]] || { echo "no container template matches $PATTERN" >&2; exit 1; }
  pveam download local "$template" >/dev/null
fi
EOF
  dns="$(pve_ssh "awk '/^nameserver/ {print \$2; exit}' /etc/resolv.conf")"
  [[ -n "$dns" ]] || die "the Proxmox host has no nameserver in /etc/resolv.conf"
  printf '%s\n' "$dns" >"$HOST_STATE/host-dns"
  log "host prepared: dnsmasq, wireguard module, SDN zone $HOST_SDN_ZONE, Debian container template"
}

host_ct_template() {
  pve_ssh "pveam list local" | awk '{print $1}' | sed 's|^local:vztmpl/||' | grep -E "$HOST_CT_TEMPLATE_PATTERN" | sort -V | tail -1
}

host_upload_binaries() {
  local name local_sum remote_sum platform names=(omni dex cloudflared kubectl code-server.tar.gz)
  for platform in "${HOST_OMNICTL_PLATFORMS[@]}"; do
    names+=("omnictl/omnictl-$platform")
  done
  pve_ssh "mkdir -p $HOST_REMOTE_BIN/omnictl $HOST_REMOTE_ETC && chmod 755 $HOST_REMOTE_BIN $HOST_REMOTE_BIN/omnictl && chmod 700 $HOST_REMOTE_ETC"
  for name in "${names[@]}"; do
    local_sum="$(sha256sum "$HOST_STATE/bin/$name" | cut -d' ' -f1)"
    remote_sum="$(pve_ssh "sha256sum $HOST_REMOTE_BIN/$name 2>/dev/null | cut -d' ' -f1" || true)"
    if [[ "$local_sum" != "$remote_sum" ]]; then
      pve_scp "$HOST_STATE/bin/$name" "$PVE_SSH:$HOST_REMOTE_BIN/$name.part"
      pve_ssh "chmod 755 $HOST_REMOTE_BIN/$name.part && mv $HOST_REMOTE_BIN/$name.part $HOST_REMOTE_BIN/$name"
      log "uploaded $name"
    fi
  done
  pve_remote BIN="$HOST_REMOTE_BIN" VERSION="$HOST_CODE_SERVER_VERSION" <<'EOF'
set -euo pipefail
if [[ "$(cat "$BIN/code-server/.talos-lab-version" 2>/dev/null)" != "$VERSION" ]]; then
  rm -rf "$BIN/code-server" "$BIN/code-server.part"
  mkdir -p "$BIN/code-server.part"
  tar -xzf "$BIN/code-server.tar.gz" -C "$BIN/code-server.part" --strip-components=1 --no-same-owner
  printf '%s\n' "$VERSION" >"$BIN/code-server.part/.talos-lab-version"
  chmod -R a+rX "$BIN/code-server.part"
  mv "$BIN/code-server.part" "$BIN/code-server"
fi
EOF
}

host_ensure_realm() {
  pve_remote REALM="$HOST_PVE_REALM" ISSUER="https://$(host_name auth)" SECRET="$(<"$HOST_STATE/proxmox-client-secret")" \
    INSTRUCTOR="instructor@$HOST_PVE_REALM" <<'EOF'
set -euo pipefail
options=(--issuer-url "$ISSUER" --client-id proxmox --client-key "$SECRET" --username-claim username --scopes "openid email profile" --default 1 --comment "Lab login")
if pveum realm list --output-format json | grep -q "\"realm\":\"$REALM\""; then
  pveum realm modify "$REALM" "${options[@]}"
else
  pveum realm add "$REALM" --type openid --autocreate 0 "${options[@]}"
fi
if ! pveum user list --output-format json | grep -q "\"userid\":\"$INSTRUCTOR\""; then
  pveum user add "$INSTRUCTOR"
fi
pveum acl modify / --users "$INSTRUCTOR" --roles PVEAuditor,PVEVMAdmin
EOF
  log "Proxmox realm $HOST_PVE_REALM signs in through Dex, instructor@$HOST_PVE_REALM can see and power every VM"
}

host_verify_realm() {
  local response url code
  response="$(curl --silent --show-error --max-time 30 --insecure --pinnedpubkey "sha256//$PVE_TLS_PIN" \
    --data-urlencode "realm=$HOST_PVE_REALM" --data-urlencode "redirect-url=https://$(host_name pve)" \
    "$PVE_URL/api2/json/access/openid/auth-url")" || host_capture_failure "Proxmox did not return an OpenID login URL: $response"
  url="$(jq -er .data <<<"$response")" || host_capture_failure "Proxmox returned no OpenID login URL: $response"
  [[ "$url" == "https://$(host_name auth)/auth?"* ]] || host_capture_failure "Proxmox OpenID login points at $url, expected Dex"
  code="$(lab_public_curl --silent --max-time 15 --output /dev/null --write-out '%{http_code}' "$url")"
  [[ "$code" == 302 || "$code" == 200 ]] || host_capture_failure "Dex refused the Proxmox login request with status $code"
  log "Proxmox lab login reaches the Dex sign-in page"
}

host_install_dex() {
  host_render_dex | host_install_file 600 "$HOST_REMOTE_ETC/dex.json"
  pve_ssh "systemctl restart talos-lab-dex"
  host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
}

host_install_services() {
  printf 'TUNNEL_TOKEN=%s\n' "$(<"$HOST_STATE/connector-token")" | host_install_file 600 "$HOST_REMOTE_ETC/cloudflared.env"
  host_render_dex | host_install_file 600 "$HOST_REMOTE_ETC/dex.json"
  host_render_dex_unit | host_install_file 644 /etc/systemd/system/talos-lab-dex.service
  host_render_cloudflared_unit | host_install_file 644 /etc/systemd/system/talos-lab-cloudflared.service
  pve_ssh "systemctl daemon-reload && systemctl enable --quiet ${HOST_SERVICES[*]} && systemctl restart ${HOST_SERVICES[*]}"
}

host_service_logs() {
  local service
  for service in "${HOST_SERVICES[@]}"; do
    printf '== %s\n' "$service"
    pve_ssh "systemctl status --no-pager --lines=0 $service; journalctl --no-pager --lines=60 --unit $service" 2>&1 || true
  done
}

host_capture_failure() {
  local reason="$1" dir label
  dir="$LAB_STATE/failures/host-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  host_service_logs >"$dir/services.txt" 2>&1 || true
  pve_ssh "ip -4 addr; ip -4 route; ss -ltnup; pct list; qm list" >"$dir/host.txt" 2>&1 || true
  pve_ssh "cat /etc/pve/sdn/*.cfg" >"$dir/sdn.txt" 2>&1 || true
  for label in auth pve; do
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
  local name="$1" url="$2" deadline=$((SECONDS + HOST_READY_TIMEOUT)) code=""
  until code="$(lab_public_curl --silent --max-time 10 --output /dev/null --write-out '%{http_code}' "$url")" && [[ "$code" =~ ^[23] ]]; do
    ((SECONDS < deadline)) || host_capture_failure "$name did not answer publicly at $url within ${HOST_READY_TIMEOUT}s, last status ${code:-none}"
    sleep 5
  done
  log "$name answering publicly at $url with status $code"
}

host_seat_address() {
  printf '10.88.%d.%d' "$((10#$1))" "$2"
}

host_wanted_hostnames() {
  local number label
  host_name auth
  printf '\n'
  host_name pve
  printf '\n'
  for number in $(host_seat_numbers); do
    for label in omni kube shell; do
      host_name "$label$number"
      printf '\n'
    done
  done
}

host_render_ingress() {
  local number rules
  rules="$(
    jq -n --arg host "$(host_name auth)" --arg service "http://127.0.0.1:$HOST_DEX_PORT" '{hostname: $host, service: $service}'
    jq -n --arg host "$(host_name pve)" '{hostname: $host, service: "https://127.0.0.1:8006", originRequest: {noTLSVerify: true}}'
    for number in $(host_seat_numbers); do
      jq -n --arg host "$(host_name "omni$number")" --arg service "http://$(host_seat_address "$number" 2):8080" '{hostname: $host, service: $service}'
      jq -n --arg host "$(host_name "kube$number")" --arg service "http://$(host_seat_address "$number" 2):8095" '{hostname: $host, service: $service}'
      jq -n --arg host "$(host_name "shell$number")" --arg service "http://$(host_seat_address "$number" 3):8443" '{hostname: $host, service: $service}'
    done
    jq -n '{service: "http_status:404"}'
  )"
  jq -s -c . <<<"$rules"
}

host_sync_tunnel() {
  local ingress="$HOST_STATE/tunnel-ingress.json" wanted host
  (
    LAB_TUNNEL_NAME="$HOST_TUNNEL_NAME"
    tunnel_ensure || exit 1
    host_render_ingress >"$ingress"
    tunnel_set_ingress "$ingress" || exit 1
    wanted="$(host_wanted_hostnames)"
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      LAB_TUNNEL_HOSTNAME="$host"
      tunnel_ensure_dns || exit 1
    done <<<"$wanted"
    while IFS= read -r host; do
      [[ "$host" =~ ^(omni|kube|shell)[0-9]{2}\. ]] || continue
      grep -qxF "$host" <<<"$wanted" && continue
      LAB_TUNNEL_HOSTNAME="$host"
      tunnel_remove_dns || exit 1
    done < <(cf_owned_hostnames)
    if [[ ! -s "$HOST_STATE/connector-token" ]]; then
      tunnel_store_connector_token "$HOST_STATE/connector-token" || exit 1
    fi
  ) || exit 1
}

host_up() {
  local before after
  host_load_config
  before="$(cf_snapshot_others)" || exit 1
  host_fetch_binaries
  host_ensure_secrets
  host_prepare
  host_upload_binaries
  host_sync_tunnel
  host_install_services
  host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
  host_ensure_realm
  host_verify
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during host up. Before: $before. After: $after"
}

host_verify() {
  local service number
  for service in "${HOST_SERVICES[@]}"; do
    pve_ssh "systemctl is-active --quiet $service" || host_capture_failure "$service is not active"
  done
  host_wait_public dex "https://$(host_name auth)/.well-known/openid-configuration"
  host_wait_public proxmox "https://$(host_name pve)/"
  host_verify_realm
  for number in $(host_seat_numbers); do
    host_wait_public "omni for seat $number" "https://$(host_name "omni$number")/"
    host_wait_public "workspace for seat $number" "https://$(host_name "shell$number")/healthz"
  done
  log "host verified: logins at https://$(host_name auth), Proxmox at https://$(host_name pve), $(host_seat_numbers | grep -c . || true) seats"
}

host_down() {
  local before after leftovers=() vnets label
  host_load_config
  [[ -z "$(host_seat_numbers)" ]] || die "seats still exist: $(host_seat_numbers | paste -sd' '), run ./lab seats delete first"
  vnets="$(pve_ssh "pvesh get /cluster/sdn/vnets --output-format json" | jq -r --arg zone "$HOST_SDN_ZONE" '.[] | select(.zone == $zone) | .vnet')" ||
    die "could not list SDN vnets"
  [[ -z "$vnets" ]] || die "zone $HOST_SDN_ZONE still has vnets: $(paste -sd' ' <<<"$vnets"), run ./lab seats delete first"
  before="$(cf_snapshot_others)" || exit 1
  pve_remote SERVICES="${HOST_SERVICES[*]}" BIN="$HOST_REMOTE_BIN" ETC="$HOST_REMOTE_ETC" ZONE="$HOST_SDN_ZONE" \
    REALM="$HOST_PVE_REALM" <<'EOF'
set -euo pipefail
if pveum user list --output-format json | grep -q "\"userid\":\"instructor@$REALM\""; then
  pveum user delete "instructor@$REALM"
fi
if pveum realm list --output-format json | grep -q "\"realm\":\"$REALM\""; then
  pveum realm delete "$REALM"
fi
for service in $SERVICES; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$service.service"
done
systemctl daemon-reload
rm -rf "$BIN" "$ETC" /etc/modules-load.d/talos-lab.conf
if pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/zones/$ZONE" >/dev/null
  pvesh set /cluster/sdn >/dev/null
fi
EOF
  (
    LAB_TUNNEL_NAME="$HOST_TUNNEL_NAME"
    for label in auth pve; do
      LAB_TUNNEL_HOSTNAME="$(host_name "$label")"
      tunnel_remove_dns || exit 1
    done
    tunnel_remove || exit 1
  ) || exit 1
  rm -f "$HOST_STATE/connector-token" "$HOST_STATE/tunnel-ingress.json"

  pve_ssh "systemctl list-unit-files 'talos-lab-*' --no-legend | grep -q ." && leftovers+=("talos-lab systemd units")
  pve_ssh "pvesh get /cluster/sdn/zones/$HOST_SDN_ZONE" >/dev/null 2>&1 && leftovers+=("SDN zone $HOST_SDN_ZONE")
  pve_ssh "pveum realm list --output-format json" | grep -q "\"realm\":\"$HOST_PVE_REALM\"" && leftovers+=("Proxmox realm $HOST_PVE_REALM")
  [[ -z "$(cf_owned_tunnels)" ]] || leftovers+=("tunnels $(cf_owned_tunnels | paste -sd' ')")
  [[ -z "$(cf_owned_hostnames)" ]] || leftovers+=("DNS records $(cf_owned_hostnames | paste -sd' ')")
  ((${#leftovers[@]} == 0)) || die "host teardown left resources behind: ${leftovers[*]}"
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during host teardown. Before: $before. After: $after"
  log "host layer removed, other tunnels and DNS records unchanged"
}
