readonly SEAT_MAX=20
readonly SEAT_CT_MEMORY_MIB=1024
readonly SEAT_CT_SWAP_MIB=512
readonly SEAT_CT_CORES=2
readonly SEAT_CT_DISK_GIB=4
readonly SEAT_WS_MEMORY_MIB=1536
readonly SEAT_WS_SWAP_MIB=512
readonly SEAT_WS_CORES=2
readonly SEAT_WS_DISK_GIB=8
readonly SEAT_WS_PORT=8443
readonly SEAT_WS_USER=student
readonly SEAT_VM_ROLES=(cp worker-a worker-b)
readonly SEAT_VM_MEMORY_MIB=3072
readonly SEAT_VM_CORES=2
readonly SEAT_VM_DISK_GIB=32
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
  SEAT_WS_ID=$((SEAT_CT_ID + 4))
  SEAT_WS_NAME="workspace$SEAT"
  SEAT_WS_ADDR="10.88.$n.3"
  SEAT_TEMPLATE_ID=$((SEAT_CT_ID + 9))
  SEAT_TEMPLATE_NAME="seat$SEAT-template"
  SEAT_PVE_USER="student$SEAT@$HOST_PVE_REALM"
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
  SEAT_SHELL_HOST="$(host_name "shell$SEAT")"
  SEAT_SITE_TUNNEL="talos-student-$SEAT"
  SEAT_ISO_STORAGE="$(host_seat_iso_storage "$SEAT")"
  SEAT_ISO_PATH="$HOST_ISO_ROOT/$SEAT_NAME"
  SEAT_ISO="$SEAT_NAME-talos.iso"
  SEAT_CLUSTER="$SEAT_NAME"
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

seat_ensure_ct() {
  local id="$1" name="$2" addr="$3" memory="$4" swap="$5" cores="$6" disk="$7" tun="$8" state
  state="$(pve_ct_state "$id" "$name")" || exit 1
  if [[ "$state" == absent ]]; then
    pve_remote CT="$id" NAME="$name" TEMPLATE="$(host_ct_template)" STORAGE="$PVE_DISK_STORAGE" \
      MEMORY="$memory" SWAP="$swap" CORES="$cores" DISK="$disk" TUN="$tun" \
      VNET="$SEAT_VNET" ADDR="$addr" GATEWAY="$SEAT_GATEWAY" DNS="$(<"$HOST_STATE/host-dns")" BIN="$HOST_REMOTE_BIN" <<'EOF'
set -euo pipefail
extra=()
if [[ "$TUN" == yes ]]; then
  extra+=(--dev0 /dev/net/tun)
fi
pct create "$CT" "local:vztmpl/$TEMPLATE" \
  --hostname "$NAME" --memory "$MEMORY" --swap "$SWAP" --cores "$CORES" \
  --rootfs "$STORAGE:$DISK" \
  --net0 "name=eth0,bridge=$VNET,ip=$ADDR/24,gw=$GATEWAY" \
  --nameserver "$DNS" --unprivileged 1 --features nesting=1 \
  "${extra[@]}" \
  --mp0 "$BIN,mp=/opt/talos-lab,ro=1" \
  --onboot 1 --start 1 >/dev/null
for attempt in $(seq 1 60); do
  pct exec "$CT" -- true 2>/dev/null && exit 0
  sleep 1
done
echo "container $CT did not accept commands within 60s" >&2
exit 1
EOF
    log "container $name ($id) created on $SEAT_VNET at $addr"
  elif [[ "$state" != running ]]; then
    pve_ssh "pct start $id"
  fi
}

