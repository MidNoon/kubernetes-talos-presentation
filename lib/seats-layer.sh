readonly SEAT_MAX=20
readonly SEAT_CT_MEMORY_MIB=1024
readonly SEAT_CT_SWAP_MIB=512
readonly SEAT_CT_CORES=2
readonly SEAT_CT_DISK_GIB=4
readonly SEAT_VM_ROLES=(cp worker-a worker-b)
readonly SEAT_VM_MEMORY_MIB=(4096 3072 3072)
readonly SEAT_VM_CORES=(2 2 2)
readonly SEAT_VM_DISK_GIB=32
readonly SEAT_VM_MACS=(BC:24:11:1A:B5 BC:24:11:1A:B6 BC:24:11:1A:B7)
readonly SEAT_EXTENSION=siderolabs/qemu-guest-agent
readonly SEAT_PRESET=talos-lab
readonly SEAT_OMNI_READY_TIMEOUT=300

SEAT_OMNI_FORWARD=""
SEAT_OMNI_FORWARD_SEAT=""

seat_use() {
  local raw="$1" n=0 index
  if [[ "$raw" =~ ^[0-9]{1,2}$ ]]; then
    n=$((10#$raw))
  fi
  ((n >= 1 && n <= SEAT_MAX)) || die "seat must be a number from 1 to $SEAT_MAX, got \"$raw\""
  SEAT="$(printf '%02d' "$n")"
  SEAT_INDEX="$n"
  SEAT_NAME="seat$SEAT"
  SEAT_USER="student$SEAT"
  SEAT_EMAIL="$SEAT_USER@$LAB_TUNNEL_ZONE"
  SEAT_VNET="seat$SEAT"
  SEAT_SUBNET="10.88.$n.0/24"
  SEAT_GATEWAY="10.88.$n.1"
  SEAT_OMNI_ADDR="10.88.$n.2"
  SEAT_DHCP_START="10.88.$n.100"
  SEAT_DHCP_END="10.88.$n.199"
  SEAT_CT_ID=$((9000 + n * 10))
  SEAT_CT_NAME="omni$SEAT"
  SEAT_VM_IDS=()
  SEAT_VM_NAMES=()
  SEAT_MACHINE_IDS=()
  for index in "${!SEAT_VM_ROLES[@]}"; do
    SEAT_VM_IDS+=($((SEAT_CT_ID + index + 1)))
    SEAT_VM_NAMES+=("$SEAT_NAME-${SEAT_VM_ROLES[index]}")
    SEAT_MACHINE_IDS+=("$(printf '1ab51de0-7a10-4000-8000-0000000%02d%03d' "$n" "$((index + 1))")")
  done
  SEAT_STATE="$LAB_SEATS_STATE/$SEAT_NAME"
  SEAT_OMNI_HOST="$(host_name "omni$SEAT")"
  SEAT_KUBE_HOST="$(host_name "kube$SEAT")"
  SEAT_SITE_HOST="$(host_name "team$SEAT")"
  SEAT_SITE_TUNNEL="talos-student-$SEAT"
  SEAT_ISO="$SEAT_NAME-talos.iso"
  SEAT_CLUSTER="$SEAT_NAME"
}

seat_vm_mac() {
  printf '%s:%02X' "${SEAT_VM_MACS[$1]}" "$SEAT_INDEX"
}

seat_omni_forward_close() {
  if [[ -n "$SEAT_OMNI_FORWARD_SEAT" ]]; then
    pve_ssh_forward_close "$LAB_SEATS_STATE/seat$SEAT_OMNI_FORWARD_SEAT/omni-forward.sock"
  fi
  SEAT_OMNI_FORWARD=""
  SEAT_OMNI_FORWARD_SEAT=""
}

seat_omni_forward_open() {
  local port
  if [[ -n "$SEAT_OMNI_FORWARD" && "$SEAT_OMNI_FORWARD_SEAT" == "$SEAT" ]]; then
    return 0
  fi
  seat_omni_forward_close
  for port in $(seq 18080 18099); do
    if pve_ssh_forward_open "$SEAT_STATE/omni-forward.sock" "127.0.0.1:$port:$SEAT_OMNI_ADDR:8080"; then
      SEAT_OMNI_FORWARD="http://127.0.0.1:$port"
      SEAT_OMNI_FORWARD_SEAT="$SEAT"
      lab_on_exit seat_omni_forward_close
      return 0
    fi
  done
  fail "could not forward a local port from 18080 to 18099 to $SEAT_OMNI_ADDR:8080 through $PVE_SSH"
}

seat_omnictl() {
  local key="$SEAT_STATE/omni-service-account.key"
  [[ -s "$key" ]] || {
    fail "seat $SEAT has no Omni service account key at $key, run ./lab seats create first"
    return 1
  }
  seat_omni_forward_open || return 1
  OMNI_ENDPOINT="$SEAT_OMNI_FORWARD" OMNI_SERVICE_ACCOUNT_KEY="$(<"$key")" \
    timeout "${LAB_OMNI_TIMEOUT:-120}" "$(host_omnictl_local)" "$@"
}

seat_ensure_secrets() {
  local gnupg fingerprint identity="omni-$SEAT_NAME@talos-lab.invalid"
  mkdir -p "$SEAT_STATE"
  [[ -s "$SEAT_STATE/account-id" ]] || uuidgen >"$SEAT_STATE/account-id"
  if [[ ! -s "$SEAT_STATE/omni.asc" ]]; then
    gnupg="$(mktemp -d)"
    GNUPGHOME="$gnupg" gpg --batch --quiet --passphrase '' --quick-generate-key \
      "Omni etcd encryption <$identity>" rsa4096 cert never 2>/dev/null
    fingerprint="$(GNUPGHOME="$gnupg" gpg --with-colons --list-keys "$identity" 2>/dev/null | awk -F: '$1 == "fpr" {print $10; exit}')"
    [[ -n "$fingerprint" ]] || die "could not generate the Omni etcd encryption key for $SEAT_NAME"
    GNUPGHOME="$gnupg" gpg --batch --quiet --passphrase '' --quick-add-key "$fingerprint" rsa4096 encr never 2>/dev/null
    GNUPGHOME="$gnupg" gpg --batch --quiet --export-secret-key --armor "$identity" >"$SEAT_STATE/omni.asc" 2>/dev/null
    gpgconf --homedir "$gnupg" --kill all 2>/dev/null || true
    rm -rf "$gnupg"
    [[ -s "$SEAT_STATE/omni.asc" ]] || die "could not export the Omni etcd encryption key for $SEAT_NAME"
  fi
  host_ensure_user "$SEAT_USER"
}

seat_ensure_vnet() {
  pve_remote ZONE="$HOST_SDN_ZONE" VNET="$SEAT_VNET" SUBNET="$SEAT_SUBNET" GATEWAY="$SEAT_GATEWAY" \
    DHCP_START="$SEAT_DHCP_START" DHCP_END="$SEAT_DHCP_END" DNS="$(<"$HOST_STATE/host-dns")" <<'EOF'
set -euo pipefail
subnet_id="$ZONE-${SUBNET/\//-}"
changed=false
if ! pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
  pvesh create /cluster/sdn/vnets --vnet "$VNET" --zone "$ZONE" >/dev/null
  changed=true
fi
if ! pvesh get "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null 2>&1; then
  pvesh create "/cluster/sdn/vnets/$VNET/subnets" --subnet "$SUBNET" --type subnet \
    --gateway "$GATEWAY" --snat 1 --dhcp-dns-server "$DNS" \
    --dhcp-range "start-address=$DHCP_START,end-address=$DHCP_END" >/dev/null
  changed=true
fi
if [[ "$changed" == true ]] || ! ip -4 addr show dev "$VNET" 2>/dev/null | grep -q "inet $GATEWAY/"; then
  pvesh set /cluster/sdn >/dev/null
fi
for attempt in $(seq 1 60); do
  if ip -4 addr show dev "$VNET" 2>/dev/null | grep -q "inet $GATEWAY/"; then
    exit 0
  fi
  sleep 1
done
echo "vnet $VNET did not get $GATEWAY within 60s" >&2
exit 1
EOF
  log "$SEAT_NAME network $SEAT_SUBNET on vnet $SEAT_VNET"
}

seat_render_omni_unit() {
  cat <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
WorkingDirectory=/var/lib/talos-lab/work
ExecStart=/opt/talos-lab/omni \\
  --config-path=/etc/talos-lab/omni.yaml \\
  --name=$SEAT_NAME \\
  --account-id=$(<"$SEAT_STATE/account-id") \\
  --eula-accept-name="$LAB_OMNI_EULA_NAME" \\
  --eula-accept-email=$LAB_OMNI_EULA_EMAIL \\
  --private-key-source=file:///etc/talos-lab/omni.asc \\
  --etcd-embedded-db-path=/var/lib/talos-lab/etcd \\
  --sqlite-storage-path=/var/lib/talos-lab/omni.db \\
  --bind-addr=$SEAT_OMNI_ADDR:8080 \\
  --advertised-api-url=https://$SEAT_OMNI_HOST \\
  --k8s-proxy-bind-addr=$SEAT_OMNI_ADDR:8095 \\
  --advertised-kubernetes-proxy-url=https://$SEAT_KUBE_HOST \\
  --metrics-bind-addr=127.0.0.1:2122 \\
  --machine-api-bind-addr=$SEAT_OMNI_ADDR:8090 \\
  --machine-api-advertised-url=grpc://$SEAT_OMNI_ADDR:8090 \\
  --siderolink-wireguard-bind-addr=$SEAT_OMNI_ADDR:50180 \\
  --siderolink-wireguard-advertised-addr=$SEAT_OMNI_ADDR:50180 \\
  --auth-oidc-enabled \\
  --auth-oidc-provider-url=https://$(host_name auth) \\
  --auth-oidc-client-id=omni \\
  --auth-oidc-scopes=openid,profile,email \\
  --initial-users=$SEAT_EMAIL,instructor@$LAB_TUNNEL_ZONE \\
  --create-initial-service-account \\
  --initial-service-account-role=Admin \\
  --initial-service-account-lifetime=8760h \\
  --initial-service-account-key-path=/var/lib/talos-lab/initial-service-account.key
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

seat_ensure_container() {
  local state restarted stage="/root/talos-lab-$SEAT_NAME"
  state="$(pve_ct_state "$SEAT_CT_ID" "$SEAT_CT_NAME")" || exit 1
  if [[ "$state" == absent ]]; then
    pve_remote CT="$SEAT_CT_ID" NAME="$SEAT_CT_NAME" TEMPLATE="$(host_ct_template)" STORAGE="$PVE_DISK_STORAGE" \
      MEMORY="$SEAT_CT_MEMORY_MIB" SWAP="$SEAT_CT_SWAP_MIB" CORES="$SEAT_CT_CORES" DISK="$SEAT_CT_DISK_GIB" \
      VNET="$SEAT_VNET" ADDR="$SEAT_OMNI_ADDR" GATEWAY="$SEAT_GATEWAY" DNS="$(<"$HOST_STATE/host-dns")" BIN="$HOST_REMOTE_BIN" <<'EOF'
set -euo pipefail
pct create "$CT" "local:vztmpl/$TEMPLATE" \
  --hostname "$NAME" --memory "$MEMORY" --swap "$SWAP" --cores "$CORES" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=$VNET,ip=$ADDR/24,gw=$GATEWAY" \
  --nameserver "$DNS" --unprivileged 1 --features nesting=1 \
  --dev0 /dev/net/tun \
  --mp0 "$BIN,mp=/opt/talos-lab,ro=1" \
  --onboot 1 --start 1 >/dev/null
EOF
    log "container $SEAT_CT_NAME ($SEAT_CT_ID) created on $SEAT_VNET at $SEAT_OMNI_ADDR"
  elif [[ "$state" != running ]]; then
    pve_ssh "pct start $SEAT_CT_ID"
  fi
  pve_ssh "rm -rf $stage && mkdir -p $stage && chmod 700 $stage"
  seat_render_omni_config | pve_ssh "cat >$stage/omni.yaml"
  pve_scp "$SEAT_STATE/omni.asc" "$PVE_SSH:$stage/omni.asc"
  seat_render_omni_unit | pve_ssh "cat >$stage/talos-lab-omni.service"
  restarted="$(pve_remote CT="$SEAT_CT_ID" STAGE="$stage" <<'EOF'
set -euo pipefail
trap 'rm -rf "$STAGE"' EXIT
for attempt in $(seq 1 60); do
  pct exec "$CT" -- true 2>/dev/null && break
  sleep 1
done
pct exec "$CT" -- install -d -m 700 /etc/talos-lab /var/lib/talos-lab
pct exec "$CT" -- install -d -m 755 /var/lib/talos-lab/work
pct exec "$CT" -- ln -sfn /opt/talos-lab/omnictl /var/lib/talos-lab/work/omnictl
changed=false
for pair in omni.yaml:/etc/talos-lab/omni.yaml:600 omni.asc:/etc/talos-lab/omni.asc:600 talos-lab-omni.service:/etc/systemd/system/talos-lab-omni.service:644; do
  IFS=: read -r name target perms <<<"$pair"
  current="$(pct exec "$CT" -- sha256sum "$target" 2>/dev/null | cut -d' ' -f1 || true)"
  if [[ "$current" != "$(sha256sum "$STAGE/$name" | cut -d' ' -f1)" ]]; then
    pct push "$CT" "$STAGE/$name" "$target" --perms "$perms"
    changed=true
  fi
done
pct exec "$CT" -- systemctl daemon-reload
pct exec "$CT" -- systemctl enable --quiet talos-lab-omni
if [[ "$changed" == true ]] || ! pct exec "$CT" -- systemctl is-active --quiet talos-lab-omni; then
  pct exec "$CT" -- systemctl restart talos-lab-omni
  echo restarted
fi
EOF
)" || exit 1
  if [[ "$restarted" == restarted ]]; then
    log "Omni for $SEAT_NAME started with new configuration"
  fi
}

seat_render_omni_config() {
  jq -n --arg secret "$(<"$HOST_STATE/dex-client-secret")" '{auth: {oidc: {clientSecret: $secret}}}'
}

seat_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/$SEAT_NAME-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  pve_ssh "pct status $SEAT_CT_ID; pct exec $SEAT_CT_ID -- systemctl status --no-pager --lines=0 talos-lab-omni; pct exec $SEAT_CT_ID -- journalctl --no-pager --lines=120 -u talos-lab-omni; pct exec $SEAT_CT_ID -- ip -br addr" >"$dir/omni.txt" 2>&1 || true
  pve_ssh "ip -4 addr show $SEAT_VNET; cat /etc/pve/sdn/*.cfg" >"$dir/network.txt" 2>&1 || true
  lab_public_curl --silent --show-error --max-time 15 --verbose --output /dev/null "https://$SEAT_OMNI_HOST/" >"$dir/curl-omni.txt" 2>&1 || true
  die "$reason. Context saved in $dir"
}

seat_wait_omni() {
  local deadline=$((SECONDS + SEAT_OMNI_READY_TIMEOUT)) key="$SEAT_STATE/omni-service-account.key" remote="/root/talos-lab-$SEAT_NAME.key"
  until pve_ssh "curl --silent --max-time 5 --output /dev/null http://$SEAT_OMNI_ADDR:8080/"; do
    ((SECONDS < deadline)) || seat_capture_failure "Omni for $SEAT_NAME did not answer at $SEAT_OMNI_ADDR:8080 within ${SEAT_OMNI_READY_TIMEOUT}s"
    sleep 3
  done
  if [[ ! -s "$key" ]]; then
    until pve_ssh "pct exec $SEAT_CT_ID -- test -s /var/lib/talos-lab/initial-service-account.key"; do
      ((SECONDS < deadline)) || seat_capture_failure "Omni for $SEAT_NAME did not write its service account key"
      sleep 3
    done
    pve_ssh "pct pull $SEAT_CT_ID /var/lib/talos-lab/initial-service-account.key $remote && chmod 600 $remote"
    pve_scp "$PVE_SSH:$remote" "$key"
    pve_ssh "rm -f $remote"
    chmod 600 "$key"
  fi
  seat_omnictl get identities >/dev/null || seat_capture_failure "the service account key for $SEAT_NAME does not work"
  until seat_omnictl get talosextensions "$LAB_TALOS_VERSION" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || seat_capture_failure "Omni for $SEAT_NAME never listed the extensions for Talos $LAB_TALOS_VERSION"
    sleep 3
  done
  log "Omni for $SEAT_NAME running at $SEAT_OMNI_ADDR with Talos $LAB_TALOS_VERSION available"
}

seat_ensure_iso() {
  local presets dir="$SEAT_STATE/media" iso status=0
  pve_iso_present "$SEAT_ISO" || status=$?
  case "$status" in
    0) return 0 ;;
    1) ;;
    *) exit 1 ;;
  esac
  presets="$(seat_omnictl get installationmediaconfigs -o json)" || exit 1
  if ! jq -e -s --arg p "$SEAT_PRESET" 'any(.[]; .metadata.id == $p)' <<<"$presets" >/dev/null 2>&1; then
    seat_omnictl media preset create "$SEAT_PRESET" --talos-version "$LAB_TALOS_VERSION" --extensions "$SEAT_EXTENSION" >/dev/null || exit 1
  fi
  rm -rf "$dir"
  mkdir -p "$dir"
  log "downloading the $SEAT_NAME install image from its Omni"
  LAB_OMNI_TIMEOUT=1800 seat_omnictl media download "$SEAT_PRESET" --output "$dir/" >/dev/null 2>&1 || exit 1
  iso="$(find "$dir" -maxdepth 1 -type f -name '*.iso' -print -quit)"
  [[ -n "$iso" ]] || die "no ISO in $dir after the download"
  pve_upload_iso "$iso" "$SEAT_ISO" || exit 1
  rm -rf "$dir"
  log "install image uploaded as $SEAT_ISO"
}

