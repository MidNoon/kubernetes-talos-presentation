readonly LOCAL_NET=talos-lab
readonly LOCAL_BRIDGE=virbr-talos
readonly LOCAL_SUBNET=10.77.0.0/24
readonly LOCAL_GATEWAY=10.77.0.1
readonly LOCAL_POOL=talos-lab
readonly LOCAL_IMAGE_BUILD=20261116-2664
readonly LOCAL_IMAGE="debian-13-generic-amd64-$LOCAL_IMAGE_BUILD.qcow2"
readonly LOCAL_IMAGE_URL="https://cloud.debian.org/images/cloud/trixie/$LOCAL_IMAGE_BUILD/$LOCAL_IMAGE"
readonly LOCAL_IMAGE_SHA512=e53a93ef33f828ceed0e7278c2cc2753bdc7d5098fbfae15bd64b6d878db350ea3744247763a1c8ecb6b4019a0f623c38caf6038ad6f9c357fb4e01493ddf1a3
readonly LOCAL_MEMORY_GIB=36
readonly LOCAL_VCPUS=12
readonly LOCAL_DISK_GIB=300
readonly LOCAL_ACCESS_TIMEOUT=900
readonly LOCAL_STOP_TIMEOUT=600
readonly LOCAL_PRIVATE_RANGES=(10.0.0.0/8 100.64.0.0/10 169.254.0.0/16 172.16.0.0/12 192.168.0.0/16)

LOCAL_STATE="$LAB_STATE/local"

virt() {
  virsh -q -c qemu:///system "$@"
}

local_domain() {
  printf 'talos-lab-%s' "$HOST_NAME"
}

local_dir() {
  printf '%s/local' "$HOST_STATE"
}

local_running_domains() {
  virt list --name | grep -E '^talos-lab-' || true
}

local_require_running() {
  [[ -d "$(local_dir)" ]] || return 0
  [[ "$(virt domstate "$(local_domain)" 2>/dev/null)" == running ]] ||
    die "$HOST_NAME runs as $(local_domain) on this machine, which is not running. ./lab local up $HOST_NAME starts it"
}

local_preflight() {
  local tool nested available_kib required_kib route
  for tool in virsh qemu-img uv ssh-keygen ufw curl; do
    command -v "$tool" >/dev/null || die "required tool is missing: $tool"
  done
  sudo -n true 2>/dev/null || die "passwordless sudo is required to manage the lab ufw rules"
  nested="$(cat /sys/module/kvm_intel/parameters/nested /sys/module/kvm_amd/parameters/nested 2>/dev/null || true)"
  [[ "$nested" == Y || "$nested" == 1 ]] || die "nested virtualization is not enabled in the kvm module, value: ${nested:-unset}"
  if ! virt dominfo "$(local_domain)" >/dev/null 2>&1; then
    available_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
    required_kib=$(((LOCAL_MEMORY_GIB + 8) * 1024 * 1024))
    ((available_kib >= required_kib)) || die "this machine has ${available_kib} KiB available, $(local_domain) needs ${required_kib} KiB"
  fi
  route="$(ip -4 route show "$LOCAL_SUBNET")"
  [[ -z "$route" || "$route" == *"dev $LOCAL_BRIDGE"* ]] || die "lab subnet $LOCAL_SUBNET is already routed: $route"
}

local_fetch_image() {
  local target="$LOCAL_STATE/$LOCAL_IMAGE"
  mkdir -p "$LOCAL_STATE"
  if [[ -f "$target" && "$(sha512sum "$target" | cut -d' ' -f1)" == "$LOCAL_IMAGE_SHA512" ]]; then
    return 0
  fi
  log "downloading $LOCAL_IMAGE"
  curl --fail --silent --show-error --location --output "$target.part" "$LOCAL_IMAGE_URL"
  [[ "$(sha512sum "$target.part" | cut -d' ' -f1)" == "$LOCAL_IMAGE_SHA512" ]] || die "$LOCAL_IMAGE does not match its pinned SHA-512"
  mv "$target.part" "$target"
}