seat_ensure_container() {
  local restarted stage="/root/talos-lab-$SEAT_NAME"
  seat_ensure_ct "$SEAT_CT_ID" "$SEAT_CT_NAME" "$SEAT_OMNI_ADDR" "$SEAT_CT_MEMORY_MIB" "$SEAT_CT_SWAP_MIB" "$SEAT_CT_CORES" "$SEAT_CT_DISK_GIB" yes
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
  local deadline=$((SECONDS + SEAT_OMNI_READY_TIMEOUT)) key="$SEAT_STATE/omni-service-account.key" remote="/root/talos-lab-$SEAT_NAME.key" identity
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
  identity="$(seat_omnictl get identity "$SEAT_EMAIL" 2>&1)" ||
    seat_capture_failure "the $SEAT_NAME Omni did not show the identity $SEAT_EMAIL to its service account: $identity"
  until seat_omnictl get talosextensions "$LAB_TALOS_VERSION" >/dev/null 2>&1; do
    ((SECONDS < deadline)) || seat_capture_failure "Omni for $SEAT_NAME never listed the extensions for Talos $LAB_TALOS_VERSION"
    sleep 3
  done
  log "Omni for $SEAT_NAME running at $SEAT_OMNI_ADDR with Talos $LAB_TALOS_VERSION available"
}

seat_ensure_pool() {
  pve_remote POOL="$SEAT_NAME" <<'EOF'
set -euo pipefail
pveum pool list --output-format json | grep -q "\"poolid\":\"$POOL\"" || pveum pool add "$POOL"
EOF
}

seat_ensure_iso_storage() {
  pve_remote STORAGE="$SEAT_ISO_STORAGE" DIR="$SEAT_ISO_PATH" <<'EOF'
set -euo pipefail
if ! pvesm status --storage "$STORAGE" >/dev/null 2>&1; then
  pvesm add dir "$STORAGE" --path "$DIR" --content iso --create-base-path 1 --create-subdirs 1
fi
EOF
  log "storage $SEAT_ISO_STORAGE holds $SEAT_NAME install images at $SEAT_ISO_PATH"
}

seat_ensure_proxmox_user() {
  pve_remote USER_ID="$SEAT_PVE_USER" POOL="$SEAT_NAME" NODE="$PVE_NODE" ISO_STORAGE="$SEAT_ISO_STORAGE" \
    DISK_STORAGE="$PVE_DISK_STORAGE" ZONE="$HOST_SDN_ZONE" VNET="$SEAT_VNET" \
    MEDIA_ROLE="$HOST_MEDIA_ROLE" DOWNLOAD_ROLE="$HOST_DOWNLOAD_ROLE" <<'EOF'
set -euo pipefail
if ! pveum user list --output-format json | grep -q "\"userid\":\"$USER_ID\""; then
  pveum user add "$USER_ID"
fi
pveum acl modify "/pool/$POOL" --users "$USER_ID" --roles PVEVMAdmin,PVEPoolUser
pveum acl modify "/storage/$ISO_STORAGE" --users "$USER_ID" --roles "$MEDIA_ROLE"
pveum acl modify "/storage/$DISK_STORAGE" --users "$USER_ID" --roles PVEDatastoreUser
pveum acl modify "/nodes/$NODE" --users "$USER_ID" --roles "$DOWNLOAD_ROLE"
pveum acl modify "/sdn/zones/$ZONE/$VNET" --users "$USER_ID" --roles PVESDNUser
EOF
  log "Proxmox user $SEAT_PVE_USER limited to pool $SEAT_NAME, storage $SEAT_ISO_STORAGE and vnet $SEAT_VNET, and can download from URLs"
}

seat_workspace_service_account() {
  local key="$SEAT_STATE/workspace-service-account.key" accounts output
  [[ -s "$key" ]] && return 0
  accounts="$(seat_omnictl serviceaccount list 2>&1)" || seat_capture_failure "could not list service accounts in the $SEAT_NAME Omni: $accounts"
  if grep -qw workspace <<<"$accounts"; then
    seat_omnictl serviceaccount destroy workspace >/dev/null || exit 1
  fi
  output="$(seat_omnictl serviceaccount create workspace --use-user-role=false --role Operator 2>&1)" ||
    seat_capture_failure "could not create the workspace service account in the $SEAT_NAME Omni"
  local LAB_SCRUB
  LAB_SCRUB="$(sed -n 's/^OMNI_SERVICE_ACCOUNT_KEY=//p' <<<"$output" | head -1)"
  [[ -n "$LAB_SCRUB" ]] || die "omnictl did not print a service account key for the $SEAT_NAME workspace"
  printf '%s' "$LAB_SCRUB" >"$key"
  chmod 600 "$key"
}

