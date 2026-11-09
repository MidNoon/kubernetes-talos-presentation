readonly MACHINE_MEMORY_MIB=(4096 3072 3072)
readonly MACHINE_CORES=(2 2 2)
readonly MACHINE_DISK_GIB=32
readonly MACHINE_MACS=(BC:24:11:1A:B5:01 BC:24:11:1A:B5:02 BC:24:11:1A:B5:03)
readonly MACHINE_ISO_NAME=talos-lab.iso
readonly MACHINE_EXTENSION=siderolabs/qemu-guest-agent
readonly CLUSTER_READY_TIMEOUT=1500
readonly LINK_STATE_TIMEOUT=420
readonly NODE_READY_TIMEOUT=420
readonly RECONNECT_WORKER_INDEX=2

lab_kubeconfig() {
  printf '%s/cluster/kubeconfig' "$LAB_STATE"
}

lab_kubectl() {
  KUBECONFIG="$(lab_kubeconfig)" kubectl --kubeconfig "$(lab_kubeconfig)" "$@"
}

omni_link_field() {
  local raw
  raw="$(omni_query get links -o json)" || return 1
  jq -s -r --arg id "$1" '.[] | select(.metadata.id == $id) | (.spec.connected // false) | tostring' <<<"$raw" 2>/dev/null || {
    fail "Omni link listing was not in the expected format"
    return 1
  }
}

machines_capture_failure() {
  local reason="$1" dir index raw
  dir="$LAB_STATE/failures/machines-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  if pve_load_target 2>/dev/null; then
    pve_api GET "/nodes/$PVE_NODE/qemu" >"$dir/proxmox-vms.json" 2>&1 || true
    for index in "${!LAB_VM_IDS[@]}"; do
      pve_api GET "/nodes/$PVE_NODE/qemu/${LAB_VM_IDS[index]}/config" >"$dir/vm-${LAB_VM_NAMES[index]}-config.json" 2>&1 || true
    done
  fi
  virsh -q -c qemu:///system net-dhcp-leases talos-lab >"$dir/dhcp-leases.txt" 2>&1 || true
  if raw="$(omni_query get links -o json 2>&1)"; then
    jq -s -c --args 'map(select(.metadata.id | IN($ARGS.positional[])) | {id:.metadata.id, connected:.spec.connected, endpoint:.spec.lastendpoint, remote:.spec.remoteaddr})' \
      "${LAB_MACHINE_IDS[@]}" <<<"$raw" >"$dir/lab-links.json" 2>&1 || true
  fi
  if raw="$(omni_query get machinestatus -o json 2>&1)"; then
    jq -s -c --args 'map(select(.metadata.id | IN($ARGS.positional[])))' \
      "${LAB_MACHINE_IDS[@]}" <<<"$raw" >"$dir/lab-machinestatus.json" 2>&1 || true
  fi
  omni_query get clusterstatus "$LAB_CLUSTER_NAME" -o json >"$dir/clusterstatus.json" 2>&1 || true
  if [[ -f "$LAB_STATE/watchdog-tripped" ]]; then
    cp "$LAB_STATE/watchdog-tripped" "$dir/"
  fi
  die "$reason. Context saved in $dir"
}

machines_require_clean() {
  local index state ids id
  ids="$(cap_live_link_ids)" || exit 1
  for id in "${LAB_MACHINE_IDS[@]}"; do
    if grep -qxF "$id" <<<"$ids"; then
      die "lab machine $id is already registered in Omni, run ./lab reset first"
    fi
  done
  for index in "${!LAB_VM_IDS[@]}"; do
    state="$(pve_lab_vm_state "${LAB_VM_IDS[index]}")" || exit 1
    [[ "$state" == absent ]] || die "lab VM ${LAB_VM_NAMES[index]} already exists and is $state, run ./lab reset first"
  done
}

