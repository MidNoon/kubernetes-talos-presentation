#!/usr/bin/env bash
set -euo pipefail

KEYRING_URL=https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
KEYRING_SHA256=136673be77aba35dcce385b28737689ad64fd785a797e57897589aed08db6e45
KEYRING=/usr/share/keyrings/proxmox-archive-keyring.gpg
REPO=/etc/apt/sources.list.d/pve-install-repo.sources
STATE=/var/lib/talos-proxmox-install
FALLBACK_UNIT=talos-proxmox-net-fallback
REVERT_UNIT=talos-proxmox-net-revert
REVERT_SECONDS=300
export DEBIAN_FRONTEND=noninteractive

manager_units() {
  case "$1" in
    NetworkManager) echo NetworkManager.service NetworkManager-wait-online.service ;;
    systemd-networkd) echo systemd-networkd.socket systemd-networkd.service systemd-networkd-wait-online.service ;;
  esac
}

disable_dhclient_profile() {
  local profile
  for profile in /etc/apparmor.d/sbin.dhclient /etc/apparmor.d/usr.sbin.dhclient; do
    [[ -e "$profile" ]] || continue
    ln -sf "$profile" "/etc/apparmor.d/disable/${profile##*/}"
    apparmor_parser -R "$profile" 2>/dev/null || true
  done
}

uplink() {
  ip -4 route show default | awk '{print $5; exit}'
}

address() {
  ip -4 -o route get 1.1.1.1 | grep -oE 'src [0-9.]+' | cut -d' ' -f2
}

uplink_on_ifupdown() {
  local nic
  nic="$(uplink)"
  systemctl is-active --quiet NetworkManager && return 1
  systemctl is-active --quiet systemd-networkd && return 1
  grep -qE "^iface $nic inet static" /etc/network/interfaces 2>/dev/null && return 0
  grep -qE "^iface $nic inet dhcp" /etc/network/interfaces 2>/dev/null && pgrep -f "dhclient.* $nic\$" >/dev/null
}

previous_manager() {
  if systemctl is-active --quiet NetworkManager; then
    echo NetworkManager
  elif systemctl is-active --quiet systemd-networkd; then
    echo systemd-networkd
  else
    echo ifupdown
  fi
}

status() {
  printf 'debian=%s\n' "$(. /etc/os-release && printf %s "$VERSION_CODENAME")"
  printf 'kernel=%s\n' "$([[ "$(uname -r)" == *-pve ]] && echo pve || echo debian)"
  printf 'pve_kernel=%s\n' "$(dpkg-query -W -f '${Status}' proxmox-default-kernel 2>/dev/null | grep -q 'install ok installed' && echo yes || echo no)"
  printf 'proxmox=%s\n' "$(dpkg-query -W -f '${Status}' proxmox-ve 2>/dev/null | grep -q 'install ok installed' && echo yes || echo no)"
  if uplink_on_ifupdown; then
    printf 'network=ifupdown2\n'
  else
    printf 'network=%s\n' "$(previous_manager)"
  fi
  printf 'revert_armed=%s\n' "$(systemctl is-active --quiet "$REVERT_UNIT.timer" && echo yes || echo no)"
  printf 'dhclient=%s\n' "$(pgrep -x dhclient >/dev/null && echo yes || echo no)"
  printf 'uplink=%s address=%s\n' "$(uplink)" "$(address)"
}

hosts_entry() {
  local host ip
  host="$(hostname)"
  ip="$(address)"
  [[ -n "$ip" ]] || { echo "no default route, so no address for $host" >&2; return 1; }
  cp -n /etc/hosts "$STATE/hosts.before"
  sed -i "/^127\.0\.1\.1[[:space:]]/d" /etc/hosts
  if ! awk -v name="$host" '$1 !~ /^(#|127\.|::1)/ { for (i = 2; i <= NF; i++) if ($i == name) found = 1 } END { exit !found }' /etc/hosts; then
    sed -i "/^127\.0\.0\.1[[:space:]]/a $ip\t$host.internal $host" /etc/hosts
  fi
  [[ " $(hostname --ip-address) " == *" $ip "* ]] || { echo "$host does not resolve to $ip after editing /etc/hosts" >&2; return 1; }
}