seat_ensure_proxmox_user() {
  pve_remote USER_ID="$SEAT_USER@pve" POOL="$SEAT_NAME" PASSWORD="$(host_user_password "$SEAT_USER")" \
    ISO_STORAGE="$PVE_ISO_STORAGE" DISK_STORAGE="$PVE_DISK_STORAGE" ZONE="$HOST_SDN_ZONE" VNET="$SEAT_VNET" <<'EOF'
set -euo pipefail
pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\"" || pveum pool add "$POOL"
if ! pveum user list --output-format json | grep -q "\"userid\":\"$USER_ID\""; then
  pveum user add "$USER_ID" --password "$PASSWORD"
fi
pveum acl modify "/pool/$POOL" --users "$USER_ID" --roles PVEVMAdmin
pveum acl modify "/storage/$ISO_STORAGE" --users "$USER_ID" --roles PVEDatastoreUser
pveum acl modify "/storage/$DISK_STORAGE" --users "$USER_ID" --roles PVEDatastoreUser
pveum acl modify "/sdn/zones/$ZONE/$VNET" --users "$USER_ID" --roles PVESDNUser
EOF
  log "Proxmox user $SEAT_USER@pve limited to pool $SEAT_NAME and vnet $SEAT_VNET"
}

seat_ensure_site_tunnel() {
  local ingress="$SEAT_STATE/site-ingress.json"
  (
    LAB_TUNNEL_NAME="$SEAT_SITE_TUNNEL"
    LAB_TUNNEL_HOSTNAME="$SEAT_SITE_HOST"
    tunnel_ensure || exit 1
    jq -n --arg host "$SEAT_SITE_HOST" \
      '[{hostname: $host, service: "http://hello.default.svc.cluster.local:80"}, {service: "http_status:404"}]' >"$ingress"
    tunnel_set_ingress "$ingress" || exit 1
    tunnel_ensure_dns || exit 1
    tunnel_store_connector_token "$SEAT_STATE/site-token" || exit 1
  ) || exit 1
}

