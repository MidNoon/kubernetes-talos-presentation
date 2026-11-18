readonly INSTALL_REMOTE=/root/talos-proxmox-install.sh
readonly INSTALL_STATE=/var/lib/talos-proxmox-install
readonly INSTALL_STEP_TIMEOUT=2700
readonly INSTALL_BOOT_TIMEOUT=900

install_upload() {
  pve_ssh "cat >$INSTALL_REMOTE && chmod 700 $INSTALL_REMOTE" <"$LAB_ROOT/tools/proxmox-install.sh" ||
    die "could not copy the install script to $HOST_NAME"
}

install_status() {
  pve_ssh "bash $INSTALL_REMOTE status" || die "could not read the install status of $HOST_NAME"
}

install_value() {
  sed -n "s/^$1=//p" <<<"$2" | cut -d' ' -f1
}

install_step() {
  local step="$1" deadline=$((SECONDS + INSTALL_STEP_TIMEOUT)) result="" output
  log "$HOST_NAME: $step step started"
  pve_ssh "rm -f $INSTALL_STATE/$step.result; systemctl reset-failed talos-proxmox-$step >/dev/null 2>&1; systemd-run --quiet --unit talos-proxmox-$step --collect --property=Type=oneshot --property=KillMode=process --no-block bash $INSTALL_REMOTE $step" ||
    die "could not start the $step step on $HOST_NAME"
  until result="$(pve_ssh "cat $INSTALL_STATE/$step.result 2>/dev/null" 2>/dev/null)" && [[ -n "$result" ]]; do
    ((SECONDS < deadline)) || die "the $step step on $HOST_NAME did not finish within ${INSTALL_STEP_TIMEOUT}s"
    sleep 10
  done
  output="$(pve_ssh "journalctl --no-pager --output=cat --unit talos-proxmox-$step --since -$((INSTALL_STEP_TIMEOUT / 60))min | grep -vE '^(Selecting|Preparing|Unpacking|Setting up|Processing|\\(Reading)' | tail -20" 2>&1 || true)"
  [[ "$result" == 0 ]] || die "the $step step on $HOST_NAME failed with exit $result: $output"
  log "$HOST_NAME: $step step done"
}

install_reboot() {
  local before after="" deadline=$((SECONDS + INSTALL_BOOT_TIMEOUT))
  before="$(pve_ssh 'cat /proc/sys/kernel/random/boot_id')" || die "could not read the boot ID of $HOST_NAME"
  pve_ssh "systemd-run --quiet --on-active=3 systemctl reboot" || die "could not reboot $HOST_NAME"
  log "$HOST_NAME rebooting"
  sleep 20
  until after="$(pve_ssh 'cat /proc/sys/kernel/random/boot_id' 2>/dev/null)" && [[ -n "$after" && "$after" != "$before" ]]; do
    ((SECONDS < deadline)) || die "$HOST_NAME did not come back within ${INSTALL_BOOT_TIMEOUT}s of rebooting. Look at its console"
    sleep 10
  done
  log "$HOST_NAME is back"
}

install_verify() {
  local checks address
  address="$(pve_ssh "ip -4 -o route get 1.1.1.1" | grep -oE 'src [0-9.]+' | cut -d' ' -f2)" || die "$HOST_NAME has no default route"
  checks="$(pve_ssh 'printf "version=%s\nservices=%s\nresolves=%s\nkvm=%s\n" "$(pveversion)" "$(systemctl is-active pve-cluster pvedaemon pveproxy | paste -sd,)" "$(hostname --ip-address)" "$([ -c /dev/kvm ] && echo yes || echo no)"')" ||
    die "could not check Proxmox on $HOST_NAME"
  [[ "$(sed -n 's/^services=//p' <<<"$checks")" == active,active,active ]] || die "Proxmox services on $HOST_NAME are not all running: $checks"
  [[ " $(sed -n 's/^resolves=//p' <<<"$checks") " == *" $address "* ]] || die "$HOST_NAME does not resolve to its address $address: $checks"
  [[ "$(sed -n 's/^kvm=//p' <<<"$checks")" == yes ]] ||
    die "Proxmox is installed on $HOST_NAME, but it has no /dev/kvm, so nested virtualization is off. Its hypervisor must expose the CPU's virtualization extensions"
  log "$HOST_NAME runs $(sed -n 's/^version=//p' <<<"$checks") at $address with KVM. Next: ./lab access target $HOST_NAME"
}

host_install() {
  local state
  access_load_config "$1"
  access_use_target || exit 1
  pve_ssh true || die "cannot reach $HOST_NAME through $(cf_access_hostname), run ./lab access verify $HOST_NAME first"
  install_upload
  state="$(install_status)"
  [[ "$(install_value debian "$state")" == trixie ]] || die "$HOST_NAME runs Debian $(install_value debian "$state"), the install needs Debian 13 (trixie)"
  if [[ "$(install_value kernel "$state")" != pve ]]; then
    install_step kernel
    install_reboot
    state="$(install_status)"
    [[ "$(install_value kernel "$state")" == pve ]] || die "$HOST_NAME booted without the Proxmox kernel. Look at its boot menu"
  fi
  if [[ "$(install_value proxmox "$state")" != yes ]]; then
    install_step packages
    state="$(install_status)"
  fi
  if [[ "$(install_value network "$state")" != ifupdown2 ]]; then
    install_step network
    state="$(install_status)"
    [[ "$(install_value network "$state")" == ifupdown2 && "$(install_value revert_armed "$state")" == yes ]] ||
      die "the network handover on $HOST_NAME did not hold, and it reverts within 5 minutes: $(paste -sd' ' <<<"$state")"
    install_step confirm
    install_reboot
    state="$(install_status)"
    [[ "$(install_value network "$state")" == ifupdown2 && "$(install_value dhclient "$state")" == yes ]] ||
      die "after rebooting, $HOST_NAME's network is $(install_value network "$state") with dhclient $(install_value dhclient "$state"). Its boot fallback restores the old network 3 minutes after boot"
  fi
  install_step finalize
  install_verify
}