boot_disk() {
  local disk
  [[ ! -d /sys/firmware/efi ]] || return 0
  disk="/dev/$(lsblk -no pkname "$(findmnt -no source /)" | head -1)"
  [[ -b "$disk" ]] || { echo "could not find the disk that holds /" >&2; return 1; }
  printf 'grub-pc grub-pc/install_devices multiselect %s\n' "$disk" | debconf-set-selections
}

step_kernel() {
  [[ "$(. /etc/os-release && printf %s "$VERSION_CODENAME")" == trixie ]] || { echo "this is not Debian 13" >&2; return 1; }
  [[ "$(dpkg --print-architecture)" == amd64 ]] || { echo "this is not amd64" >&2; return 1; }
  if [[ -d /etc/cloud/cloud.cfg.d ]]; then
    printf 'manage_etc_hosts: false\nnetwork:\n  config: disabled\n' >/etc/cloud/cloud.cfg.d/99-talos-proxmox.cfg
  fi
  hosts_entry
  boot_disk
  dpkg --configure -a </dev/null
  printf 'Types: deb\nURIs: http://download.proxmox.com/debian/pve\nSuites: trixie\nComponents: pve-no-subscription\nSigned-By: %s\n' "$KEYRING" >"$REPO"
  curl -fsSL -o "$KEYRING.part" "$KEYRING_URL"
  printf '%s  %s\n' "$KEYRING_SHA256" "$KEYRING.part" | sha256sum --check --quiet
  mv "$KEYRING.part" "$KEYRING"
  apt-get update -qq </dev/null
  apt-get full-upgrade -y -qq </dev/null
  apt-get install -y -qq proxmox-default-kernel </dev/null
}