local_ufw() {
  local action="$1" range
  if [[ "$action" == add ]]; then
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto udp to any port 67 >/dev/null 2>&1 || true
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto udp to any port 53 >/dev/null 2>&1 || true
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto tcp to any port 53 >/dev/null 2>&1 || true
    sudo -n ufw delete deny in on "$LOCAL_BRIDGE" >/dev/null 2>&1 || true
    sudo -n ufw insert 1 deny in on "$LOCAL_BRIDGE" >/dev/null
    sudo -n ufw insert 1 allow in on "$LOCAL_BRIDGE" proto tcp to any port 53 >/dev/null
    sudo -n ufw insert 1 allow in on "$LOCAL_BRIDGE" proto udp to any port 53 >/dev/null
    sudo -n ufw insert 1 allow in on "$LOCAL_BRIDGE" proto udp to any port 67 >/dev/null
    for range in "${LOCAL_PRIVATE_RANGES[@]}"; do
      sudo -n ufw route deny in on "$LOCAL_BRIDGE" to "$range" >/dev/null
    done
    sudo -n ufw route allow in on "$LOCAL_BRIDGE" >/dev/null
  else
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto udp to any port 67 >/dev/null
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto udp to any port 53 >/dev/null
    sudo -n ufw delete allow in on "$LOCAL_BRIDGE" proto tcp to any port 53 >/dev/null
    sudo -n ufw delete deny in on "$LOCAL_BRIDGE" >/dev/null
    for range in "${LOCAL_PRIVATE_RANGES[@]}"; do
      sudo -n ufw route delete deny in on "$LOCAL_BRIDGE" to "$range" >/dev/null
    done
    sudo -n ufw route delete allow in on "$LOCAL_BRIDGE" >/dev/null
  fi
}

local_ensure_network() {
  local xml="$LOCAL_STATE/network.xml"
  if ! virt net-info "$LOCAL_NET" >/dev/null 2>&1; then
    cat >"$xml" <<EOF
<network>
  <name>$LOCAL_NET</name>
  <forward mode='nat'/>
  <bridge name='$LOCAL_BRIDGE' stp='on' delay='0'/>
  <ip address='$LOCAL_GATEWAY' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.77.0.100' end='10.77.0.200'/>
    </dhcp>
  </ip>
</network>
EOF
    virt net-define "$xml" >/dev/null
    log "libvirt network $LOCAL_NET defined"
  fi
  if [[ "$(virt net-info "$LOCAL_NET" | awk '/^Active:/ {print $2}')" != yes ]]; then
    virt net-start "$LOCAL_NET" >/dev/null
  fi
  local_ufw add
  log "libvirt network $LOCAL_NET reaches the internet but not this machine, the LAN or any private range"
}

local_ensure_pool() {
  if ! virt pool-info "$LOCAL_POOL" >/dev/null 2>&1; then
    virt pool-define-as "$LOCAL_POOL" dir --target "/var/lib/libvirt/images/$LOCAL_POOL" >/dev/null
    virt pool-build "$LOCAL_POOL" >/dev/null
    log "libvirt pool $LOCAL_POOL defined"
  fi
  if [[ "$(virt pool-info "$LOCAL_POOL" | awk '/^State:/ {print $2}')" != running ]]; then
    virt pool-start "$LOCAL_POOL" >/dev/null
  fi
  if ! virt vol-info --pool "$LOCAL_POOL" "$LOCAL_IMAGE" >/dev/null 2>&1; then
    virt vol-create-as "$LOCAL_POOL" "$LOCAL_IMAGE" "$(stat -c %s "$LOCAL_STATE/$LOCAL_IMAGE")" --format qcow2 >/dev/null
    virt vol-upload --pool "$LOCAL_POOL" "$LOCAL_IMAGE" "$LOCAL_STATE/$LOCAL_IMAGE"
    log "Debian 13 cloud image $LOCAL_IMAGE_BUILD uploaded to pool $LOCAL_POOL"
  fi
}

