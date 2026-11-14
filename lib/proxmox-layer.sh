readonly PROXMOX_VM=talos-lab-pve
readonly PROXMOX_NET=talos-lab
readonly PROXMOX_POOL=talos-lab
readonly PROXMOX_BRIDGE=virbr-talos
readonly PROXMOX_SUBNET=10.77.0.0/24
readonly PROXMOX_GATEWAY=10.77.0.1
readonly PROXMOX_ADDRESS=10.77.0.10
readonly PROXMOX_MAC=52:54:00:1a:b5:10
readonly PROXMOX_MEMORY_GIB=24
readonly PROXMOX_VCPUS=8
readonly PROXMOX_DISK_GIB=200
readonly PROXMOX_NODE=pve
readonly PROXMOX_DISK_VOLUME=pve.qcow2
readonly PROXMOX_ISO_VOLUME=pve-auto.iso
readonly PROXMOX_ISO_NAME=proxmox-ve_9.2-1.iso
readonly PROXMOX_ISO_URL="https://enterprise.proxmox.com/iso/$PROXMOX_ISO_NAME"
readonly PROXMOX_ISO_SHA256=4e88fe416df9b527624a175f24c9aa07c714d3332afb1ee3dbf3879573ef2c6c
readonly PROXMOX_ASSISTANT_IMAGE=talos-lab/pve-assistant:local
readonly PROXMOX_API_USER=talos-lab@pve
readonly PROXMOX_API_TOKEN=kit
readonly PROXMOX_API_ROLES=PVEVMAdmin,PVEDatastoreAdmin,PVESDNUser
readonly PROXMOX_INSTALL_TIMEOUT=1800
readonly PROXMOX_REQUIRED_PRIVILEGES=(
  VM.Allocate VM.Audit VM.PowerMgmt VM.Config.CDROM VM.Config.CPU VM.Config.Disk
  VM.Config.Memory VM.Config.Network VM.Config.Options
  Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit SDN.Use
)

PROXMOX_STATE="$LAB_STATE/proxmox"
PROXMOX_SSH_DIR="$PROXMOX_STATE/ssh"
PROXMOX_TARGET="$LAB_STATE/pve-target.env"
PROXMOX_API="https://$PROXMOX_ADDRESS:8006/api2/json"

virt() {
  virsh -q -c qemu:///system "$@"
}

proxmox_preflight() {
  local tool nested available_kib required_kib route
  for tool in virsh docker curl jq openssl sha256sum ufw ip; do
    command -v "$tool" >/dev/null || die "required tool is missing: $tool"
  done
  sudo -n true 2>/dev/null || die "passwordless sudo is required to manage the lab ufw rules"
  nested="$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)"
  [[ "$nested" == Y || "$nested" == 1 ]] || die "nested virtualization is not enabled in the kvm module, value: ${nested:-unset}"
  if ! virt dominfo "$PROXMOX_VM" >/dev/null 2>&1; then
    available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    required_kib=$(((PROXMOX_MEMORY_GIB + 8) * 1024 * 1024))
    ((available_kib >= required_kib)) || die "host has ${available_kib} KiB available, the lab needs ${required_kib} KiB"
  fi
  route="$(ip -4 route show "$PROXMOX_SUBNET")"
  [[ -z "$route" || "$route" == *"dev $PROXMOX_BRIDGE"* ]] || die "lab subnet $PROXMOX_SUBNET is already routed: $route"
}

proxmox_fetch_iso() {
  local dir="$PROXMOX_STATE/download" iso actual
  mkdir -p "$dir"
  iso="$dir/$PROXMOX_ISO_NAME"
  if [[ -f "$iso" && "$(sha256sum "$iso" | cut -d' ' -f1)" == "$PROXMOX_ISO_SHA256" ]]; then
    log "proxmox iso already downloaded and verified"
    return 0
  fi
  log "downloading $PROXMOX_ISO_NAME"
  curl --fail --silent --show-error --location --retry 3 --continue-at - --output "$iso.part" "$PROXMOX_ISO_URL"
  actual="$(sha256sum "$iso.part" | cut -d' ' -f1)"
  if [[ "$actual" != "$PROXMOX_ISO_SHA256" ]]; then
    rm -f "$iso.part"
    die "$PROXMOX_ISO_NAME checksum mismatch: got $actual, expected $PROXMOX_ISO_SHA256"
  fi
  mv "$iso.part" "$iso"
  log "proxmox iso verified"
}