seat_write_sheet() {
  {
    printf 'seat      %s\n' "$SEAT"
    printf 'email     %s\n' "$SEAT_EMAIL"
    printf 'password  %s\n' "$(host_user_password "$SEAT_USER")"
    printf 'omni      https://%s\n' "$SEAT_OMNI_HOST"
    printf 'proxmox   https://%s (user %s, realm Proxmox VE authentication server)\n' "$(host_name pve)" "$SEAT_USER"
    printf 'pool      %s\n' "$SEAT_NAME"
    printf 'network   %s\n' "$SEAT_VNET"
    printf 'image     %s\n' "$SEAT_ISO"
    printf 'site      https://%s\n' "$SEAT_SITE_HOST"
    printf 'token     %s/site-token\n' "$SEAT_STATE"
  } >"$SEAT_STATE/sheet.txt"
}

seat_create() {
  seat_use "$1"
  seat_ensure_secrets
  seat_ensure_vnet
  seat_ensure_container
  seat_wait_omni
  seat_ensure_iso
  seat_ensure_proxmox_user
  seat_ensure_site_tunnel
  seat_write_sheet
  log "$SEAT_NAME ready, sign-in sheet at $SEAT_STATE/sheet.txt"
}

seats_create() {
  local count="${1:-}" number before after
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]] || ((count > SEAT_MAX)); then
    die "seats create needs a count from 1 to $SEAT_MAX, got \"$count\""
  fi
  host_load_config
  [[ -s "$HOST_STATE/dex-client-secret" && -s "$HOST_STATE/host-dns" ]] || die "run ./lab host up first"
  before="$(cf_snapshot_others)" || exit 1
  for ((number = 1; number <= count; number++)); do
    seat_use "$number"
    mkdir -p "$SEAT_STATE"
    host_ensure_user "$SEAT_USER"
  done
  host_install_dex
  host_sync_tunnel
  for ((number = 1; number <= count; number++)); do
    seat_create "$number"
  done
  host_verify
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed while creating seats. Before: $before. After: $after"
  log "$count seats ready, sheets in $LAB_SEATS_STATE/seatNN/sheet.txt"
}

