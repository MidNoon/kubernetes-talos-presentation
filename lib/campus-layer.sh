readonly CAMPUS_UNIT=talos-campus
readonly CAMPUS_TABLE=talos_campus
readonly CAMPUS_RULES=/etc/talos-campus.nft
readonly CAMPUS_OPEN=/etc/talos-campus.open
readonly CAMPUS_REVERT_SECONDS=120
readonly CAMPUS_SERVICES=(ssh proxmox)

campus_ports() {
  case "$1" in
    ssh) printf '22' ;;
    proxmox) printf '8006, 3128' ;;
    *) return 1 ;;
  esac
}

campus_render_rules() {
  local uplink="$1" service ports=""
  shift
  for service in "$@"; do
    ports+="${ports:+, }$(campus_ports "$service")"
  done
  printf 'table inet %s\ndelete table inet %s\n\ntable inet %s {\n' "$CAMPUS_TABLE" "$CAMPUS_TABLE" "$CAMPUS_TABLE"
  printf '  chain input {\n    type filter hook input priority filter - 20; policy accept;\n'
  printf '    iifname != "%s" accept\n' "$uplink"
  printf '    ct state established,related accept\n'
  printf '    meta l4proto { icmp, ipv6-icmp } accept\n'
  printf '    udp dport 68 accept\n'
  [[ -z "$ports" ]] || printf '    tcp dport { %s } accept\n' "$ports"
  printf '    drop\n  }\n}\n'
}

campus_render_unit() {
  cat <<EOF
[Unit]
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $CAMPUS_RULES
ExecStop=/usr/sbin/nft delete table inet $CAMPUS_TABLE

[Install]
WantedBy=sysinit.target
EOF
}

campus_load() {
  host_load_config
  [[ -n "${PVE_SSH_ACCESS:-}" ]] ||
    die "campus rules need a target reached through Cloudflare Access, because closing the campus side could cut off $PVE_SSH"
}

campus_state() {
  pve_ssh "if nft list table inet $CAMPUS_TABLE >/dev/null 2>&1; then echo rules; sed 's/^/open /' $CAMPUS_OPEN 2>/dev/null; else echo none; fi
ip -4 route show default | awk '{print \"uplink \" \$5; exit}'
ip -4 -o route get 1.1.1.1 | grep -oE 'src [0-9.]+' | sed 's/^src /address /'"
}

campus_open_services() {
  local state="$1"
  if grep -qx rules <<<"$state"; then
    sed -n 's/^open //p' <<<"$state"
  else
    printf '%s\n' "${CAMPUS_SERVICES[@]}"
  fi
}

campus_show() {
  local state uplink address open
  state="$(campus_state)" || die "could not read the campus rules on $PVE_SSH"
  uplink="$(sed -n 's/^uplink //p' <<<"$state")"
  address="$(sed -n 's/^address //p' <<<"$state")"
  if grep -qx rules <<<"$state"; then
    open="$(sed -n 's/^open //p' <<<"$state" | paste -sd' ')"
    log "campus side of $PVE_NODE ($uplink, $address): closed to new connections, open: ${open:-none}. Replies, DHCP and ping pass"
  else
    log "campus side of $PVE_NODE ($uplink, $address): no campus rules, every service listening there is reachable"
  fi
}

campus_apply() {
  local uplink
  uplink="$(pve_ssh "ip -4 route show default" | awk '{print $5; exit}')"
  [[ -n "$uplink" ]] || die "the host has no default route, so its campus interface is unknown"
  campus_render_rules "$uplink" "$@" | host_install_file 600 "$CAMPUS_RULES"
  { (($# == 0)) || printf '%s\n' "$@"; } | host_install_file 600 "$CAMPUS_OPEN"
  campus_render_unit | host_install_file 644 "/etc/systemd/system/$CAMPUS_UNIT.service"
  pve_ssh "set -e
nft -c -f $CAMPUS_RULES
systemctl stop $CAMPUS_UNIT-revert.timer >/dev/null 2>&1 || true
systemd-run --quiet --unit $CAMPUS_UNIT-revert --on-active=$CAMPUS_REVERT_SECONDS /bin/sh -c 'systemctl disable --now $CAMPUS_UNIT; nft delete table inet $CAMPUS_TABLE'
systemctl daemon-reload
systemctl enable --quiet $CAMPUS_UNIT
systemctl restart $CAMPUS_UNIT" || die "could not load the campus rules on $PVE_SSH"
  pve_ssh true ||
    die "a new connection through Cloudflare Access failed after the campus rules changed. The host removes them within ${CAMPUS_REVERT_SECONDS}s"
  pve_ssh "systemctl stop $CAMPUS_UNIT-revert.timer" || die "could not cancel the campus rules' automatic removal on $PVE_SSH"
  campus_show
}

campus_set() {
  local service="$1" wanted="$2" state current open=() name
  campus_ports "$service" >/dev/null || die "unknown campus service $service, expected one of: ${CAMPUS_SERVICES[*]}"
  [[ "$wanted" == open || "$wanted" == close ]] || die "expected open or close, got $wanted"
  campus_load
  state="$(campus_state)" || die "could not read the campus rules on $PVE_SSH"
  current="$(campus_open_services "$state")"
  for name in "${CAMPUS_SERVICES[@]}"; do
    if [[ "$name" == "$service" ]]; then
      [[ "$wanted" == close ]] || open+=("$name")
    elif grep -qxF "$name" <<<"$current"; then
      open+=("$name")
    fi
  done
  campus_apply "${open[@]}"
}

campus_close() {
  campus_load
  campus_apply
}

campus_reset() {
  campus_load
  pve_ssh "systemctl disable --now $CAMPUS_UNIT >/dev/null 2>&1 || true
nft delete table inet $CAMPUS_TABLE >/dev/null 2>&1 || true
rm -f /etc/systemd/system/$CAMPUS_UNIT.service $CAMPUS_RULES $CAMPUS_OPEN
systemctl daemon-reload" || die "could not remove the campus rules on $PVE_SSH"
  campus_show
}

campus_status() {
  campus_load
  campus_show
}