proxmox_assistant() {
  docker run --rm --user "$(id -u):$(id -g)" \
    --env HOME=/tmp \
    --volume "$PROXMOX_STATE/download:/iso:ro" \
    --volume "$PROXMOX_STATE/build:/work" \
    --workdir /work \
    "$PROXMOX_ASSISTANT_IMAGE" "$@"
}

proxmox_render_answer() {
  cat <<EOF
[global]
keyboard = "en-us"
country = "us"
fqdn = "$PROXMOX_NODE.talos-lab.internal"
mailto = "lab@talos-lab.invalid"
timezone = "UTC"
root-password-hashed = "$1"
root-ssh-keys = ["$2"]

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "ext4"
disk-list = ["vda"]
EOF
}

proxmox_build_installer() {
  local build="$PROXMOX_STATE/build" password="$PROXMOX_STATE/root-password" hash="$PROXMOX_STATE/root-password.hash" answer
  mkdir -p "$build"
  log "building proxmox install assistant image"
  docker build --quiet --tag "$PROXMOX_ASSISTANT_IMAGE" "$LAB_ROOT/docker/pve-assistant" >/dev/null
  if [[ ! -s "$password" ]]; then
    openssl rand -hex 24 | tr -d '\n' >"$password"
  fi
  if [[ ! -s "$hash" ]]; then
    openssl passwd -6 -stdin <"$password" >"$hash"
  fi
  mkdir -p "$PROXMOX_SSH_DIR"
  if [[ ! -s "$PROXMOX_SSH_DIR/id_ed25519" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C talos-lab -f "$PROXMOX_SSH_DIR/id_ed25519"
  fi
  answer="$(proxmox_render_answer "$(<"$hash")" "$(<"$PROXMOX_SSH_DIR/id_ed25519.pub")")"
  if [[ ! -f "$build/answer.toml" || "$(<"$build/answer.toml")" != "$answer" ]]; then
    printf '%s\n' "$answer" >"$build/answer.toml"
    rm -f "$build/$PROXMOX_ISO_VOLUME"
  fi
  proxmox_assistant validate-answer /work/answer.toml >/dev/null
  if [[ -s "$build/$PROXMOX_ISO_VOLUME" ]]; then
    log "unattended installer already built"
    return 0
  fi
  log "building unattended installer"
  proxmox_assistant prepare-iso "/iso/$PROXMOX_ISO_NAME" \
    --fetch-from iso \
    --answer-file /work/answer.toml \
    --tmp /work \
    --output "/work/$PROXMOX_ISO_VOLUME" >/dev/null
  [[ -s "$build/$PROXMOX_ISO_VOLUME" ]] || die "assistant did not produce $build/$PROXMOX_ISO_VOLUME"
}

proxmox_ufw() {
  local action="$1"
  if [[ "$action" == add ]]; then
    sudo -n ufw allow in on "$PROXMOX_BRIDGE" proto udp to any port 67 >/dev/null
    sudo -n ufw allow in on "$PROXMOX_BRIDGE" proto udp to any port 53 >/dev/null
    sudo -n ufw allow in on "$PROXMOX_BRIDGE" proto tcp to any port 53 >/dev/null
    sudo -n ufw route allow in on "$PROXMOX_BRIDGE" >/dev/null
  else
    sudo -n ufw delete allow in on "$PROXMOX_BRIDGE" proto udp to any port 67 >/dev/null
    sudo -n ufw delete allow in on "$PROXMOX_BRIDGE" proto udp to any port 53 >/dev/null
    sudo -n ufw delete allow in on "$PROXMOX_BRIDGE" proto tcp to any port 53 >/dev/null
    sudo -n ufw route delete allow in on "$PROXMOX_BRIDGE" >/dev/null
  fi
}

proxmox_ensure_network() {
  local xml="$PROXMOX_STATE/network.xml"
  if ! virt net-info "$PROXMOX_NET" >/dev/null 2>&1; then
    cat >"$xml" <<EOF
<network>
  <name>$PROXMOX_NET</name>
  <forward mode='nat'/>
  <bridge name='$PROXMOX_BRIDGE' stp='on' delay='0'/>
  <ip address='$PROXMOX_GATEWAY' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.77.0.100' end='10.77.0.200'/>
      <host mac='$PROXMOX_MAC' ip='$PROXMOX_ADDRESS'/>
    </dhcp>
  </ip>
</network>
EOF
    virt net-define "$xml" >/dev/null
    log "libvirt network $PROXMOX_NET defined"
  fi
  if [[ "$(virt net-info "$PROXMOX_NET" | awk '/^Active:/ {print $2}')" != yes ]]; then
    virt net-start "$PROXMOX_NET" >/dev/null
    log "libvirt network $PROXMOX_NET started"
  fi
  proxmox_ufw add
  log "ufw rules applied for $PROXMOX_BRIDGE"
}

proxmox_ensure_storage() {
  local iso="$PROXMOX_STATE/build/$PROXMOX_ISO_VOLUME" size
  if ! virt pool-info "$PROXMOX_POOL" >/dev/null 2>&1; then
    virt pool-define-as "$PROXMOX_POOL" dir --target "/var/lib/libvirt/images/$PROXMOX_POOL" >/dev/null
    virt pool-build "$PROXMOX_POOL" >/dev/null
    log "libvirt pool $PROXMOX_POOL defined"
  fi
  if [[ "$(virt pool-info "$PROXMOX_POOL" | awk '/^State:/ {print $2}')" != running ]]; then
    virt pool-start "$PROXMOX_POOL" >/dev/null
  fi
  if ! virt vol-info --pool "$PROXMOX_POOL" "$PROXMOX_DISK_VOLUME" >/dev/null 2>&1; then
    virt vol-create-as "$PROXMOX_POOL" "$PROXMOX_DISK_VOLUME" "${PROXMOX_DISK_GIB}G" --format qcow2 >/dev/null
    log "sparse ${PROXMOX_DISK_GIB}G disk created"
  fi
  if ! virt vol-info --pool "$PROXMOX_POOL" "$PROXMOX_ISO_VOLUME" >/dev/null 2>&1; then
    size="$(stat -c %s "$iso")"
    virt vol-create-as "$PROXMOX_POOL" "$PROXMOX_ISO_VOLUME" "$size" --format raw >/dev/null
    log "uploading unattended installer to the pool"
    virt vol-upload --pool "$PROXMOX_POOL" "$PROXMOX_ISO_VOLUME" "$iso"
  fi
}

proxmox_ensure_vm() {
  local xml="$PROXMOX_STATE/domain.xml"
  if ! virt dominfo "$PROXMOX_VM" >/dev/null 2>&1; then
    cat >"$xml" <<EOF
<domain type='kvm'>
  <name>$PROXMOX_VM</name>
  <memory unit='GiB'>$PROXMOX_MEMORY_GIB</memory>
  <vcpu>$PROXMOX_VCPUS</vcpu>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <firmware>
      <feature enabled='no' name='secure-boot'/>
      <feature enabled='no' name='enrolled-keys'/>
    </firmware>
  </os>
  <features><acpi/><apic/></features>
  <cpu mode='host-passthrough' check='none'/>
  <clock offset='utc'/>
  <on_poweroff>destroy</on_poweroff>
  <on_reboot>restart</on_reboot>
  <on_crash>destroy</on_crash>
  <devices>
    <disk type='volume' device='disk'>
      <driver name='qemu' type='qcow2' discard='unmap'/>
      <source pool='$PROXMOX_POOL' volume='$PROXMOX_DISK_VOLUME'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <disk type='volume' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source pool='$PROXMOX_POOL' volume='$PROXMOX_ISO_VOLUME'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
      <boot order='2'/>
    </disk>
    <interface type='network'>
      <source network='$PROXMOX_NET'/>
      <mac address='$PROXMOX_MAC'/>
      <model type='virtio'/>
    </interface>
    <serial type='pty'/>
    <console type='pty'/>
    <graphics type='vnc' listen='127.0.0.1' autoport='yes'/>
    <video><model type='virtio'/></video>
  </devices>
</domain>
EOF
    virt define "$xml" >/dev/null
    log "virtual machine $PROXMOX_VM defined"
  fi
  if [[ "$(virt domstate "$PROXMOX_VM")" != running ]]; then
    virt start "$PROXMOX_VM" >/dev/null
    log "virtual machine $PROXMOX_VM started"
  fi
}

proxmox_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/proxmox-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  virt dominfo "$PROXMOX_VM" >"$dir/dominfo.txt" 2>&1 || true
  virt domstate --reason "$PROXMOX_VM" >"$dir/domstate.txt" 2>&1 || true
  virt net-dhcp-leases "$PROXMOX_NET" >"$dir/leases.txt" 2>&1 || true
  virt screenshot "$PROXMOX_VM" --file "$dir/console.ppm" >"$dir/screenshot.txt" 2>&1 || true
  sudo -n ufw status verbose >"$dir/ufw.txt" 2>&1 || true
  ip -4 addr show "$PROXMOX_BRIDGE" >"$dir/bridge.txt" 2>&1 || true
  curl --insecure --silent --show-error --max-time 10 --output /dev/null \
    --write-out 'http=%{http_code} connect=%{time_connect}\n' "https://$PROXMOX_ADDRESS:8006/" >"$dir/api.txt" 2>&1 || true
  die "$reason. Context saved in $dir. VM state: $(tr '\n' ' ' <"$dir/domstate.txt"). Leases: $(tr -s ' ' <"$dir/leases.txt" | tr '\n' ';'). API probe: $(tr '\n' ' ' <"$dir/api.txt")"
}

proxmox_wait_for_api() {
  local deadline=$((SECONDS + PROXMOX_INSTALL_TIMEOUT)) state last_report=$SECONDS
  log "waiting for the unattended install to finish and the Proxmox API to answer"
  until curl --insecure --silent --fail --max-time 5 --output /dev/null "https://$PROXMOX_ADDRESS:8006/"; do
    state="$(virt domstate "$PROXMOX_VM" 2>&1 || true)"
    if [[ "$state" != running ]]; then
      proxmox_capture_failure "Proxmox VM left the running state while installing"
    fi
    if ((SECONDS >= deadline)); then
      proxmox_capture_failure "Proxmox API did not answer within ${PROXMOX_INSTALL_TIMEOUT}s"
    fi
    if ((SECONDS - last_report >= 60)); then
      log "still installing, vm is $state, $((deadline - SECONDS))s left"
      last_report=$SECONDS
    fi
    sleep 10
  done
  log "Proxmox API is answering"
}

proxmox_tls_pin() {
  openssl s_client -connect "$PROXMOX_ADDRESS:8006" </dev/null 2>/dev/null |
    openssl x509 -pubkey -noout |
    openssl pkey -pubin -outform der |
    openssl dgst -sha256 -binary |
    base64
}

proxmox_root_session() {
  local response="" attempt
  PROXMOX_PIN="$1"
  for ((attempt = 1; attempt <= 30; attempt++)); do
    if response="$(curl --silent --show-error --fail-with-body --insecure --max-time 20 \
      --pinnedpubkey "sha256//$PROXMOX_PIN" \
      --data-urlencode 'username=root@pam' \
      --data-urlencode "password@$PROXMOX_STATE/root-password" \
      "$PROXMOX_API/access/ticket" 2>&1)"; then
      PROXMOX_ROOT_TICKET="$(jq -er .data.ticket <<<"$response")"
      PROXMOX_ROOT_CSRF="$(jq -er .data.CSRFPreventionToken <<<"$response")"
      return 0
    fi
    sleep 5
  done
  die "root login to Proxmox failed after $attempt attempts: $response"
}