seat_render_workspace_unit() {
  cat <<EOF
[Unit]
After=network-online.target
Wants=network-online.target

[Service]
User=$SEAT_WS_USER
WorkingDirectory=/home/$SEAT_WS_USER
EnvironmentFile=/etc/talos-lab/code-server.env
ExecStart=/opt/talos-lab/code-server/bin/code-server --bind-addr $SEAT_WS_ADDR:$SEAT_WS_PORT --auth password --disable-telemetry --disable-update-check --disable-workspace-trust /home/$SEAT_WS_USER
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

seat_render_connect() {
  cat <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cluster="${1:-}"
if [[ -z "$cluster" ]]; then
  clusters="$(omnictl get clusters | awk 'NR > 1 {print $3}')"
  case "$(grep -c . <<<"$clusters" || true)" in
    0)
      echo "There is no cluster yet. Create one in Omni, then run connect again." >&2
      exit 1
      ;;
    1) cluster="$clusters" ;;
    *)
      echo "There are several clusters: $(paste -sd' ' <<<"$clusters"). Run connect with the one you want, for example: connect $(head -1 <<<"$clusters")" >&2
      exit 1
      ;;
  esac
fi
mkdir -p "$HOME/.kube"
omnictl kubeconfig "$HOME/.kube/config" --cluster "$cluster" --service-account --user "$USER" --ttl 24h --force --merge=false >/dev/null
echo "kubectl now talks to cluster $cluster. Try: kubectl get nodes"
EOF
}

seat_render_omnictl_wrapper() {
  cat <<'EOF'
#!/bin/sh
set -a
. /etc/talos-lab-workspace.env
set +a
exec /opt/talos-lab/omnictl/omnictl-linux-amd64 "$@"
EOF
}

seat_render_vscode_settings() {
  jq -n '{
    "workbench.startupEditor": "readme",
    "telemetry.telemetryLevel": "off",
    "security.workspace.trust.enabled": false,
    "terminal.integrated.defaultProfile.linux": "bash",
    "terminal.integrated.cwd": "${workspaceFolder}",
    "files.exclude": {"**/.*": true}
  }'
}