machines_download_iso() {
  local dir="$LAB_STATE/machines/media" found=()
  rm -rf "$dir"
  mkdir -p "$dir"
  log "downloading install image from Omni"
  LAB_OMNI_TIMEOUT=1800 omni_query media download "$LAB_PRESET_NAME" --output "$dir/" >/dev/null || return 1
  while IFS= read -r -d '' file; do
    found+=("$file")
  done < <(find "$dir" -maxdepth 1 -type f -name '*.iso' -print0)
  if ((${#found[@]} != 1)); then
    fail "expected one ISO in $dir after download, found ${#found[@]}: $(ls -la "$dir")"
    return 1
  fi
  printf '%s\n' "${found[0]}"
}

machines_create_vm() {
  local index="$1" response
  response="$(pve_api POST "/nodes/$PVE_NODE/qemu" \
    --data-urlencode "vmid=${LAB_VM_IDS[index]}" \
    --data-urlencode "name=${LAB_VM_NAMES[index]}" \
    --data-urlencode "ostype=l26" \
    --data-urlencode "machine=q35" \
    --data-urlencode "bios=ovmf" \
    --data-urlencode "efidisk0=$PVE_DISK_STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
    --data-urlencode "cpu=host" \
    --data-urlencode "sockets=1" \
    --data-urlencode "cores=${MACHINE_CORES[index]}" \
    --data-urlencode "memory=${MACHINE_MEMORY_MIB[index]}" \
    --data-urlencode "balloon=0" \
    --data-urlencode "scsihw=virtio-scsi-pci" \
    --data-urlencode "scsi0=$PVE_DISK_STORAGE:$MACHINE_DISK_GIB,discard=on,cache=writethrough" \
    --data-urlencode "ide2=$PVE_ISO_STORAGE:iso/$MACHINE_ISO_NAME,media=cdrom" \
    --data-urlencode "net0=virtio=${MACHINE_MACS[index]},bridge=$PVE_BRIDGE" \
    --data-urlencode "boot=order=scsi0;ide2" \
    --data-urlencode "agent=enabled=1" \
    --data-urlencode "smbios1=uuid=${LAB_MACHINE_IDS[index]}" \
    --data-urlencode "onboot=0")" || return 1
  pve_wait_response "$response" 300
}

machines_up() {
  local token iso index
  lab_load_config
  pve_load_target || exit 1
  cap_gate || exit 1
  machines_require_clean

  cap_token_create || exit 1
  token="$(cap_token_id)" || exit 1
  local LAB_SCRUB="$token"
  cap_preset_delete || exit 1
  cap_preset_create "$token" "$LAB_TALOS_VERSION" "$MACHINE_EXTENSION" || exit 1

  iso="$(machines_download_iso)" || exit 1
  log "uploading $(du -h "$iso" | cut -f1) install image to Proxmox"
  pve_delete_iso "$MACHINE_ISO_NAME" || exit 1
  pve_upload_iso "$iso" "$MACHINE_ISO_NAME" || exit 1
  rm -f "$iso"

  for index in "${!LAB_VM_IDS[@]}"; do
    cap_gate || exit 1
    machines_create_vm "$index" || exit 1
    log "created ${LAB_VM_NAMES[index]} as VM ${LAB_VM_IDS[index]}"
  done

  cap_watchdog_start || exit 1
  cap_guarded_boot || machines_capture_failure "machines did not all register"
  cap_watchdog_stop
  log "all ${#LAB_MACHINE_IDS[@]} lab machines registered"
}

cluster_render_template() {
  local path id
  path="$(lab_cluster_template)"
  mkdir -p "$(dirname "$path")"
  {
    cat <<EOF
kind: Cluster
name: $LAB_CLUSTER_NAME
kubernetes:
  version: v$LAB_KUBERNETES_VERSION
talos:
  version: v$LAB_TALOS_VERSION
---
kind: ControlPlane
machines:
  - ${LAB_MACHINE_IDS[0]}
---
kind: Workers
machines:
  - ${LAB_MACHINE_IDS[1]}
  - ${LAB_MACHINE_IDS[2]}
EOF
    for id in "${LAB_MACHINE_IDS[@]}"; do
      printf -- '---\nkind: Machine\nname: %s\n' "$id"
    done
  } >"$path"
}

cluster_wait_ready() {
  local deadline=$((SECONDS + CLUSTER_READY_TIMEOUT)) raw summary="" current ready=false healthy=0 total=0 phase=
  while ((SECONDS < deadline)); do
    if cap_tripped; then
      machines_capture_failure "cap watchdog tripped during cluster creation: $(cat "$LAB_STATE/watchdog-tripped")"
    fi
    if raw="$(omni_query get clusterstatus "$LAB_CLUSTER_NAME" -o json 2>/dev/null)"; then
      phase="$(jq -r '.spec.phase // 0' <<<"$raw")"
      ready="$(jq -r '.spec.ready // false' <<<"$raw")"
      healthy="$(jq -r '.spec.machines.healthy // 0' <<<"$raw")"
      total="$(jq -r '.spec.machines.total // 0' <<<"$raw")"
      current="phase=$phase ready=$ready healthy=$healthy/$total"
      if [[ "$current" != "$summary" ]]; then
        log "cluster $LAB_CLUSTER_NAME: $current"
        summary="$current"
      fi
      if [[ "$ready" == true && "$healthy" == "${#LAB_MACHINE_IDS[@]}" && "$total" == "${#LAB_MACHINE_IDS[@]}" ]]; then
        return 0
      fi
    fi
    sleep 10
  done
  machines_capture_failure "cluster $LAB_CLUSTER_NAME not ready within ${CLUSTER_READY_TIMEOUT}s, last $summary"
}

cluster_fetch_kubeconfig() {
  local path
  path="$(lab_kubeconfig)"
  mkdir -p "$(dirname "$path")"
  rm -f "$path"
  omni_query kubeconfig "$path" --cluster "$LAB_CLUSTER_NAME" --service-account --user talos-lab-kit --ttl 24h --force --merge=false >/dev/null || exit 1
  [[ -s "$path" ]] || die "omnictl did not write a kubeconfig to $path"
}

cluster_wait_nodes_ready() {
  local deadline=$((SECONDS + NODE_READY_TIMEOUT)) raw ready=""
  while ((SECONDS < deadline)); do
    if raw="$(lab_kubectl get nodes -o json 2>/dev/null)"; then
      ready="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$raw")"
      if [[ "$ready" == "${#LAB_MACHINE_IDS[@]}" ]]; then
        return 0
      fi
    fi
    sleep 5
  done
  fail "only ${ready:-0} of ${#LAB_MACHINE_IDS[@]} nodes became Ready within ${NODE_READY_TIMEOUT}s"
}

cluster_up() {
  local index connected
  lab_load_config
  pve_load_target || exit 1
  cap_gate || exit 1
  for index in "${!LAB_MACHINE_IDS[@]}"; do
    connected="$(omni_link_field "${LAB_MACHINE_IDS[index]}")" || exit 1
    [[ "$connected" == true ]] || die "lab machine ${LAB_VM_NAMES[index]} is not connected to Omni, link state: ${connected:-absent}"
  done

  cluster_render_template
  omni_query cluster template validate -f "$(lab_cluster_template)" >/dev/null || exit 1
  cap_watchdog_start || exit 1
  log "applying cluster template for $LAB_CLUSTER_NAME"
  LAB_OMNI_TIMEOUT=300 omni_query cluster template sync -f "$(lab_cluster_template)" >/dev/null || machines_capture_failure "cluster template sync failed"
  cluster_wait_ready

  cap_token_revoke || machines_capture_failure "Omni refused a plain revoke of the lab join token, a machine may still depend on it"
  cap_preset_delete || exit 1
  cap_watchdog_stop

  cluster_fetch_kubeconfig
  cluster_wait_nodes_ready || machines_capture_failure "kubernetes nodes did not become Ready"
  log "cluster $LAB_CLUSTER_NAME is ready and the lab join token is revoked"
}

cluster_wait_link() {
  local machine_id="$1" wanted="$2" deadline=$((SECONDS + LINK_STATE_TIMEOUT)) state=""
  while ((SECONDS < deadline)); do
    state="$(omni_link_field "$machine_id")" || return 1
    if [[ "$state" == "$wanted" ]]; then
      return 0
    fi
    sleep 5
  done
  fail "link for $machine_id stayed at connected=${state:-absent}, wanted connected=$wanted after ${LINK_STATE_TIMEOUT}s"
}

cluster_prove_reconnect() {
  local vmid="${LAB_VM_IDS[RECONNECT_WORKER_INDEX]}" name="${LAB_VM_NAMES[RECONNECT_WORKER_INDEX]}" id="${LAB_MACHINE_IDS[RECONNECT_WORKER_INDEX]}"
  local active started
  lab_load_config
  pve_load_target || exit 1
  active="$(cap_token_ids true)" || exit 1
  [[ -z "$active" ]] || die "the lab join token is still active, the reconnect proof needs it revoked"

  log "hard stopping $name with the lab join token revoked"
  started=$SECONDS
  pve_stop_lab_vm "$vmid" || exit 1
  cluster_wait_link "$id" false || machines_capture_failure "Omni never saw $name disconnect"
  log "$name disconnected after $((SECONDS - started))s"

  cap_gate || exit 1
  log "starting $name"
  started=$SECONDS
  pve_start_lab_vm "$vmid" || exit 1
  cluster_wait_link "$id" true || machines_capture_failure "$name did not reconnect to Omni after restart"
  log "$name reconnected to Omni after $((SECONDS - started))s"
  cluster_wait_nodes_ready || machines_capture_failure "$name did not return to Ready in Kubernetes"
  log "reconnect proven: $name rejoined after a hard restart with the join token revoked, all nodes Ready after $((SECONDS - started))s"
}

lab_cluster_exists() {
  local raw
  raw="$(omni_query get clusters -o json)" || return 2
  jq -s -e --arg name "$LAB_CLUSTER_NAME" 'any(.[]; .metadata.id == $name)' <<<"$raw" >/dev/null
}

lab_wait_cluster_teardown_started() {
  local deadline=$((SECONDS + 120)) raw phase=""
  while ((SECONDS < deadline)); do
    if ! lab_cluster_exists_quiet; then
      return 0
    fi
    raw="$(omni_query get clusters "$LAB_CLUSTER_NAME" -o json 2>/dev/null)" || raw=""
    phase="$(jq -r '.metadata.phase // ""' <<<"$raw" 2>/dev/null)" || phase=""
    if [[ "$phase" == tearingDown ]]; then
      return 0
    fi
    sleep 2
  done
  fail "cluster $LAB_CLUSTER_NAME did not start tearing down within 120s, phase: ${phase:-unknown}"
}

lab_cluster_exists_quiet() {
  local status=0
  lab_cluster_exists || status=$?
  ((status != 1))
}

lab_delete_lab_links_workers_first() {
  local index ids
  ids="$(cap_live_link_ids)" || return 1
  for ((index = ${#LAB_MACHINE_IDS[@]} - 1; index >= 0; index--)); do
    if grep -qxF "${LAB_MACHINE_IDS[index]}" <<<"$ids"; then
      LAB_OMNI_TIMEOUT=600 omni_query delete link "${LAB_MACHINE_IDS[index]}" >/dev/null || return 1
      log "removed link ${LAB_MACHINE_IDS[index]}"
    fi
  done
}

lab_delete_cluster_and_links() {
  local deleter status=0
  log "deleting cluster $LAB_CLUSTER_NAME"
  LAB_OMNI_TIMEOUT=900 omni_query cluster delete "$LAB_CLUSTER_NAME" >/dev/null &
  deleter=$!
  lab_wait_cluster_teardown_started || status=1
  if ((status == 0)); then
    lab_delete_lab_links_workers_first || status=1
  fi
  wait "$deleter" || status=1
  if ((status != 0)); then
    machines_capture_failure "cluster $LAB_CLUSTER_NAME and its machines could not be removed"
  fi
}

lab_reset() {
  local before after id index state status=0 leftovers=() ids
  lab_load_config
  pve_load_target || exit 1
  before="$(cap_protected_machine_ids | sort)"
  if [[ -n "${LAB_OMNI_PROTECTED_CLUSTER:-}" && -z "$before" ]]; then
    die "could not read protected cluster $LAB_OMNI_PROTECTED_CLUSTER, refusing to tear down without a baseline"
  fi
  for index in "${!LAB_VM_IDS[@]}"; do
    pve_lab_vm_state "${LAB_VM_IDS[index]}" >/dev/null || exit 1
  done

  cf_load_config

  log "stopping lab VMs"
  pve_stop_lab_vms || exit 1
  tunnel_down
  ids="$(cap_live_link_ids)" || exit 1
  for id in "${LAB_MACHINE_IDS[@]}"; do
    if grep -qxF "$id" <<<"$ids"; then
      cluster_wait_link "$id" false || exit 1
    fi
  done

  lab_cluster_exists || status=$?
  case "$status" in
    0)
      lab_delete_cluster_and_links
      ;;
    1)
      lab_delete_lab_links_workers_first || exit 1
      ;;
    *) exit 1 ;;
  esac

  for index in "${!LAB_VM_IDS[@]}"; do
    pve_delete_lab_vm "${LAB_VM_IDS[index]}" || exit 1
  done
  pve_delete_iso "$MACHINE_ISO_NAME" || exit 1
  cap_preset_delete || exit 1
  cap_token_delete || exit 1
  rm -rf "$LAB_STATE/machines" "$LAB_STATE/cluster"

  status=0
  lab_cluster_exists || status=$?
  ((status == 1)) || leftovers+=("cluster $LAB_CLUSTER_NAME")
  ids="$(cap_live_link_ids)" || exit 1
  for id in "${LAB_MACHINE_IDS[@]}"; do
    if grep -qxF "$id" <<<"$ids"; then
      leftovers+=("link $id")
    fi
  done
  for index in "${!LAB_VM_IDS[@]}"; do
    state="$(pve_lab_vm_state "${LAB_VM_IDS[index]}")" || exit 1
    [[ "$state" == absent ]] || leftovers+=("vm ${LAB_VM_NAMES[index]}")
  done
  [[ -z "$(cap_token_ids)" ]] || leftovers+=("join token $LAB_JOIN_TOKEN_NAME")
  if cap_preset_exists; then
    leftovers+=("media preset $LAB_PRESET_NAME")
  fi
  ((${#leftovers[@]} == 0)) || die "reset left resources behind: ${leftovers[*]}"

  after="$(cap_protected_machine_ids | sort)"
  [[ "$before" == "$after" ]] || die "protected cluster membership changed during reset. Before: $before. After: $after"
  log "reset complete: only lab resources removed, $LAB_OMNI_PROTECTED_CLUSTER membership unchanged at $(grep -c . <<<"$after") machines"
}