proxmox_root_api() {
  local method="$1" path="$2" body status=0
  shift 2
  body="$(curl --silent --show-error --fail-with-body --insecure --max-time 120 \
    --pinnedpubkey "sha256//$PROXMOX_PIN" \
    --config <(printf 'header = "Cookie: PVEAuthCookie=%s"\nheader = "CSRFPreventionToken: %s"\n' "$PROXMOX_ROOT_TICKET" "$PROXMOX_ROOT_CSRF") \
    -X "$method" "$PROXMOX_API$path" "$@" 2>&1)" || status=$?
  if ((status != 0)); then
    die "Proxmox API $method $path as root failed with curl exit $status: $body"
  fi
  printf '%s\n' "$body"
}

proxmox_bootstrap_api() {
  local pin users tokens created secret
  pin="$(proxmox_tls_pin)"
  [[ -n "$pin" ]] || die "could not read the TLS public key from $PROXMOX_ADDRESS:8006"
  proxmox_root_session "$pin"
  users="$(proxmox_root_api GET /access/users)"
  if ! jq -e --arg user "$PROXMOX_API_USER" '.data | any(.userid == $user)' <<<"$users" >/dev/null; then
    proxmox_root_api POST /access/users --data-urlencode "userid=$PROXMOX_API_USER" >/dev/null
  fi
  proxmox_root_api PUT /access/acl \
    --data-urlencode path=/ \
    --data-urlencode "users=$PROXMOX_API_USER" \
    --data-urlencode "roles=$PROXMOX_API_ROLES" \
    --data-urlencode propagate=1 >/dev/null
  tokens="$(proxmox_root_api GET "/access/users/$PROXMOX_API_USER/token")"
  if jq -e --arg token "$PROXMOX_API_TOKEN" '.data | any(.tokenid == $token)' <<<"$tokens" >/dev/null; then
    proxmox_root_api DELETE "/access/users/$PROXMOX_API_USER/token/$PROXMOX_API_TOKEN" >/dev/null
  fi
  created="$(proxmox_root_api POST "/access/users/$PROXMOX_API_USER/token/$PROXMOX_API_TOKEN" --data-urlencode privsep=0)"
  secret="$(jq -er .data.value <<<"$created")" || die "Proxmox did not return a secret for the new API token"
  {
    printf 'PVE_URL=%q\n' "https://$PROXMOX_ADDRESS:8006"
    printf 'PVE_NODE=%q\n' "$PROXMOX_NODE"
    printf 'PVE_TOKEN_ID=%q\n' "$PROXMOX_API_USER!$PROXMOX_API_TOKEN"
    printf 'PVE_TOKEN_SECRET=%q\n' "$secret"
    printf 'PVE_TLS_PIN=%q\n' "$pin"
    printf 'PVE_ISO_STORAGE=%q\n' local
    printf 'PVE_DISK_STORAGE=%q\n' local-lvm
    printf 'PVE_BRIDGE=%q\n' vmbr0
    printf 'PVE_SSH=%q\n' "root@$PROXMOX_ADDRESS"
    printf 'PVE_SSH_KEY=%q\n' "$PROXMOX_SSH_DIR/id_ed25519"
    printf 'PVE_SSH_KNOWN_HOSTS=%q\n' "$PROXMOX_SSH_DIR/known_hosts"
  } >"$PROXMOX_TARGET"
  log "API token written to $PROXMOX_TARGET"
}