seat_remote_numbers() {
  local vnets tunnels
  vnets="$(pve_ssh "pvesh get /cluster/sdn/vnets --output-format json" | jq -r --arg zone "$HOST_SDN_ZONE" '.[] | select(.zone == $zone) | .vnet')" || return 1
  tunnels="$(cf_owned_tunnels)" || return 1
  {
    sed -n 's/^seat\([0-9][0-9]\)$/\1/p' <<<"$vnets"
    sed -n 's/^talos-student-\([0-9][0-9]\)$/\1/p' <<<"$tunnels"
    host_seat_numbers
  } | sort -u
}

seat_delete() {
  local index state
  seat_use "$1"
  seat_omni_forward_close
  for index in "${!SEAT_VM_IDS[@]}"; do
    pve_delete_vm "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}" || exit 1
  done
  state="$(pve_ct_state "$SEAT_CT_ID" "$SEAT_CT_NAME")" || exit 1
  if [[ "$state" != absent ]]; then
    pve_ssh "pct stop $SEAT_CT_ID >/dev/null 2>&1 || true; pct destroy $SEAT_CT_ID --purge 1 >/dev/null"
    log "container $SEAT_CT_NAME removed"
  fi
  pve_delete_iso "$SEAT_ISO" || exit 1
  pve_remote ZONE="$HOST_SDN_ZONE" VNET="$SEAT_VNET" SUBNET="$SEAT_SUBNET" USER_ID="$SEAT_USER@pve" POOL="$SEAT_NAME" <<'EOF'
set -euo pipefail
subnet_id="$ZONE-${SUBNET/\//-}"
pveum user list --output-format json | grep -q "\"userid\":\"$USER_ID\"" && pveum user delete "$USER_ID"
pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\"" && pveum pool delete "$POOL"
changed=false
if pvesh get "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/vnets/$VNET/subnets/$subnet_id" >/dev/null
  changed=true
fi
if pvesh get "/cluster/sdn/vnets/$VNET" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/vnets/$VNET" >/dev/null
  changed=true
fi
if [[ "$changed" == true ]]; then
  pvesh set /cluster/sdn >/dev/null
fi
EOF
  (
    LAB_TUNNEL_NAME="$SEAT_SITE_TUNNEL"
    LAB_TUNNEL_HOSTNAME="$SEAT_SITE_HOST"
    tunnel_remove_dns || exit 1
    tunnel_remove || exit 1
  ) || exit 1
  host_remove_user "$SEAT_USER"
  rm -rf "$SEAT_STATE"
  log "$SEAT_NAME removed"
}

seats_delete() {
  local numbers number before after leftovers
  host_load_config
  before="$(cf_snapshot_others)" || exit 1
  numbers="$(seat_remote_numbers)" || die "could not list existing seats"
  for number in $numbers; do
    seat_delete "$number"
  done
  host_install_dex
  host_sync_tunnel
  leftovers="$(seat_remote_numbers)" || die "could not list seats after deleting them"
  [[ -z "$leftovers" ]] || die "seats left behind: $(paste -sd' ' <<<"$leftovers")"
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed while deleting seats. Before: $before. After: $after"
  log "all seats removed, other tunnels and DNS records unchanged"
}