local_ensure_keys() {
  local dir known entry
  dir="$(local_dir)"
  mkdir -p "$dir"
  chmod 700 "$dir"
  [[ -s "$dir/ssh_host_ed25519_key" ]] || ssh-keygen -q -t ed25519 -N '' -C "$HOST_NAME" -f "$dir/ssh_host_ed25519_key"
  [[ -s "$dir/root-password" ]] || host_random_password >"$dir/root-password"
  chmod 600 "$dir/root-password"
  known="$(access_known_hosts)"
  entry="$(cf_access_hostname) $(cut -d' ' -f1,2 "$dir/ssh_host_ed25519_key.pub")"
  mkdir -p "$(dirname "$known")"
  if ! grep -qxF "$entry" "$known" 2>/dev/null; then
    { grep -v "^$(cf_access_hostname) " "$known" 2>/dev/null || true; printf '%s\n' "$entry"; } >"$known.new"
    mv "$known.new" "$known"
    chmod 600 "$known"
  fi
}

local_render_user_data() {
  local dir
  dir="$(local_dir)"
  cat <<EOF
#cloud-config
hostname: $HOST_NAME
fqdn: $HOST_NAME.internal
manage_etc_hosts: false
ssh_pwauth: false
disable_root: false
ssh_deletekeys: true
ssh_keys:
  ed25519_private: |
$(sed 's/^/    /' "$dir/ssh_host_ed25519_key")
  ed25519_public: $(<"$dir/ssh_host_ed25519_key.pub")
chpasswd:
  expire: false
  users:
    - name: root
      password: $(<"$dir/root-password")
      type: text
write_files:
  - path: /root/talos-access-bootstrap.sh
    permissions: '0700'
    content: |
$(sed 's/^/      /' "$(access_host_state)/bootstrap.sh")
runcmd:
  - [bash, /root/talos-access-bootstrap.sh]
  - [rm, -f, /root/talos-access-bootstrap.sh]
  - [touch, /etc/cloud/cloud-init.disabled]
EOF
}

local_build_seed() {
  local work volume="seed-$HOST_NAME.iso"
  work="$(mktemp -d)"
  (
    umask 077
    local_render_user_data >"$work/user-data"
    printf 'instance-id: %s-%s\nlocal-hostname: %s\n' "$(local_domain)" "$(date +%s)" "$HOST_NAME" >"$work/meta-data"
  )
  uv run --quiet --with pycdlib==1.14.0 python -I - "$work" "$work/seed.iso" <<'PY' || die "could not build the cloud-init seed for $HOST_NAME"
import io, pathlib, sys, pycdlib
source, target = pathlib.Path(sys.argv[1]), sys.argv[2]
iso = pycdlib.PyCdlib()
iso.new(interchange_level=3, joliet=3, rock_ridge="1.09", vol_ident="cidata")
for name in ("user-data", "meta-data"):
    data = (source / name).read_bytes()
    iso.add_fp(io.BytesIO(data), len(data), "/" + name.replace("-", "_").upper() + ".;1", rr_name=name, joliet_path="/" + name)
iso.write(target)
iso.close()
PY
  if virt vol-info --pool "$LOCAL_POOL" "$volume" >/dev/null 2>&1; then
    virt vol-delete --pool "$LOCAL_POOL" "$volume" >/dev/null
  fi
  virt vol-create-as "$LOCAL_POOL" "$volume" "$(stat -c %s "$work/seed.iso")" --format raw >/dev/null
  virt vol-upload --pool "$LOCAL_POOL" "$volume" "$work/seed.iso"
  rm -f "${work:?}/user-data" "${work:?}/meta-data" "${work:?}/seed.iso"
  rmdir "$work"
}

