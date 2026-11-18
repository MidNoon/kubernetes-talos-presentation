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
readonly HOST_MEDIA_ROLE=TalosLabMedia
readonly HOST_MEDIA_PRIVILEGES=Datastore.Audit,Datastore.AllocateTemplate
readonly HOST_DOWNLOAD_ROLE=TalosLabDownload
readonly HOST_DOWNLOAD_PRIVILEGES=Sys.AccessNetwork
readonly HOST_ISO_ROOT=/var/lib/talos-lab/iso
readonly HOST_DEX_PORT=5556
readonly HOST_REMOTE_BIN=/usr/local/lib/talos-lab
readonly HOST_REMOTE_ETC=/etc/talos-lab
readonly HOST_SEAT_RANGE=10.88.0.0/16
readonly HOST_BLOCKED_RANGES='10.0.0.0/8, 100.64.0.0/10, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16'
readonly HOST_READY_TIMEOUT=300
readonly HOST_ADDRESS_HOOK=/etc/dhcp/dhclient-exit-hooks.d/talos-lab
readonly HOST_CT_TEMPLATE_PATTERN='^debian-13-standard_[0-9.-]+_amd64\.tar\.zst$'

LAB_SEATS_STATE="$LAB_STATE/seats"

host_name() {
  printf '%s.%s' "$1" "$LAB_TUNNEL_ZONE"
}

host_tunnel_name() {
  printf 'talos-lab-host-%s' "$HOST_INDEX"
}

host_is_primary() {
  [[ "$HOST_INDEX" == 0 ]]
}

host_services() {
  host_is_primary && printf 'talos-lab-dex\n'
  printf 'talos-lab-cloudflared\ntalos-lab-isolation\n'
}

host_omni_release_file() {
  local name="$1" target="$2" sums="$SHARED_STATE/bin/omni.sha256sum.txt"
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
  local dir="$SHARED_STATE/bin" cid platform
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
  printf '%s/bin/omnictl/omnictl-linux-amd64' "$SHARED_STATE"
}

host_random_password() {
  local alphabet=abcdefghijkmnpqrstuvwxyz23456789 password="" byte
  for byte in $(od -An -tu1 -N12 /dev/urandom); do
    password+="${alphabet:byte % ${#alphabet}:1}"
  done
  printf '%s-%s-%s\n' "${password:0:4}" "${password:4:4}" "${password:8:4}"
}

host_ensure_user() {
  local username="$1" users="$SHARED_STATE/users.tsv" password hash
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
  local users="$SHARED_STATE/users.tsv"
  [[ -f "$users" ]] || return 0
  awk -F'\t' -v u="$1" '$1 != u' "$users" >"$users.new"
  mv "$users.new" "$users"
}

host_user_password() {
  awk -F'\t' -v u="$1" '$1 == u {print $3}' "$SHARED_STATE/users.tsv"
}

host_ensure_secrets() {
  [[ -s "$SHARED_STATE/dex-client-secret" ]] || openssl rand -hex 32 >"$SHARED_STATE/dex-client-secret"
  [[ -s "$SHARED_STATE/proxmox-client-secret" ]] || openssl rand -hex 32 >"$SHARED_STATE/proxmox-client-secret"
  host_ensure_user instructor
}

