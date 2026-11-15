readonly REHEARSAL_LINK_TIMEOUT=420
readonly REHEARSAL_CLUSTER_TIMEOUT=1500
readonly REHEARSAL_NODE_TIMEOUT=420
readonly REHEARSAL_DELETE_TIMEOUT=900

lab_kubeconfig() {
  printf '%s/kubeconfig' "$SEAT_STATE"
}

lab_kubectl() {
  KUBECONFIG="$(lab_kubeconfig)" kubectl --kubeconfig "$(lab_kubeconfig)" "$@"
}

rehearsal_load() {
  host_load_config
  seat_use "$1"
  [[ -s "$SEAT_STATE/omni-service-account.key" ]] || die "$SEAT_NAME does not exist, run ./lab seats create first"
}

rehearsal_capture_failure() {
  local reason="$1" dir index
  dir="$LAB_STATE/failures/$SEAT_NAME-rehearsal-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  for index in "${!SEAT_VM_IDS[@]}"; do
    pve_api GET "/nodes/$PVE_NODE/qemu/${SEAT_VM_IDS[index]}/config" >"$dir/vm-${SEAT_VM_NAMES[index]}-config.json" 2>&1 || true
  done
  seat_omnictl get links -o json >"$dir/links.json" 2>&1 || true
  seat_omnictl get machinestatus -o json >"$dir/machinestatus.json" 2>&1 || true
  seat_omnictl get clusterstatus "$SEAT_CLUSTER" -o json >"$dir/clusterstatus.json" 2>&1 || true
  pve_ssh "cat /var/lib/misc/dnsmasq.$HOST_SDN_ZONE.leases 2>/dev/null; ls /var/lib/misc/" >"$dir/dhcp.txt" 2>&1 || true
  if [[ -s "$(lab_kubeconfig)" ]]; then
    lab_kubectl get nodes -o wide >"$dir/nodes.txt" 2>&1 || true
    lab_kubectl get pods -A -o wide >"$dir/pods.txt" 2>&1 || true
    lab_kubectl get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
  fi
  die "$reason. Context saved in $dir"
}

rehearsal_link_connected() {
  local raw
  raw="$(seat_omnictl get links -o json)" || return 1
  jq -s -r --arg id "$1" '.[] | select(.metadata.id == $id) | if .spec.connected == true then "true" else "false" end' <<<"$raw"
}

rehearsal_wait_link() {
  local id="$1" wanted="$2" deadline=$((SECONDS + REHEARSAL_LINK_TIMEOUT)) state=""
  while ((SECONDS < deadline)); do
    state="$(rehearsal_link_connected "$id")" || return 1
    [[ "$state" == "$wanted" ]] && return 0
    sleep 5
  done
  fail "link for $id stayed at connected=${state:-absent}, wanted connected=$wanted after ${REHEARSAL_LINK_TIMEOUT}s"
}

rehearsal_create_vm() {
  local index="$1" response
  response="$(pve_api POST "/nodes/$PVE_NODE/qemu" \
    --data-urlencode "vmid=${SEAT_VM_IDS[index]}" \
    --data-urlencode "name=${SEAT_VM_NAMES[index]}" \
    --data-urlencode "pool=$SEAT_NAME" \
    --data-urlencode "ostype=l26" \
    --data-urlencode "machine=q35" \
    --data-urlencode "bios=ovmf" \
    --data-urlencode "efidisk0=$PVE_DISK_STORAGE:1,efitype=4m,pre-enrolled-keys=0" \
    --data-urlencode "cpu=host" \
    --data-urlencode "sockets=1" \
    --data-urlencode "cores=${SEAT_VM_CORES[index]}" \
    --data-urlencode "memory=${SEAT_VM_MEMORY_MIB[index]}" \
    --data-urlencode "balloon=0" \
    --data-urlencode "scsihw=virtio-scsi-pci" \
    --data-urlencode "scsi0=$PVE_DISK_STORAGE:$SEAT_VM_DISK_GIB,discard=on,cache=writethrough" \
    --data-urlencode "ide2=$PVE_ISO_STORAGE:iso/$SEAT_ISO,media=cdrom" \
    --data-urlencode "net0=virtio=$(seat_vm_mac "$index"),bridge=$SEAT_VNET" \
    --data-urlencode "boot=order=scsi0;ide2" \
    --data-urlencode "agent=enabled=1" \
    --data-urlencode "smbios1=uuid=${SEAT_MACHINE_IDS[index]}" \
    --data-urlencode "onboot=0")" || return 1
  pve_wait_response "$response" 300
}