local_define_vm() {
  local xml
  xml="$(local_dir)/domain.xml"
  if ! virt vol-info --pool "$LOCAL_POOL" "$HOST_NAME.qcow2" >/dev/null 2>&1; then
    virt vol-create-as "$LOCAL_POOL" "$HOST_NAME.qcow2" "${LOCAL_DISK_GIB}G" --format qcow2 \
      --backing-vol "$LOCAL_IMAGE" --backing-vol-format qcow2 >/dev/null
  fi
  cat >"$xml" <<EOF
<domain type='kvm'>
  <name>$(local_domain)</name>
  <memory unit='GiB'>$LOCAL_MEMORY_GIB</memory>
  <vcpu>$LOCAL_VCPUS</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
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
      <source pool='$LOCAL_POOL' volume='$HOST_NAME.qcow2'/>
      <target dev='vda' bus='virtio'/>
      <boot order='1'/>
    </disk>
    <disk type='volume' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source pool='$LOCAL_POOL' volume='seed-$HOST_NAME.iso'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
    <interface type='network'>
      <source network='$LOCAL_NET'/>
      <mac address='52:54:00:1a:b6:$(printf '%02x' "$HOST_INDEX")'/>
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
  log "virtual machine $(local_domain) defined with ${LOCAL_MEMORY_GIB} GiB, $LOCAL_VCPUS vCPUs and a ${LOCAL_DISK_GIB}G thin disk"
}

local_wait_access() {
  local deadline=$((SECONDS + LOCAL_ACCESS_TIMEOUT))
  access_use_target || exit 1
  until pve_ssh true 2>/dev/null; do
    ((SECONDS < deadline)) || die "$(local_domain) did not come up through $(cf_access_hostname) within ${LOCAL_ACCESS_TIMEOUT}s. Its console: virsh -c qemu:///system console $(local_domain), root password in $(local_dir)/root-password"
    sleep 10
  done
}

local_drop_seed() {
  if virt domblklist "$(local_domain)" | awk '$1 == "sda" && $2 != "-" {found = 1} END {exit !found}'; then
    virt change-media "$(local_domain)" sda --eject --live --config >/dev/null 2>&1 || virt change-media "$(local_domain)" sda --eject --config >/dev/null
  fi
  if virt vol-info --pool "$LOCAL_POOL" "seed-$HOST_NAME.iso" >/dev/null 2>&1; then
    virt vol-delete --pool "$LOCAL_POOL" "seed-$HOST_NAME.iso" >/dev/null
  fi
}