host_render_dex() {
  local redirects proxmox number name
  redirects="$(for number in $(lab_seat_numbers); do printf 'https://%s/oidc/consume\n' "$(host_name "omni$number")"; done | jq -R . | jq -s -c .)"
  proxmox="$(for name in $(hosts_names); do printf 'https://%s\n' "$(host_name "pve$(sed -n 's/^HOST_INDEX=//p' "$LAB_HOSTS_STATE/$name/host.env")")"; done | jq -R . | jq -s -c .)"
  jq -n \
    --arg issuer "https://$(host_name auth)" \
    --arg listen "127.0.0.1:$HOST_DEX_PORT" \
    --arg secret "$(<"$SHARED_STATE/dex-client-secret")" \
    --arg proxmox_secret "$(<"$SHARED_STATE/proxmox-client-secret")" \
    --argjson proxmox "$proxmox" \
    --argjson redirects "$redirects" \
    --rawfile users "$SHARED_STATE/users.tsv" \
    '{
      issuer: $issuer,
      storage: {type: "memory"},
      web: {http: $listen},
      oauth2: {skipApprovalScreen: true, passwordConnector: "local"},
      staticClients: [
        {id: "omni", name: "Omni", secret: $secret, redirectURIs: $redirects},
        {id: "proxmox", name: "Proxmox", secret: $proxmox_secret, redirectURIs: $proxmox}
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
printf 'net.ipv4.ip_forward = 1\n' >/etc/sysctl.d/talos-lab.conf
sysctl -q -w net.ipv4.ip_forward=1
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
  dns="$(pve_ssh "awk '\$1 == \"nameserver\" && \$2 ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$/ {print \$2; exit}' /etc/resolv.conf")"
  [[ -n "$dns" ]] || die "the Proxmox host has no IPv4 nameserver in /etc/resolv.conf: $(pve_ssh "grep nameserver /etc/resolv.conf" | paste -sd' ')"
  [[ "$dns" != 127.* ]] || die "the Proxmox host resolves through $dns, which seats cannot reach. Put an upstream IPv4 nameserver first in /etc/resolv.conf"
  printf '%s\n' "$dns" >"$HOST_STATE/host-dns"
  log "$HOST_NAME prepared: dnsmasq, wireguard module, IPv4 forwarding, SDN zone $HOST_SDN_ZONE, Debian container template"
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
    local_sum="$(sha256sum "$SHARED_STATE/bin/$name" | cut -d' ' -f1)"
    remote_sum="$(pve_ssh "sha256sum $HOST_REMOTE_BIN/$name 2>/dev/null | cut -d' ' -f1" || true)"
    if [[ "$local_sum" != "$remote_sum" ]]; then
      pve_scp "$SHARED_STATE/bin/$name" "$PVE_SSH:$HOST_REMOTE_BIN/$name.part"
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
  pve_remote REALM="$HOST_PVE_REALM" ISSUER="https://$(host_name auth)" SECRET="$(<"$SHARED_STATE/proxmox-client-secret")" \
    INSTRUCTOR="instructor@$HOST_PVE_REALM" <<'EOF'
set -euo pipefail
options=(--issuer-url "$ISSUER" --client-id proxmox --client-key "$SECRET" --scopes "openid email profile" --autocreate 0 --default 1 --comment "Lab login")
if pveum realm list --output-format json | grep -q "\"realm\":\"$REALM\""; then
  pveum realm modify "$REALM" "${options[@]}"
else
  pveum realm add "$REALM" --type openid --username-claim name "${options[@]}"
fi
if ! pveum user list --output-format json | grep -q "\"userid\":\"$INSTRUCTOR\""; then
  pveum user add "$INSTRUCTOR"
fi
pveum acl modify / --users "$INSTRUCTOR" --roles PVEAuditor,PVEVMAdmin
EOF
  log "Proxmox realm $HOST_PVE_REALM signs in through Dex, instructor@$HOST_PVE_REALM can see and power every VM"
}

host_ensure_roles() {
  pve_remote MEDIA_ROLE="$HOST_MEDIA_ROLE" MEDIA_PRIVILEGES="$HOST_MEDIA_PRIVILEGES" \
    DOWNLOAD_ROLE="$HOST_DOWNLOAD_ROLE" DOWNLOAD_PRIVILEGES="$HOST_DOWNLOAD_PRIVILEGES" ISO_ROOT="$HOST_ISO_ROOT" <<'EOF'
set -euo pipefail
roles="$(pveum role list --output-format json)"
for pair in "$MEDIA_ROLE=$MEDIA_PRIVILEGES" "$DOWNLOAD_ROLE=$DOWNLOAD_PRIVILEGES"; do
  if grep -q "\"roleid\":\"${pair%%=*}\"" <<<"$roles"; then
    pveum role modify "${pair%%=*}" --privs "${pair#*=}"
  else
    pveum role add "${pair%%=*}" --privs "${pair#*=}"
  fi
done
install -d -m 700 "$ISO_ROOT"
EOF
  log "Proxmox roles $HOST_MEDIA_ROLE ($HOST_MEDIA_PRIVILEGES) and $HOST_DOWNLOAD_ROLE ($HOST_DOWNLOAD_PRIVILEGES) ready"
}

host_query_param() {
  local url="$1" name="$2" pair
  while IFS= read -r -d '&' pair; do
    if [[ "${pair%%=*}" == "$name" ]]; then
      printf '%s\n' "${pair#*=}"
      return 0
    fi
  done <<<"${url#*\?}&"
  return 1
}

host_dex_login() {
  local start="$1" username="$2" dir status=0 form="" result=""
  dir="$(mktemp -d)"
  printf '%s' "$username@$LAB_TUNNEL_ZONE" >"$dir/login"
  printf '%s' "$(host_user_password "$username")" >"$dir/password"
  form="$(lab_public_curl --silent --show-error --max-time 30 --location --cookie "$dir/jar" --cookie-jar "$dir/jar" \
    --output /dev/null --write-out '%{http_code} %{url_effective}' "$start" 2>&1)" || status=$?
  if ((status == 0)) && [[ "$form" == "200 https://$(host_name auth)/auth/local/login?"* ]]; then
    result="$(lab_public_curl --silent --show-error --max-time 60 --location --cookie "$dir/jar" --cookie-jar "$dir/jar" \
      --data-urlencode "login@$dir/login" --data-urlencode "password@$dir/password" \
      --output /dev/null --write-out '%{http_code} %{url_effective}' "${form#* }" 2>&1)" || status=$?
  fi
  rm -rf "$dir"
  if ((status != 0)); then
    fail "the Dex login for $username failed with curl exit $status: ${form%%\?*} ${result%%\?*}"
    return 1
  fi
  if [[ "$form" != "200 https://$(host_name auth)/auth/local/login?"* ]]; then
    fail "the login for $username did not reach the Dex password form, it ended at ${form%%\?*}"
    return 1
  fi
  if [[ "${result#* }" == "${form#* }" ]]; then
    fail "Dex rejected the password in users.tsv for $username"
    return 1
  fi
  printf '%s\n' "$result"
}

host_omni_login() {
  local username="$1" omni="$2" result
  result="$(host_dex_login "https://$omni/login?flow=frontend&redirect=/" "$username")" || return 1
  if [[ "$result" != "200 https://$omni/authenticate?"* ]] || ! host_query_param "${result#* }" token >/dev/null; then
    fail "Omni at $omni did not accept the Dex login for $username, it ended at ${result%%\?*}"
    return 1
  fi
}

host_pve_login() {
  local username="$1" pve response start="" result code="" state="" session
  pve="https://$(host_name "$(host_pve_label)")"
  if response="$(lab_public_curl --silent --show-error --max-time 30 --data-urlencode "realm=$HOST_PVE_REALM" \
    --data-urlencode "redirect-url=$pve" "$pve/api2/json/access/openid/auth-url" 2>&1)"; then
    start="$(jq -r '.data // empty' <<<"$response" 2>/dev/null)"
  fi
  if [[ -z "$start" ]]; then
    fail "Proxmox did not return an OpenID login URL: $response"
    return 1
  fi
  result="$(host_dex_login "$start" "$username")" || return 1
  if [[ "$result" == "200 $pve/?"* ]]; then
    code="$(host_query_param "${result#* }" code)"
    state="$(host_query_param "${result#* }" state)"
  fi
  if [[ -z "$code" || -z "$state" ]]; then
    fail "Dex did not send $username back to Proxmox with a code, it ended at ${result%%\?*}"
    return 1
  fi
  response="$(lab_public_curl --silent --show-error --max-time 30 --data "code=$code" --data "state=$state" \
    --data-urlencode "redirect-url=$pve" "$pve/api2/json/access/openid/login" 2>&1)" || response="curl failed: $response"
  session="$(jq -r --arg user "$username@$HOST_PVE_REALM" \
    'if .data.username == $user and .data.ticket and .data.CSRFPreventionToken then "\(.data.ticket)\n\(.data.CSRFPreventionToken)" else empty end' \
    <<<"$response" 2>/dev/null)"
  if [[ -z "$session" ]]; then
    fail "Proxmox did not open a session for $username@$HOST_PVE_REALM: $(jq -c 'del(.data.ticket, .data.CSRFPreventionToken)' <<<"$response" 2>/dev/null || printf '%s' "$response")"
    return 1
  fi
  HOST_PVE_TICKET="${session%%$'\n'*}"
  HOST_PVE_CSRF="${session#*$'\n'}"
}

host_pve_session_api() {
  local method="$1" path="$2" body status=0
  shift 2
  body="$(lab_public_curl --silent --show-error --fail-with-body --max-time 120 \
    --config <(printf 'cookie = "PVEAuthCookie=%s"\nheader = "CSRFPreventionToken: %s"\n' "$HOST_PVE_TICKET" "$HOST_PVE_CSRF") \
    -X "$method" "https://$(host_name "$(host_pve_label)")/api2/json$path" "$@" 2>&1)" || status=$?
  if ((status != 0)); then
    fail "Proxmox API $method $path as a lab login failed with curl exit $status: $body"
    return 1
  fi
  printf '%s\n' "$body"
}

host_workspace_login() {
  local username="$1" workspace="$2" dir status=0 result=""
  dir="$(mktemp -d)"
  printf '%s' "$(host_user_password "$username")" >"$dir/password"
  lab_public_curl --silent --show-error --max-time 30 --cookie-jar "$dir/jar" --output /dev/null \
    --data-urlencode "password@$dir/password" "https://$workspace/login" 2>"$dir/error" || status=$?
  if ((status == 0)); then
    result="$(lab_public_curl --silent --show-error --max-time 30 --location --cookie "$dir/jar" --output /dev/null \
      --write-out '%{http_code} %{url_effective}' "https://$workspace/" 2>"$dir/error")" || status=$?
  fi
  if ((status != 0)); then
    fail "the workspace login for $username at $workspace failed with curl exit $status: $(<"$dir/error")"
  elif ! grep -q 'code-server-session' "$dir/jar"; then
    fail "the workspace at $workspace rejected the password in users.tsv for $username"
    status=1
  elif [[ "$result" != "200 https://$workspace/"* || "$result" == "200 https://$workspace/login"* ]]; then
    fail "the workspace at $workspace issued a session for $username but then answered $result"
    status=1
  fi
  rm -rf "$dir"
  return "$status"
}

host_seat_iso_storage() {
  printf 'seat%s-iso' "$1"
}

host_verify_seat_logins() {
  local number="$1" iso pools storages wanted permissions
  iso="$(host_seat_iso_storage "$number")"
  host_workspace_login "student$number" "$(host_name "shell$number")" || host_capture_failure "student$number cannot sign in to the workspace"
  host_omni_login "student$number" "$(host_name "omni$number")" || host_capture_failure "student$number cannot sign in to Omni"
  host_pve_login "student$number" || host_capture_failure "student$number cannot sign in to Proxmox"
  pools="$(host_pve_session_api GET /pools | jq -c '[.data[].poolid]')" || host_capture_failure "student$number cannot list Proxmox pools"
  [[ "$pools" == "[\"seat$number\"]" ]] || host_capture_failure "student$number sees the Proxmox pools $pools, expected only seat$number"
  storages="$(host_pve_session_api GET /storage | jq -c '[.data[].storage] | sort')" || host_capture_failure "student$number cannot list Proxmox storage"
  wanted="$(jq -cn --arg a "$PVE_DISK_STORAGE" --arg b "$iso" '[$a, $b] | sort')"
  [[ "$storages" == "$wanted" ]] || host_capture_failure "student$number sees the Proxmox storage $storages, expected $wanted"
  permissions="$(host_pve_session_api GET /access/permissions)" || host_capture_failure "student$number cannot read their Proxmox permissions"
  jq -e --arg node "/nodes/$PVE_NODE" --arg iso "/storage/$iso" \
    '.data[$node]["Sys.AccessNetwork"] == 1 and .data[$iso]["Datastore.AllocateTemplate"] == 1' <<<"$permissions" >/dev/null ||
    host_capture_failure "student$number cannot download ISOs into $iso: $(jq -c --arg node "/nodes/$PVE_NODE" --arg iso "/storage/$iso" '{node: .data[$node], iso: .data[$iso]}' <<<"$permissions")"
  log "student$number signs in to shell$number, omni$number and Proxmox, where only pool seat$number and storage $iso are visible and $iso accepts downloads"
}

host_install_dex() {
  local current="$HOST_NAME"
  host_switch "$(hosts_primary)"
  host_render_dex | host_install_file 600 "$HOST_REMOTE_ETC/dex.json"
  pve_ssh "systemctl restart talos-lab-dex"
  host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
  host_switch "$current"
}

host_render_isolation() {
  local number
  printf 'table ip talos_lab\ndelete table ip talos_lab\n\ntable ip talos_lab {\n'
  printf '  set resolvers {\n    type ipv4_addr\n    elements = { %s }\n  }\n\n' "$(<"$HOST_STATE/host-dns")"
  printf '  set blocked {\n    type ipv4_addr\n    flags interval\n    elements = { %s }\n  }\n\n' "$HOST_BLOCKED_RANGES"
  printf '  chain forward {\n    type filter hook forward priority filter - 10; policy accept;\n'
  printf '    ip saddr != %s accept\n' "$HOST_SEAT_RANGE"
  printf '    ip daddr @resolvers meta l4proto { tcp, udp } th dport 53 accept\n'
  for ((number = 1; number <= SEAT_MAX; number++)); do
    printf '    ip saddr %s ip daddr %s accept\n' "$(host_seat_subnet "$number")" "$(host_seat_subnet "$number")"
  done
  printf '    ip daddr @blocked drop\n  }\n\n'
  printf '  chain input {\n    type filter hook input priority filter - 10; policy accept;\n'
  printf '    ip saddr != %s accept\n' "$HOST_SEAT_RANGE"
  printf '    ct state established,related accept\n    udp dport 67 accept\n    icmp type echo-request accept\n    drop\n  }\n}\n'
}

host_render_isolation_unit() {
  cat <<EOF
[Unit]
Before=pve-guests.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $HOST_REMOTE_ETC/isolation.nft
ExecStop=/usr/sbin/nft delete table ip talos_lab

[Install]
WantedBy=multi-user.target
EOF
}

host_isolation_probe() {
  local ct="$1"
  shift
  pve_ssh "pct exec $ct -- bash -s" <<EOF
probe() {
  if timeout 2 bash -c "exec 3<>/dev/tcp/\$2/\$3" 2>/dev/null; then
    printf '%s open\n' "\$1"
  else
    printf '%s closed\n' "\$1"
  fi
}
$(printf '%s\n' "$@" | awk '{printf "probe %s %s %s &\n", $1, $2, $3}')
wait
EOF
}

host_verify_isolation() {
  local number="$1" seats="$2" ct address other result wanted
  ct="$(seat_use "$number" && printf '%s' "$SEAT_WS_ID")"
  address="$(pve_ssh "ip -4 -o route get 1.1.1.1" | grep -oE 'src [0-9.]+' | cut -d' ' -f2)" ||
    host_capture_failure "the host's default route names no source address"
  other="$(awk -v own="$number" '$0 != own {print; exit}' <<<"$seats")"
  wanted="own-omni open
gateway-ssh closed
host-ssh closed
internet open"
  local probes=(
    "own-omni $(host_seat_address "$number" 2) 8080"
    "gateway-ssh $(host_seat_address "$number" 1) 22"
    "host-ssh $address 22"
    "internet factory.talos.dev 443"
  )
  if [[ -n "$other" ]]; then
    probes+=("other-seat-omni $(host_seat_address "$other" 2) 8080")
    wanted+=$'\n'"other-seat-omni closed"
  fi
  result="$(host_isolation_probe "$ct" "${probes[@]}" 2>&1 | sort)" || host_capture_failure "could not probe the network from seat $number's workspace: $result"
  [[ "$result" == "$(sort <<<"$wanted")" ]] ||
    host_capture_failure "seat $number's network isolation is wrong. Expected: $(sort <<<"$wanted" | paste -sd';'). Saw: $(paste -sd';' <<<"$result")"
  pve_ssh "pct exec $ct -- getent hosts factory.talos.dev" >/dev/null || host_capture_failure "seat $number's workspace cannot resolve names through $(<"$HOST_STATE/host-dns")"
  log "seat $number reaches its own Omni, names and the internet, and not the host$([[ -n "$other" ]] && printf ' or seat %s' "$other")"
}

host_render_address_hook() {
  cat <<'EOF'
talos_lab_address() {
  hosts=/etc/hosts
  case "$reason" in BOUND | RENEW | REBIND | REBOOT) ;; *) return 0 ;; esac
  [ -n "$new_ip_address" ] || return 0
  name="$(hostname)"
  current="$(awk -v name="$name" '$1 !~ /^(#|127\.|::1)/ { for (i = 2; i <= NF; i++) if ($i == name) { print $1; exit } }' "$hosts")"
  [ "$current" = "$new_ip_address" ] && return 0
  if [ -n "$current" ]; then
    sed -i "s/^$(printf '%s' "$current" | sed 's/\./\\./g')\([[:space:]]\)/$new_ip_address\1/" "$hosts"
  else
    printf '%s\t%s.internal %s\n' "$new_ip_address" "$name" "$name" >>"$hosts"
  fi
  logger -t talos-lab "address of $name changed from ${current:-none} to $new_ip_address, restarting pve-cluster and reloading SDN"
  systemd-run --no-block --quiet --collect --property=After=pve-cluster.service /bin/sh -c 'systemctl restart pve-cluster && pvesh set /cluster/sdn'
}
talos_lab_address
EOF
}

host_install_services() {
  local services
  services="$(host_services | paste -sd' ')"
  printf 'TUNNEL_TOKEN=%s\n' "$(<"$HOST_STATE/connector-token")" | host_install_file 600 "$HOST_REMOTE_ETC/cloudflared.env"
  if host_is_primary; then
    host_render_dex | host_install_file 600 "$HOST_REMOTE_ETC/dex.json"
    host_render_dex_unit | host_install_file 644 /etc/systemd/system/talos-lab-dex.service
  fi
  host_render_cloudflared_unit | host_install_file 644 /etc/systemd/system/talos-lab-cloudflared.service
  host_render_isolation | host_install_file 600 "$HOST_REMOTE_ETC/isolation.nft"
  host_render_isolation_unit | host_install_file 644 /etc/systemd/system/talos-lab-isolation.service
  host_render_address_hook | host_install_file 644 "$HOST_ADDRESS_HOOK"
  pve_ssh "systemctl daemon-reload && systemctl enable --quiet $services && systemctl restart $services"
}

host_service_logs() {
  local service
  for service in $(host_services); do
    printf '== %s\n' "$service"
    pve_ssh "systemctl status --no-pager --lines=0 $service; journalctl --no-pager --lines=60 --unit $service" 2>&1 || true
  done
}

host_capture_failure() {
  local reason="$1" dir label
  dir="$LAB_STATE/failures/host-$HOST_NAME-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  host_service_logs >"$dir/services.txt" 2>&1 || true
  pve_ssh "ip -4 addr; ip -4 route; ss -ltnup; pct list; qm list" >"$dir/host.txt" 2>&1 || true
  pve_ssh "cat /etc/pve/sdn/*.cfg" >"$dir/sdn.txt" 2>&1 || true
  for label in auth "$(host_pve_label)"; do
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

host_seat_subnet() {
  printf '10.88.%d.0/24' "$((10#$1))"
}

host_wanted_hostnames() {
  local number label
  if host_is_primary; then
    host_name auth
    printf '\n'
  fi
  host_name "$(host_pve_label)"
  printf '\n'
  for number in $(host_seats_on "$HOST_NAME"); do
    for label in omni kube shell; do
      host_name "$label$number"
      printf '\n'
    done
  done
}

host_render_ingress() {
  local number rules
  rules="$(
    if host_is_primary; then
      jq -n --arg host "$(host_name auth)" --arg service "http://127.0.0.1:$HOST_DEX_PORT" '{hostname: $host, service: $service}'
    fi
    jq -n --arg host "$(host_name "$(host_pve_label)")" '{hostname: $host, service: "https://127.0.0.1:8006", originRequest: {noTLSVerify: true}}'
    for number in $(host_seats_on "$HOST_NAME"); do
      jq -n --arg host "$(host_name "omni$number")" --arg service "http://$(host_seat_address "$number" 2):8080" '{hostname: $host, service: $service}'
      jq -n --arg host "$(host_name "kube$number")" --arg service "http://$(host_seat_address "$number" 2):8095" '{hostname: $host, service: $service}'
      jq -n --arg host "$(host_name "shell$number")" --arg service "http://$(host_seat_address "$number" 3):8443" '{hostname: $host, service: $service}'
    done
    jq -n '{service: "http_status:404"}'
  )"
  jq -s -c . <<<"$rules"
}

host_sync_tunnel() {
  local ingress="$HOST_STATE/tunnel-ingress.json" wanted host content
  (
    LAB_TUNNEL_NAME="$(host_tunnel_name)"
    tunnel_ensure || exit 1
    host_render_ingress >"$ingress"
    tunnel_set_ingress "$ingress" || exit 1
    wanted="$(host_wanted_hostnames)"
    while IFS= read -r host; do
      [[ -n "$host" ]] || continue
      LAB_TUNNEL_HOSTNAME="$host"
      tunnel_ensure_dns || exit 1
    done <<<"$wanted"
    while read -r host content; do
      [[ "$content" == "$CF_LAB_TUNNEL_ID.cfargotunnel.com" ]] || continue
      grep -qxF "$host" <<<"$wanted" && continue
      LAB_TUNNEL_HOSTNAME="$host"
      tunnel_remove_dns || exit 1
    done < <(cf_owned_records)
    if [[ ! -s "$HOST_STATE/connector-token" ]]; then
      tunnel_store_connector_token "$HOST_STATE/connector-token" || exit 1
    fi
  ) || exit 1
}

host_up_one() {
  local before after
  host_load "$1"
  hosts_require_primary
  if ! host_is_primary; then
    [[ -s "$LAB_HOSTS_STATE/$(hosts_primary)/connector-token" ]] || die "bring up $(hosts_primary) first, because it runs the lab sign-in"
  fi
  before="$(cf_snapshot_others)" || exit 1
  host_fetch_binaries
  host_ensure_secrets
  host_prepare
  host_upload_binaries
  host_sync_tunnel
  host_install_services
  if host_is_primary; then
    host_wait_local dex "http://127.0.0.1:$HOST_DEX_PORT/.well-known/openid-configuration"
  else
    host_install_dex
  fi
  host_ensure_realm
  host_ensure_roles
  host_verify
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during host up on $HOST_NAME. Before: $before. After: $after"
}

host_up() {
  local name names
  lab_load_config
  names="${1:-$(hosts_names)}"
  [[ -n "$names" ]] || die "no hosts yet, add one with ./lab hosts add <name> <index> <seats>"
  for name in $names; do
    host_up_one "$name"
  done
}

host_verify_address() {
  local address resolved
  address="$(pve_ssh "ip -4 -o route get 1.1.1.1" | grep -oE 'src [0-9.]+' | cut -d' ' -f2)" ||
    host_capture_failure "the host's default route names no source address"
  resolved="$(pve_ssh "hostname --ip-address")" || host_capture_failure "the host's name does not resolve"
  [[ " $resolved " == *" $address "* ]] ||
    host_capture_failure "the host's name resolves to $resolved, not its address $address, so pve-cluster cannot start. Fix /etc/hosts"
}

host_verify() {
  local service number seats
  for service in $(host_services); do
    pve_ssh "systemctl is-active --quiet $service" || host_capture_failure "$service is not active on $HOST_NAME"
  done
  host_wait_public dex "https://$(host_name auth)/.well-known/openid-configuration"
  host_wait_public "$(host_pve_label)" "https://$(host_name "$(host_pve_label)")/"
  host_verify_address
  host_pve_login instructor || host_capture_failure "instructor cannot sign in to $(host_pve_label)"
  log "instructor signs in to $(host_pve_label) through Dex"
  seats="$(host_seats_on "$HOST_NAME")"
  for number in $seats; do
    host_wait_public "omni for seat $number" "https://$(host_name "omni$number")/"
    host_wait_public "workspace for seat $number" "https://$(host_name "shell$number")/healthz"
    host_verify_seat_logins "$number"
    host_verify_isolation "$number" "$seats"
  done
  log "$HOST_NAME verified: Proxmox at https://$(host_name "$(host_pve_label)"), $(grep -c . <<<"$seats" || true) of $HOST_SEATS seats"
}

host_verify_hosts() {
  local name names
  lab_load_config
  names="${1:-$(hosts_names)}"
  for name in $names; do
    host_load "$name"
    host_verify
  done
}

host_down_one() {
  local before after leftovers=() vnets name labels=()
  host_load "$1"
  [[ -z "$(host_seats_on "$HOST_NAME")" ]] || die "$HOST_NAME still holds seats $(host_seats_on "$HOST_NAME" | paste -sd' '), delete them first"
  if host_is_primary; then
    for name in $(hosts_names); do
      [[ "$name" == "$HOST_NAME" || ! -s "$LAB_HOSTS_STATE/$name/connector-token" ]] ||
        die "$name still runs the lab and signs in through $HOST_NAME, run ./lab host down $name first"
    done
  fi
  vnets="$(pve_ssh "pvesh get /cluster/sdn/vnets --output-format json" | jq -r --arg zone "$HOST_SDN_ZONE" '.[] | select(.zone == $zone) | .vnet')" ||
    die "could not list SDN vnets on $HOST_NAME"
  [[ -z "$vnets" ]] || die "zone $HOST_SDN_ZONE on $HOST_NAME still has vnets: $(paste -sd' ' <<<"$vnets"), delete its seats first"
  before="$(cf_snapshot_others)" || exit 1
  pve_remote SERVICES="$(host_services | paste -sd' ')" BIN="$HOST_REMOTE_BIN" ETC="$HOST_REMOTE_ETC" ZONE="$HOST_SDN_ZONE" \
    REALM="$HOST_PVE_REALM" ROLES="$HOST_MEDIA_ROLE $HOST_DOWNLOAD_ROLE" ISO_ROOT="$HOST_ISO_ROOT" ADDRESS_HOOK="$HOST_ADDRESS_HOOK" <<'EOF'
set -euo pipefail
if pveum user list --output-format json | grep -q "\"userid\":\"instructor@$REALM\""; then
  pveum user delete "instructor@$REALM"
fi
if pveum realm list --output-format json | grep -q "\"realm\":\"$REALM\""; then
  pveum realm delete "$REALM"
fi
for role in $ROLES; do
  if pveum role list --output-format json | grep -q "\"roleid\":\"$role\""; then
    pveum role delete "$role"
  fi
done
rmdir "$ISO_ROOT" 2>/dev/null || true
for service in $SERVICES talos-lab-dex; do
  systemctl disable --now "$service" >/dev/null 2>&1 || true
  rm -f "/etc/systemd/system/$service.service"
done
systemctl daemon-reload
rm -rf "${BIN:?}" "${ETC:?}" /etc/modules-load.d/talos-lab.conf /etc/sysctl.d/talos-lab.conf "${ADDRESS_HOOK:?}"
if pvesh get "/cluster/sdn/zones/$ZONE" >/dev/null 2>&1; then
  pvesh delete "/cluster/sdn/zones/$ZONE" >/dev/null
  pvesh set /cluster/sdn >/dev/null
fi
EOF
  labels=("$(host_pve_label)")
  host_is_primary && labels+=(auth)
  (
    LAB_TUNNEL_NAME="$(host_tunnel_name)"
    for name in "${labels[@]}"; do
      LAB_TUNNEL_HOSTNAME="$(host_name "$name")"
      tunnel_remove_dns || exit 1
    done
    tunnel_remove || exit 1
  ) || exit 1
  rm -f "$HOST_STATE/connector-token" "$HOST_STATE/tunnel-ingress.json" "$HOST_STATE/host-dns"

  pve_ssh "systemctl list-unit-files 'talos-lab-*' --no-legend | grep -q ." && leftovers+=("talos-lab systemd units")
  pve_ssh "pvesh get /cluster/sdn/zones/$HOST_SDN_ZONE" >/dev/null 2>&1 && leftovers+=("SDN zone $HOST_SDN_ZONE")
  pve_ssh "pveum realm list --output-format json" | grep -q "\"realm\":\"$HOST_PVE_REALM\"" && leftovers+=("Proxmox realm $HOST_PVE_REALM")
  pve_ssh "pveum role list --output-format json" | grep -qE "\"roleid\":\"($HOST_MEDIA_ROLE|$HOST_DOWNLOAD_ROLE)\"" && leftovers+=("Proxmox lab roles")
  pve_ssh "test -e $HOST_ISO_ROOT" && leftovers+=("$HOST_ISO_ROOT")
  grep -qxF "$(host_tunnel_name)" <<<"$(cf_owned_tunnels)" && leftovers+=("tunnel $(host_tunnel_name)")
  for name in "${labels[@]}"; do
    grep -qxF "$(host_name "$name")" <<<"$(cf_owned_hostnames)" && leftovers+=("DNS record $(host_name "$name")")
  done
  ((${#leftovers[@]} == 0)) || die "teardown of $HOST_NAME left resources behind: ${leftovers[*]}"
  after="$(cf_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed during teardown of $HOST_NAME. Before: $before. After: $after"
  log "$HOST_NAME lab services removed, other tunnels and DNS records unchanged"
}

host_down() {
  local name names
  lab_load_config
  names="${1:-$(hosts_names | tac)}"
  for name in $names; do
    host_down_one "$name"
  done
}