proxmox_pin_ssh() {
  local known="$PROXMOX_SSH_DIR/known_hosts" scanned
  if [[ ! -s "$known" ]]; then
    scanned="$(ssh-keyscan -T 10 -t ed25519 "$PROXMOX_ADDRESS" 2>/dev/null)"
    [[ -n "$scanned" ]] || die "could not read the SSH host key of $PROXMOX_ADDRESS"
    printf '%s\n' "$scanned" >"$known"
    log "SSH host key of $PROXMOX_ADDRESS recorded in $known"
  fi
}

proxmox_verify() {
  local version permissions privilege missing=() network storage status flags egress
  pve_load_target || exit 1
  version="$(pve_api GET /version)" || exit 1
  version="$(jq -er .data.version <<<"$version")" || die "Proxmox returned an unreadable version"
  [[ "$version" == 9.* ]] || die "expected Proxmox 9.x, API token reached version $version"

  permissions="$(pve_api GET '/access/permissions?path=/')" || exit 1
  for privilege in "${PROXMOX_REQUIRED_PRIVILEGES[@]}"; do
    if ! jq -e --arg p "$privilege" '.data["/"][$p] == 1' <<<"$permissions" >/dev/null; then
      missing+=("$privilege")
    fi
  done
  ((${#missing[@]} == 0)) || die "API token $PVE_TOKEN_ID lacks privileges: ${missing[*]}"

  proxmox_root_session "$PVE_TLS_PIN"
  network="$(proxmox_root_api GET "/nodes/$PVE_NODE/network/$PVE_BRIDGE")"
  jq -e '.data.type == "bridge" and (.data.active == 1)' <<<"$network" >/dev/null ||
    die "bridge $PVE_BRIDGE is not active on $PVE_NODE: $network"

  storage="$(proxmox_root_api GET "/nodes/$PVE_NODE/storage")"
  jq -e --arg s "$PVE_ISO_STORAGE" '.data | any(.storage == $s and (.content | split(",") | index("iso")))' <<<"$storage" >/dev/null ||
    die "storage $PVE_ISO_STORAGE cannot hold ISOs: $storage"
  jq -e --arg s "$PVE_DISK_STORAGE" '.data | any(.storage == $s and (.content | split(",") | index("images")))' <<<"$storage" >/dev/null ||
    die "storage $PVE_DISK_STORAGE cannot hold VM disks: $storage"

  status="$(proxmox_root_api GET "/nodes/$PVE_NODE/status")"
  flags="$(jq -er .data.cpuinfo.flags <<<"$status")" || die "Proxmox did not report CPU flags: $status"
  [[ " $flags " == *" vmx "* || " $flags " == *" svm "* ]] || die "guest CPU has no hardware virtualization flag, nested VMs cannot use KVM"

  egress="$(proxmox_root_api GET "/nodes/$PVE_NODE/query-url-metadata?url=https%3A%2F%2Fenterprise.proxmox.com%2Fiso%2FSHA256SUMS")"
  jq -e '.data' <<<"$egress" >/dev/null || die "Proxmox node could not reach enterprise.proxmox.com: $egress"

  pve_ssh pveversion >/dev/null || die "root SSH to $PVE_SSH with $PVE_SSH_KEY failed"

  log "proxmox verified: version $version, token privileges complete, $PVE_BRIDGE active, nested virtualization exposed, outbound https working, root SSH working"
}

proxmox_up() {
  proxmox_preflight
  mkdir -p "$PROXMOX_STATE"
  proxmox_fetch_iso
  proxmox_build_installer
  proxmox_ensure_network
  proxmox_ensure_storage
  proxmox_ensure_vm
  proxmox_wait_for_api
  proxmox_pin_ssh
  if ! { [[ -r "$PROXMOX_TARGET" ]] && pve_load_target && pve_api GET /version >/dev/null 2>&1; }; then
    proxmox_bootstrap_api
  fi
  proxmox_verify
}

proxmox_other_domains() {
  local domains
  domains="$(virt list --all --name)" || return 1
  grep -vxF "$PROXMOX_VM" <<<"$domains" | grep . | sort || true
}

proxmox_down() {
  local before after volume volumes leftovers=()
  before="$(proxmox_other_domains)"
  [[ -n "$before" ]] || die "could not list the other libvirt domains, refusing to tear down without a baseline"

  if virt dominfo "$PROXMOX_VM" >/dev/null 2>&1; then
    if [[ "$(virt domstate "$PROXMOX_VM")" == running ]]; then
      virt destroy "$PROXMOX_VM" >/dev/null
    fi
    virt undefine --nvram "$PROXMOX_VM" >/dev/null
    log "virtual machine $PROXMOX_VM removed"
  fi

  if virt pool-info "$PROXMOX_POOL" >/dev/null 2>&1; then
    if [[ "$(virt pool-info "$PROXMOX_POOL" | awk '/^State:/ {print $2}')" != running ]]; then
      virt pool-start "$PROXMOX_POOL" >/dev/null
    fi
    volumes="$(virt vol-list --pool "$PROXMOX_POOL" | awk '{print $1}')"
    while IFS= read -r volume; do
      [[ -n "$volume" ]] || continue
      virt vol-delete --pool "$PROXMOX_POOL" "$volume" >/dev/null
    done <<<"$volumes"
    virt pool-destroy "$PROXMOX_POOL" >/dev/null
    virt pool-delete "$PROXMOX_POOL" >/dev/null
    virt pool-undefine "$PROXMOX_POOL" >/dev/null
    log "libvirt pool $PROXMOX_POOL removed"
  fi

  if virt net-info "$PROXMOX_NET" >/dev/null 2>&1; then
    if [[ "$(virt net-info "$PROXMOX_NET" | awk '/^Active:/ {print $2}')" == yes ]]; then
      virt net-destroy "$PROXMOX_NET" >/dev/null
    fi
    virt net-undefine "$PROXMOX_NET" >/dev/null
    log "libvirt network $PROXMOX_NET removed"
  fi

  proxmox_ufw delete
  log "ufw rules for $PROXMOX_BRIDGE removed"
  rm -f "$PROXMOX_TARGET" "$PROXMOX_SSH_DIR/known_hosts"

  virt dominfo "$PROXMOX_VM" >/dev/null 2>&1 && leftovers+=("domain $PROXMOX_VM")
  virt pool-info "$PROXMOX_POOL" >/dev/null 2>&1 && leftovers+=("pool $PROXMOX_POOL")
  virt net-info "$PROXMOX_NET" >/dev/null 2>&1 && leftovers+=("network $PROXMOX_NET")
  if sudo -n ufw status | grep -qF "$PROXMOX_BRIDGE"; then
    leftovers+=("ufw rules for $PROXMOX_BRIDGE")
  fi
  ((${#leftovers[@]} == 0)) || die "teardown left resources behind: ${leftovers[*]}"

  after="$(proxmox_other_domains)"
  [[ "$before" == "$after" ]] || die "other libvirt domains changed during teardown. Before: $before. After: $after"
  log "proxmox layer removed, other libvirt domains unchanged"
}