local_up() {
  local host="$1" identity next
  lab_load_config
  host_select "$host"
  CF_ACCESS_INDEX="$HOST_INDEX"
  local_preflight
  [[ -s "$HOST_STATE/access/connector-token" ]] || access_up "$host"
  host_select "$host"
  CF_ACCESS_INDEX="$HOST_INDEX"
  local_fetch_image
  local_ensure_network
  local_ensure_pool
  local_ensure_keys
  if ! virt dominfo "$(local_domain)" >/dev/null 2>&1; then
    local_build_seed
    local_define_vm
  elif ! virt vol-info --pool "$LOCAL_POOL" "seed-$HOST_NAME.iso" >/dev/null 2>&1; then
    local_drop_seed
  fi
  if [[ "$(virt domstate "$(local_domain)")" != running ]]; then
    virt start "$(local_domain)" >/dev/null
    log "virtual machine $(local_domain) started"
  fi
  local_wait_access
  local_drop_seed
  identity="$(pve_ssh 'printf "%s, %s" "$(hostname)" "$(. /etc/os-release && printf %s "$PRETTY_NAME")"; if command -v pveversion >/dev/null; then printf ", %s" "$(pveversion)"; fi')" ||
    die "could not run a command on $HOST_NAME"
  next=". Next: ./lab host install $HOST_NAME"
  [[ "$identity" != *pve-manager/* ]] || next=""
  log "$HOST_NAME runs as $(local_domain) on this machine: $identity, reached through $(cf_access_hostname)$next"
}

local_stop() {
  local host="$1" deadline state
  lab_load_config
  host_select "$host"
  virt dominfo "$(local_domain)" >/dev/null 2>&1 || die "$HOST_NAME has no virtual machine $(local_domain) on this machine"
  if [[ "$(virt domstate "$(local_domain)")" == running ]]; then
    virt shutdown "$(local_domain)" >/dev/null
    log "$(local_domain) shutting down, its Proxmox stops the seats' containers and VMs first"
    deadline=$((SECONDS + LOCAL_STOP_TIMEOUT))
    until state="$(virt domstate "$(local_domain)")" && [[ "$state" == "shut off" ]]; do
      ((SECONDS < deadline)) ||
        die "$(local_domain) is still $state ${LOCAL_STOP_TIMEOUT}s after it was asked to shut down. Its console: virsh -c qemu:///system console $(local_domain), root password in $(local_dir)/root-password"
      sleep 5
    done
  fi
  log "$(local_domain) shut off, ./lab local up $HOST_NAME starts it again"
  if [[ -z "$(local_running_domains)" && "$(virt net-info "$LOCAL_NET" 2>/dev/null | awk '/^Active:/ {print $2}')" == yes ]]; then
    virt net-destroy "$LOCAL_NET" >/dev/null
    log "libvirt network $LOCAL_NET stopped, because no lab VM runs on it"
  fi
}

local_other_domains() {
  local domains
  domains="$(virt list --all --name)" || return 1
  grep -vxF "$(local_domain)" <<<"$domains" | grep . | sort || true
}

local_down() {
  local host="$1" before after volume leftovers=() remaining
  lab_load_config
  host_select "$host"
  before="$(local_other_domains)" || die "could not list the other libvirt domains"
  if virt dominfo "$(local_domain)" >/dev/null 2>&1; then
    [[ "$(virt domstate "$(local_domain)")" != running ]] || virt destroy "$(local_domain)" >/dev/null
    virt undefine "$(local_domain)" >/dev/null
    log "virtual machine $(local_domain) removed"
  fi
  if virt pool-info "$LOCAL_POOL" >/dev/null 2>&1; then
    for volume in "$HOST_NAME.qcow2" "seed-$HOST_NAME.iso"; do
      if virt vol-info --pool "$LOCAL_POOL" "$volume" >/dev/null 2>&1; then
        virt vol-delete --pool "$LOCAL_POOL" "$volume" >/dev/null
      fi
    done
  fi
  rm -f "$(local_dir)/ssh_host_ed25519_key" "$(local_dir)/ssh_host_ed25519_key.pub" "$(local_dir)/root-password" "$(local_dir)/domain.xml"
  rmdir "$(local_dir)" 2>/dev/null || true
  remaining="$(virt list --all --name | grep -E '^talos-lab-' || true)"
  if [[ -z "$remaining" ]]; then
    if virt pool-info "$LOCAL_POOL" >/dev/null 2>&1; then
      for volume in $(virt vol-list --pool "$LOCAL_POOL" | awk '{print $1}'); do
        virt vol-delete --pool "$LOCAL_POOL" "$volume" >/dev/null
      done
      [[ "$(virt pool-info "$LOCAL_POOL" | awk '/^State:/ {print $2}')" != running ]] || virt pool-destroy "$LOCAL_POOL" >/dev/null
      virt pool-delete "$LOCAL_POOL" >/dev/null
      virt pool-undefine "$LOCAL_POOL" >/dev/null
      log "libvirt pool $LOCAL_POOL removed"
    fi
    if virt net-info "$LOCAL_NET" >/dev/null 2>&1; then
      [[ "$(virt net-info "$LOCAL_NET" | awk '/^Active:/ {print $2}')" != yes ]] || virt net-destroy "$LOCAL_NET" >/dev/null
      virt net-undefine "$LOCAL_NET" >/dev/null
      log "libvirt network $LOCAL_NET removed"
    fi
    local_ufw delete
    sudo -n ufw status | grep -qF "$LOCAL_BRIDGE" && leftovers+=("ufw rules for $LOCAL_BRIDGE")
    virt pool-info "$LOCAL_POOL" >/dev/null 2>&1 && leftovers+=("pool $LOCAL_POOL")
    virt net-info "$LOCAL_NET" >/dev/null 2>&1 && leftovers+=("network $LOCAL_NET")
  fi
  virt dominfo "$(local_domain)" >/dev/null 2>&1 && leftovers+=("domain $(local_domain)")
  ((${#leftovers[@]} == 0)) || die "teardown of $(local_domain) left resources behind: ${leftovers[*]}"
  after="$(local_other_domains)" || die "could not list the other libvirt domains"
  [[ "$before" == "$after" ]] || die "other libvirt domains changed during teardown. Before: $before. After: $after"
  log "$(local_domain) removed, other libvirt domains unchanged. Its Cloudflare side goes with ./lab access down $HOST_NAME"
}