step_packages() {
  local source old=()
  [[ "$(uname -r)" == *-pve ]] || { echo "boot the Proxmox kernel first, running $(uname -r)" >&2; return 1; }
  debconf-set-selections <<EOF
postfix postfix/main_mailer_type select Local only
postfix postfix/mailname string $(hostname).internal
EOF
  apt-get install -y -qq proxmox-ve postfix open-iscsi chrony isc-dhcp-client </dev/null
  for source in /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources; do
    if [[ -f "$source" ]] && ! grep -qx 'Enabled: no' "$source"; then
      printf 'Enabled: no\n' >>"$source"
    fi
  done
  mapfile -t old < <(dpkg-query -W -f '${Package} ${Status}\n' 'linux-image-*' 2>/dev/null | awk '$4 == "installed" && $1 !~ /pve/ {print $1}')
  if ((${#old[@]} > 0)); then
    apt-get remove -y -qq "${old[@]}" </dev/null
  fi
  update-grub
  if dpkg-query -W -f '${Status}' os-prober 2>/dev/null | grep -q 'install ok installed'; then
    apt-get remove -y -qq os-prober </dev/null
  fi
}

step_network() {
  local nic manager units=()
  nic="$(uplink)"
  [[ -n "$nic" ]] || { echo "no default route, so the uplink is unknown" >&2; return 1; }
  if uplink_on_ifupdown; then
    echo "$nic is already managed by ifupdown2"
    return 0
  fi
  manager="$(previous_manager)"
  cp -n /etc/network/interfaces "$STATE/interfaces.before"
  printf '%s\n' "$manager" >"$STATE/manager"
  cat >"$STATE/revert.sh" <<EOF
#!/bin/sh
pkill -x dhclient || true
cp $STATE/interfaces.before /etc/network/interfaces
ip link set $nic up
if [ "$manager" != ifupdown ]; then
  systemctl unmask $(manager_units "$manager")
  systemctl enable $manager
  systemctl restart $manager
else
  ifreload -a
fi
if [ -e $STATE/resolved ]; then
  systemctl unmask systemd-resolved
  systemctl enable --now systemd-resolved
  ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
fi
EOF
  chmod 700 "$STATE/revert.sh"
  cat >"$STATE/fallback.sh" <<EOF
#!/bin/sh
sleep 180
ip -4 route show default | grep -q . && exit 0
$STATE/revert.sh
EOF
  chmod 700 "$STATE/fallback.sh"
  printf '[Unit]\nAfter=network.target\n\n[Service]\nType=simple\nExecStart=%s/fallback.sh\n\n[Install]\nWantedBy=multi-user.target\n' "$STATE" >"/etc/systemd/system/$FALLBACK_UNIT.service"
  systemctl daemon-reload
  systemctl enable --quiet "$FALLBACK_UNIT"
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
  systemd-run --quiet --unit "$REVERT_UNIT" --on-active="$REVERT_SECONDS" "$STATE/revert.sh"
  if systemctl is-active --quiet systemd-resolved; then
    touch "$STATE/resolved"
    cp --remove-destination /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl disable --now systemd-resolved
  fi
  printf 'auto lo\niface lo inet loopback\n\nauto %s\niface %s inet dhcp\n\nsource /etc/network/interfaces.d/*\n' "$nic" "$nic" >/etc/network/interfaces
  rm -f /etc/network/interfaces.new
  install -d -m 755 /run/network
  disable_dhclient_profile
  if [[ "$manager" != ifupdown ]]; then
    systemctl disable --quiet "$manager" >/dev/null 2>&1 || true
    read -ra units <<<"$(manager_units "$manager")"
    systemctl mask --now --quiet "${units[@]}"
  fi
  ifreload -a || true
  sleep 5
  pgrep -x dhclient >/dev/null || ifup --force "$nic" || true
  sleep 3
  pgrep -x dhclient >/dev/null || { echo "dhclient is not running on $nic" >&2; return 1; }
  ip -4 route show default | grep -q . || { echo "no default route after the handover" >&2; return 1; }
}

step_confirm() {
  systemctl stop "$REVERT_UNIT.timer" >/dev/null 2>&1 || true
}

step_finalize() {
  local manager units=()
  uplink_on_ifupdown || { echo "the uplink is not managed by ifupdown2" >&2; return 1; }
  pgrep -x dhclient >/dev/null || { echo "dhclient is not running" >&2; return 1; }
  [[ ! -e /etc/network/interfaces.new ]] || { echo "a pending /etc/network/interfaces.new would replace the network on the next boot" >&2; return 1; }
  manager="$(cat "$STATE/manager" 2>/dev/null || echo ifupdown)"
  if [[ "$manager" != ifupdown ]]; then
    read -ra units <<<"$(manager_units "$manager")"
    systemctl mask --quiet "${units[@]}"
  fi
  [[ ! -e "$STATE/resolved" ]] || systemctl mask --quiet systemd-resolved
  systemctl disable --quiet "$FALLBACK_UNIT" 2>/dev/null || true
  rm -f "/etc/systemd/system/$FALLBACK_UNIT.service" "$STATE/fallback.sh" "$STATE/revert.sh"
  systemctl daemon-reload
}

main() {
  STEP="${1:-}"
  case "$STEP" in
    status)
      status
      return 0
      ;;
    kernel | packages | network | confirm | finalize) ;;
    *)
      echo "usage: $0 status|kernel|packages|network|confirm|finalize" >&2
      return 2
      ;;
  esac
  install -d -m 700 "$STATE"
  rm -f "$STATE/$STEP.result"
  trap 'printf "%s\n" "$?" >"$STATE/$STEP.result"' EXIT
  "step_$STEP"
}

main "$@"