seat_ensure_workspace() {
  local stage="/root/talos-lab-$SEAT_NAME-workspace" restarted
  seat_ensure_ct "$SEAT_WS_ID" "$SEAT_WS_NAME" "$SEAT_WS_ADDR" "$SEAT_WS_MEMORY_MIB" "$SEAT_WS_SWAP_MIB" "$SEAT_WS_CORES" "$SEAT_WS_DISK_GIB" no
  seat_workspace_service_account
  pve_ssh "rm -rf $stage && mkdir -p $stage/manifests && chmod 700 $stage"
  printf 'OMNI_ENDPOINT=http://%s:8080\nOMNI_SERVICE_ACCOUNT_KEY=%s\n' "$SEAT_OMNI_ADDR" "$(<"$SEAT_STATE/workspace-service-account.key")" | pve_ssh "cat >$stage/workspace.env"
  printf 'PASSWORD=%s\n' "$(host_user_password "$SEAT_USER")" | pve_ssh "cat >$stage/code-server.env"
  seat_render_workspace_unit | pve_ssh "cat >$stage/talos-lab-workspace.service"
  seat_render_connect | pve_ssh "cat >$stage/connect"
  seat_render_omnictl_wrapper | pve_ssh "cat >$stage/omnictl"
  seat_render_vscode_settings | pve_ssh "cat >$stage/settings.json"
  pve_scp "$LAB_ROOT/manifests/hello.yaml" "$LAB_ROOT/manifests/cloudflared.yaml" "$PVE_SSH:$stage/manifests/"
  pve_scp "$LAB_ROOT/docs/hands-on.md" "$PVE_SSH:$stage/README.md"
  pve_scp "$SEAT_STATE/site-token" "$PVE_SSH:$stage/token.txt"
  restarted="$(pve_remote CT="$SEAT_WS_ID" STAGE="$stage" WS_USER="$SEAT_WS_USER" <<'EOF'
set -euo pipefail
trap 'rm -rf "$STAGE"' EXIT
home="/home/$WS_USER"
pct exec "$CT" -- id -u "$WS_USER" >/dev/null 2>&1 || pct exec "$CT" -- useradd --create-home --shell /bin/bash "$WS_USER"
pct exec "$CT" -- install -d -m 700 /etc/talos-lab
pct exec "$CT" -- install -d -o "$WS_USER" -g "$WS_USER" -m 755 "$home/manifests" "$home/.local/share/code-server/User"
pct exec "$CT" -- ln -sfn /opt/talos-lab/kubectl /usr/local/bin/kubectl
changed=false
push() {
  local source="$1" target="$2" perms="$3" owner="$4" current
  current="$(pct exec "$CT" -- sha256sum "$target" 2>/dev/null | cut -d' ' -f1 || true)"
  if [[ "$current" != "$(sha256sum "$source" | cut -d' ' -f1)" ]]; then
    pct push "$CT" "$source" "$target" --perms "$perms" --user "${owner%:*}" --group "${owner#*:}"
    return 0
  fi
  return 1
}
push "$STAGE/code-server.env" /etc/talos-lab/code-server.env 600 root:root && changed=true
push "$STAGE/talos-lab-workspace.service" /etc/systemd/system/talos-lab-workspace.service 644 root:root && changed=true
gid="$(pct exec "$CT" -- id -g "$WS_USER")"
push "$STAGE/workspace.env" /etc/talos-lab-workspace.env 640 "0:$gid" || true
push "$STAGE/connect" /usr/local/bin/connect 755 root:root || true
push "$STAGE/omnictl" /usr/local/bin/omnictl 755 root:root || true
uid="$(pct exec "$CT" -- id -u "$WS_USER")"
push "$STAGE/settings.json" "$home/.local/share/code-server/User/settings.json" 644 "$uid:$gid" || true
push "$STAGE/README.md" "$home/README.md" 644 "$uid:$gid" || true
push "$STAGE/token.txt" "$home/token.txt" 600 "$uid:$gid" || true
for manifest in "$STAGE"/manifests/*.yaml; do
  push "$manifest" "$home/manifests/$(basename "$manifest")" 644 "$uid:$gid" || true
done
pct exec "$CT" -- systemctl daemon-reload
pct exec "$CT" -- systemctl enable --quiet talos-lab-workspace
if [[ "$changed" == true ]] || ! pct exec "$CT" -- systemctl is-active --quiet talos-lab-workspace; then
  pct exec "$CT" -- systemctl restart talos-lab-workspace
  echo restarted
fi
EOF
)" || exit 1
  if [[ "$restarted" == restarted ]]; then
    log "workspace for $SEAT_NAME started at $SEAT_WS_ADDR:$SEAT_WS_PORT"
  fi
}

seat_wait_workspace() {
  local deadline=$((SECONDS + SEAT_OMNI_READY_TIMEOUT))
  until pve_ssh "curl --silent --fail --max-time 5 --output /dev/null http://$SEAT_WS_ADDR:$SEAT_WS_PORT/healthz"; do
    ((SECONDS < deadline)) || seat_capture_failure "the $SEAT_NAME workspace did not answer at $SEAT_WS_ADDR:$SEAT_WS_PORT within ${SEAT_OMNI_READY_TIMEOUT}s"
    sleep 3
  done
  seat_workspace_run 'omnictl get clusters >/dev/null && kubectl version --client >/dev/null' >/dev/null ||
    seat_capture_failure "the $SEAT_NAME workspace cannot reach its Omni or run kubectl"
  log "workspace for $SEAT_NAME answering, omnictl and kubectl work inside it"
}

seat_workspace_run() {
  pve_ssh "pct exec $SEAT_WS_ID -- su - $SEAT_WS_USER -c $(printf '%q' "$1")"
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
    printf 'Seat       %s\n' "$SEAT"
    printf 'Email      %s\n' "$SEAT_EMAIL"
    printf 'Password   %s\n' "$(host_user_password "$SEAT_USER")"
    printf 'Workspace  https://%s\n' "$SEAT_SHELL_HOST"
    printf 'Omni       https://%s\n' "$SEAT_OMNI_HOST"
    printf 'Proxmox    https://%s\n' "$(host_name pve)"
    printf 'Site       https://%s\n' "$SEAT_SITE_HOST"
  } >"$SEAT_STATE/sheet.txt"
}

seat_create() {
  seat_use "$1"
  seat_ensure_secrets
  seat_ensure_vnet
  seat_ensure_container
  seat_wait_omni
  seat_ensure_pool
  seat_ensure_iso_storage
  seat_ensure_proxmox_user
  seat_ensure_site_tunnel
  seat_ensure_workspace
  seat_wait_workspace
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
  local vnets tunnels storages
  vnets="$(pve_ssh "pvesh get /cluster/sdn/vnets --output-format json" | jq -r --arg zone "$HOST_SDN_ZONE" '.[] | select(.zone == $zone) | .vnet')" || return 1
  storages="$(pve_api GET /storage | jq -r '.data[].storage')" || return 1
  tunnels="$(cf_owned_tunnels)" || return 1
  {
    sed -n 's/^seat\([0-9][0-9]\)-iso$/\1/p' <<<"$storages"
    sed -n 's/^seat\([0-9][0-9]\)$/\1/p' <<<"$vnets"
    sed -n 's/^talos-student-\([0-9][0-9]\)$/\1/p' <<<"$tunnels"
    host_seat_numbers
  } | sort -u
}

seat_pool_vms() {
  local pools
  pools="$(pve_api GET /pools)" || return 1
  if ! jq -e --arg pool "$SEAT_NAME" '.data | any(.poolid == $pool)' <<<"$pools" >/dev/null; then
    return 0
  fi
  pve_api GET "/pools?poolid=$SEAT_NAME" |
    jq -r '.data[0].members // [] | map(select(.type == "qemu")) | sort_by(.template // 0) | .[] | "\(.vmid)\t\(.name)"'
}

seat_delete_pool_vms() {
  local vms vmid name
  vms="$(seat_pool_vms)" || exit 1
  while IFS=$'\t' read -r vmid name; do
    [[ -n "$vmid" ]] || continue
    pve_delete_vm "$vmid" "$name" || exit 1
    log "VM $name ($vmid) in pool $SEAT_NAME removed"
  done <<<"$vms"
}

seat_destroy_ct() {
  local id="$1" name="$2" state
  state="$(pve_ct_state "$id" "$name")" || exit 1
  if [[ "$state" != absent ]]; then
    pve_ssh "pct stop $id >/dev/null 2>&1 || true; pct destroy $id --purge 1 >/dev/null"
    log "container $name removed"
  fi
}

seat_delete() {
  local index
  seat_use "$1"
  seat_omni_forward_close
  seat_delete_pool_vms
  for index in "${!SEAT_VM_IDS[@]}"; do
    pve_delete_vm "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}" || exit 1
  done
  pve_delete_vm "$SEAT_TEMPLATE_ID" "$SEAT_TEMPLATE_NAME" || exit 1
  seat_destroy_ct "$SEAT_WS_ID" "$SEAT_WS_NAME"
  seat_destroy_ct "$SEAT_CT_ID" "$SEAT_CT_NAME"
  pve_remote ZONE="$HOST_SDN_ZONE" VNET="$SEAT_VNET" SUBNET="$SEAT_SUBNET" USER_ID="$SEAT_PVE_USER" POOL="$SEAT_NAME" \
    STORAGE="$SEAT_ISO_STORAGE" DIR="$SEAT_ISO_PATH" <<'EOF'
set -euo pipefail
subnet_id="$ZONE-${SUBNET/\//-}"
if pvesm status --storage "$STORAGE" >/dev/null 2>&1; then
  pvesm remove "$STORAGE"
fi
rm -rf "$DIR"
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