rehearsal_machines() {
  local index state
  for index in "${!SEAT_VM_IDS[@]}"; do
    state="$(pve_vm_state "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}")" || exit 1
    [[ "$state" == absent ]] || die "${SEAT_VM_NAMES[index]} already exists and is $state, run ./lab seat $SEAT reset first"
  done
  for index in "${!SEAT_VM_IDS[@]}"; do
    rehearsal_create_vm "$index" || exit 1
    log "created ${SEAT_VM_NAMES[index]} as VM ${SEAT_VM_IDS[index]} in pool $SEAT_NAME on $SEAT_VNET"
  done
  for index in "${!SEAT_VM_IDS[@]}"; do
    pve_start_vm "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}" || exit 1
    rehearsal_wait_link "${SEAT_MACHINE_IDS[index]}" true || rehearsal_capture_failure "${SEAT_VM_NAMES[index]} did not register with the $SEAT_NAME Omni"
    log "${SEAT_VM_NAMES[index]} registered with the $SEAT_NAME Omni"
  done
}

rehearsal_render_template() {
  local id
  cat <<EOF
kind: Cluster
name: $SEAT_CLUSTER
kubernetes:
  version: v$LAB_KUBERNETES_VERSION
talos:
  version: v$LAB_TALOS_VERSION
---
kind: ControlPlane
machines:
  - ${SEAT_MACHINE_IDS[0]}
---
kind: Workers
machines:
  - ${SEAT_MACHINE_IDS[1]}
  - ${SEAT_MACHINE_IDS[2]}
EOF
  for id in "${SEAT_MACHINE_IDS[@]}"; do
    printf -- '---\nkind: Machine\nname: %s\n' "$id"
  done
}

rehearsal_wait_cluster_ready() {
  local deadline=$((SECONDS + REHEARSAL_CLUSTER_TIMEOUT)) raw summary="" current
  while ((SECONDS < deadline)); do
    if raw="$(seat_omnictl get clusterstatus "$SEAT_CLUSTER" -o json 2>/dev/null)"; then
      current="$(jq -r '"ready=\(.spec.ready == true) healthy=\(.spec.machines.healthy // 0)/\(.spec.machines.total // 0)"' <<<"$raw")"
      if [[ "$current" != "$summary" ]]; then
        log "cluster $SEAT_CLUSTER: $current"
        summary="$current"
      fi
      [[ "$current" == "ready=true healthy=3/3" ]] && return 0
    fi
    sleep 10
  done
  rehearsal_capture_failure "cluster $SEAT_CLUSTER not ready within ${REHEARSAL_CLUSTER_TIMEOUT}s, last $summary"
}

rehearsal_wait_nodes_ready() {
  local deadline=$((SECONDS + REHEARSAL_NODE_TIMEOUT)) raw ready=""
  while ((SECONDS < deadline)); do
    if raw="$(lab_kubectl get nodes -o json 2>/dev/null)"; then
      ready="$(jq -r '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$raw")"
      [[ "$ready" == 3 ]] && return 0
    fi
    sleep 5
  done
  fail "only ${ready:-0} of 3 nodes became Ready within ${REHEARSAL_NODE_TIMEOUT}s"
}

rehearsal_cluster() {
  local template="$SEAT_STATE/cluster.yaml"
  rehearsal_render_template >"$template"
  seat_omnictl cluster template validate -f "$template" >/dev/null || exit 1
  log "syncing cluster template for $SEAT_CLUSTER"
  LAB_OMNI_TIMEOUT=300 seat_omnictl cluster template sync -f "$template" >/dev/null || rehearsal_capture_failure "cluster template sync failed"
  rehearsal_wait_cluster_ready
  rm -f "$(lab_kubeconfig)"
  seat_omnictl kubeconfig "$(lab_kubeconfig)" --cluster "$SEAT_CLUSTER" --service-account --user talos-lab-kit --ttl 24h --force --merge=false >/dev/null || exit 1
  [[ -s "$(lab_kubeconfig)" ]] || die "omnictl did not write a kubeconfig to $(lab_kubeconfig)"
  rehearsal_wait_nodes_ready || rehearsal_capture_failure "nodes did not become Ready through https://$SEAT_KUBE_HOST"
  log "cluster $SEAT_CLUSTER ready, kubectl reaches it through https://$SEAT_KUBE_HOST"
}

