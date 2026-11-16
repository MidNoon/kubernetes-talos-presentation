#!/usr/bin/env bash
set -uo pipefail

TARGETS=(
  1.1.1.1:443
  factory.talos.dev:443
  discovery.talos.dev:443
  ghcr.io:443
  registry.k8s.io:443
  registry-1.docker.io:443
  api.cloudflare.com:443
  download.proxmox.com:80
  deb.debian.org:80
  region1.v2.argotunnel.com:7844
  region2.v2.argotunnel.com:7844
)

report() {
  printf '%-5s %-34s %s\n' "$1" "$2" "$3"
}

check_host() {
  printf 'host %s, kernel %s, %s cpus, %s MiB memory\n' "$(hostname)" "$(uname -r)" "$(nproc)" "$(awk '/MemTotal/ {print int($2 / 1024)}' /proc/meminfo)"
  if command -v pveversion >/dev/null; then
    pveversion
  fi
}

check_virt() {
  local flags
  flags="$(grep -cE '^flags\s*:.*\b(vmx|svm)\b' /proc/cpuinfo)"
  if ((flags > 0)); then
    report PASS "cpu virtualization flag" "$flags cpus"
  else
    report FAIL "cpu virtualization flag" "no vmx or svm, VMs on this host run without KVM"
  fi
  if [[ -c /dev/kvm ]]; then
    report PASS "/dev/kvm" "present"
  else
    report FAIL "/dev/kvm" "missing"
  fi
}

check_network() {
  local route gateway nameservers
  route="$(ip -4 route show default)"
  nameservers="$(awk '/^nameserver/ {print $2}' /etc/resolv.conf | paste -sd ' ')"
  report INFO "nameservers" "${nameservers:-none}"
  if [[ -z "$route" ]]; then
    report FAIL "default route" "none"
    return
  fi
  report INFO "default route" "$route"
  gateway="$(awk '{print $3}' <<<"$route")"
  if ping -c 1 -W 2 "$gateway" >/dev/null 2>&1; then
    report PASS "gateway $gateway" "answers ping"
  else
    report FAIL "gateway $gateway" "no ping reply, neighbor $(ip neigh show "$gateway" | awk '{print $NF}')"
  fi
}

check_target() {
  local host="${1%:*}" port="${1##*:}" addr code
  if [[ "$host" =~ ^[0-9.]+$ ]]; then
    addr="$host"
  else
    addr="$(timeout 8 getent ahostsv4 "$host" | awk 'NR == 1 {print $1}')"
    if [[ -z "$addr" ]]; then
      report FAIL "$1" "dns lookup failed"
      return
    fi
  fi
  if ! timeout 5 bash -c "exec 3<>/dev/tcp/$addr/$port" 2>/dev/null; then
    report FAIL "$1" "tcp connect to $addr failed"
    return
  fi
  if [[ "$port" == 443 && "$host" != "$addr" ]] && command -v curl >/dev/null; then
    code="$(curl -sS -o /dev/null -m 10 -w '%{http_code}' "https://$host/" 2>&1)"
    report PASS "$1" "tcp to $addr, https status $code"
  else
    report PASS "$1" "tcp to $addr"
  fi
}

check_host
check_virt
check_network
for target in "${TARGETS[@]}" "$@"; do
  check_target "$target"
done