rehearsal_tunnel_verify() {
  local url="https://$SEAT_SITE_HOST/whoami" deadline=$((SECONDS + TUNNEL_PUBLIC_TIMEOUT)) body attempt pod seen="" nodes
  nodes="$(site_distinct_nodes default app=cloudflared)" || rehearsal_capture_failure "could not read cloudflared placement"
  ((nodes == 2)) || rehearsal_capture_failure "cloudflared pods are on $nodes nodes, expected 2"
  until lab_public_curl --silent --fail --max-time 8 --output /dev/null "$url" 2>/dev/null; do
    ((SECONDS < deadline)) || rehearsal_capture_failure "$url did not answer within ${TUNNEL_PUBLIC_TIMEOUT}s"
    sleep 5
  done
  for ((attempt = 1; attempt <= 40; attempt++)); do
    body="$(lab_public_curl --silent --fail --max-time 8 "$url")" || rehearsal_capture_failure "$url failed during verification on request $attempt"
    pod="$(jq -er .pod <<<"$body")" || rehearsal_capture_failure "$url returned an unreadable body: $body"
    grep -qxF "$pod" <<<"$seen" || seen+="$pod"$'\n'
  done
  (($(grep -c . <<<"$seen") == 2)) || rehearsal_capture_failure "only saw these pods answer in 40 public requests: $seen"
  log "site published: both connectors on 2 nodes and both replicas answering at https://$SEAT_SITE_HOST"
}

rehearsal_tunnel() {
  [[ -s "$SEAT_STATE/site-token" ]] || die "$SEAT_NAME has no site tunnel token, run ./lab seats create first"
  lab_kubectl create secret generic cloudflared-token --from-file=token="$SEAT_STATE/site-token" \
    --dry-run=client -o yaml | lab_kubectl apply -f - >/dev/null
  lab_kubectl apply -f "$LAB_ROOT/manifests/cloudflared.yaml" >/dev/null
  lab_kubectl rollout status deployment/cloudflared --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null ||
    rehearsal_capture_failure "cloudflared did not finish rolling out"
  rehearsal_tunnel_verify
}

seat_up() {
  rehearsal_load "$1"
  rehearsal_machines
  rehearsal_cluster
  site_up
  rehearsal_tunnel
  log "$SEAT_NAME rehearsal up: https://$SEAT_SITE_HOST"
}

rehearsal_cluster_exists() {
  local raw
  raw="$(seat_omnictl get clusters -o json)" || return 2
  jq -s -e --arg name "$SEAT_CLUSTER" 'any(.[]; .metadata.id == $name)' <<<"$raw" >/dev/null
}

seat_reset() {
  local index status=0 raw id deadline
  rehearsal_load "$1"
  rehearsal_cluster_exists || status=$?
  case "$status" in
    0)
      log "deleting cluster $SEAT_CLUSTER while its machines are online"
      LAB_OMNI_TIMEOUT="$REHEARSAL_DELETE_TIMEOUT" seat_omnictl cluster delete "$SEAT_CLUSTER" >/dev/null ||
        rehearsal_capture_failure "cluster $SEAT_CLUSTER could not be deleted"
      deadline=$((SECONDS + REHEARSAL_DELETE_TIMEOUT))
      while rehearsal_cluster_exists; do
        ((SECONDS < deadline)) || rehearsal_capture_failure "cluster $SEAT_CLUSTER still exists after ${REHEARSAL_DELETE_TIMEOUT}s"
        sleep 5
      done
      ;;
    1) ;;
    *) exit 1 ;;
  esac
  for index in "${!SEAT_VM_IDS[@]}"; do
    pve_delete_vm "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}" || exit 1
  done
  raw="$(seat_omnictl get links -o json)" || exit 1
  for id in "${SEAT_MACHINE_IDS[@]}"; do
    if jq -s -e --arg id "$id" 'any(.[]; .metadata.id == $id)' <<<"$raw" >/dev/null; then
      seat_omnictl delete link "$id" >/dev/null || exit 1
    fi
  done
  rm -rf "$(lab_kubeconfig)" "$SEAT_STATE/cluster.yaml"
  raw="$(seat_omnictl get links -o json)" || exit 1
  for id in "${SEAT_MACHINE_IDS[@]}"; do
    ! jq -s -e --arg id "$id" 'any(.[]; .metadata.id == $id)' <<<"$raw" >/dev/null || die "link $id still exists after reset"
  done
  for index in "${!SEAT_VM_IDS[@]}"; do
    [[ "$(pve_vm_state "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}")" == absent ]] || die "${SEAT_VM_NAMES[index]} still exists after reset"
  done
  log "$SEAT_NAME reset: cluster, machines and VMs removed, the seat's Omni, logins and tunnel kept"
}
