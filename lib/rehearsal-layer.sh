readonly REHEARSAL_LINK_TIMEOUT=420
readonly REHEARSAL_CLUSTER_TIMEOUT=1500
readonly REHEARSAL_NODE_TIMEOUT=420
readonly REHEARSAL_DELETE_TIMEOUT=900
readonly REHEARSAL_DOWNLOAD_TIMEOUT=900
readonly REHEARSAL_PRESET=talos-lab
readonly REHEARSAL_EXTENSION=siderolabs/qemu-guest-agent
readonly REHEARSAL_CPU_TYPE=x86-64-v2-AES

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
  pve_api GET "/nodes/$PVE_NODE/qemu/$SEAT_TEMPLATE_ID/config" >"$dir/vm-$SEAT_TEMPLATE_NAME-config.json" 2>&1 || true
  pve_api GET "/nodes/$PVE_NODE/storage/$SEAT_ISO_STORAGE/content" >"$dir/$SEAT_ISO_STORAGE-content.json" 2>&1 || true
  pve_api GET "/nodes/$PVE_NODE/tasks?limit=20&errors=1" >"$dir/failed-tasks.json" 2>&1 || true
  seat_omnictl get links -o json >"$dir/links.json" 2>&1 || true
  seat_omnictl get machinestatus -o json >"$dir/machinestatus.json" 2>&1 || true
  seat_omnictl get clusterstatus "$SEAT_CLUSTER" -o json >"$dir/clusterstatus.json" 2>&1 || true
  pve_ssh "pct exec $SEAT_WS_ID -- journalctl --no-pager --lines=80 -u talos-lab-workspace" >"$dir/workspace.txt" 2>&1 || true
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

rehearsal_image_url() {
  local presets preset factory output pxe
  presets="$(seat_omnictl get installationmediaconfigs -o json)" || return 1
  if ! jq -e -s --arg p "$REHEARSAL_PRESET" 'any(.[]; .metadata.id == $p)' <<<"$presets" >/dev/null 2>&1; then
    seat_omnictl media preset create "$REHEARSAL_PRESET" --talos-version "$LAB_TALOS_VERSION" --extensions "$REHEARSAL_EXTENSION" >/dev/null || return 1
  fi
  preset="$(seat_omnictl get installationmediaconfigs "$REHEARSAL_PRESET" -o json)" || return 1
  factory="$(jq -er '.spec.imagefactoryurl' <<<"$preset")" || {
    fail "preset $REHEARSAL_PRESET names no image factory: $preset"
    return 1
  }
  output="$(seat_omnictl media download "$REHEARSAL_PRESET" --format pxe 2>&1)" || {
    fail "omnictl could not print the PXE link for preset $REHEARSAL_PRESET: $output"
    return 1
  }
  pxe="$(grep -oE 'https://[^ ]+/pxe/[0-9a-f]+/v[0-9.]+/metal-amd64$' <<<"$output")" || {
    fail "omnictl printed no PXE link for preset $REHEARSAL_PRESET: $output"
    return 1
  }
  printf '%s/image/%s/%s/metal-amd64.iso\n' "$factory" "$(cut -d/ -f5 <<<"$pxe")" "$(cut -d/ -f6 <<<"$pxe")"
}

rehearsal_image() {
  local isos url response
  isos="$(pve_storage_isos "$SEAT_ISO_STORAGE")" || exit 1
  [[ -z "$isos" ]] || die "$SEAT_ISO_STORAGE already holds $(paste -sd' ' <<<"$isos"), run ./lab seat $SEAT reset first"
  url="$(rehearsal_image_url)" || rehearsal_capture_failure "could not build the install image link for $SEAT_NAME"
  log "$SEAT_PVE_USER asks Proxmox to download the install image from ${url%%/image/*}"
  response="$(host_pve_session_api POST "/nodes/$PVE_NODE/storage/$SEAT_ISO_STORAGE/download-url" \
    --data-urlencode content=iso \
    --data-urlencode "filename=$SEAT_ISO" \
    --data-urlencode "url=$url")" || rehearsal_capture_failure "$SEAT_PVE_USER could not start the install image download"
  pve_wait_response "$response" "$REHEARSAL_DOWNLOAD_TIMEOUT" host_pve_session_api ||
    rehearsal_capture_failure "the install image download into $SEAT_ISO_STORAGE did not finish"
  log "install image downloaded into $SEAT_ISO_STORAGE as $SEAT_ISO"
}

rehearsal_template() {
  local response
  response="$(host_pve_session_api POST "/nodes/$PVE_NODE/qemu" \
    --data-urlencode "vmid=$SEAT_TEMPLATE_ID" \
    --data-urlencode "name=$SEAT_TEMPLATE_NAME" \
    --data-urlencode "pool=$SEAT_NAME" \
    --data-urlencode "ide2=$SEAT_ISO_STORAGE:iso/$SEAT_ISO,media=cdrom" \
    --data-urlencode ostype=l26 \
    --data-urlencode scsihw=virtio-scsi-pci \
    --data-urlencode agent=1 \
    --data-urlencode "scsi0=$PVE_DISK_STORAGE:$SEAT_VM_DISK_GIB" \
    --data-urlencode sockets=1 \
    --data-urlencode "cores=$SEAT_VM_CORES" \
    --data-urlencode "cpu=$REHEARSAL_CPU_TYPE" \
    --data-urlencode "memory=$SEAT_VM_MEMORY_MIB" \
    --data-urlencode balloon=0 \
    --data-urlencode "net0=virtio,bridge=$SEAT_VNET,firewall=1")" ||
    rehearsal_capture_failure "$SEAT_PVE_USER could not create $SEAT_TEMPLATE_NAME"
  pve_wait_response "$response" 300 host_pve_session_api || rehearsal_capture_failure "creating $SEAT_TEMPLATE_NAME did not finish"
  response="$(host_pve_session_api POST "/nodes/$PVE_NODE/qemu/$SEAT_TEMPLATE_ID/template")" ||
    rehearsal_capture_failure "$SEAT_PVE_USER could not convert $SEAT_TEMPLATE_NAME to a template"
  pve_wait_response "$response" 300 host_pve_session_api || rehearsal_capture_failure "converting $SEAT_TEMPLATE_NAME did not finish"
  log "$SEAT_PVE_USER created $SEAT_TEMPLATE_NAME ($SEAT_TEMPLATE_ID) in pool $SEAT_NAME and converted it to a template"
}

rehearsal_clone_vm() {
  local index="$1" response
  response="$(host_pve_session_api POST "/nodes/$PVE_NODE/qemu/$SEAT_TEMPLATE_ID/clone" \
    --data-urlencode "newid=${SEAT_VM_IDS[index]}" \
    --data-urlencode "name=${SEAT_VM_NAMES[index]}" \
    --data-urlencode "pool=$SEAT_NAME")" || return 1
  pve_wait_response "$response" 300 host_pve_session_api || return 1
  response="$(pve_api PUT "/nodes/$PVE_NODE/qemu/${SEAT_VM_IDS[index]}/config" \
    --data-urlencode "smbios1=uuid=${SEAT_MACHINE_IDS[index]}")" || return 1
  pve_wait_response "$response" 60
}

rehearsal_machines() {
  local index state
  state="$(pve_vm_state "$SEAT_TEMPLATE_ID" "$SEAT_TEMPLATE_NAME")" || exit 1
  [[ "$state" == absent ]] || die "$SEAT_TEMPLATE_NAME already exists and is $state, run ./lab seat $SEAT reset first"
  for index in "${!SEAT_VM_IDS[@]}"; do
    state="$(pve_vm_state "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}")" || exit 1
    [[ "$state" == absent ]] || die "${SEAT_VM_NAMES[index]} already exists and is $state, run ./lab seat $SEAT reset first"
  done
  host_pve_login "$SEAT_USER" || exit 1
  rehearsal_image
  rehearsal_template
  for index in "${!SEAT_VM_IDS[@]}"; do
    rehearsal_clone_vm "$index" || exit 1
    log "$SEAT_PVE_USER cloned $SEAT_TEMPLATE_NAME into ${SEAT_VM_NAMES[index]} (${SEAT_VM_IDS[index]}) in pool $SEAT_NAME"
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

rehearsal_student() {
  local step="$1" command="$2" output
  output="$(seat_workspace_run "$command" 2>&1)" || rehearsal_capture_failure "the workspace step \"$step\" failed: $output"
  log "workspace: $step"
}

rehearsal_student_site() {
  local attempt nodes=0
  rehearsal_student "connect and list nodes" 'connect && kubectl get nodes'
  for ((attempt = 1; attempt <= 4; attempt++)); do
    rehearsal_student "restart CoreDNS" 'kubectl -n kube-system rollout restart deployment/coredns && kubectl -n kube-system rollout status deployment/coredns'
    nodes="$(site_distinct_nodes kube-system k8s-app=kube-dns)" || rehearsal_capture_failure "could not read CoreDNS placement"
    ((nodes >= 2)) && break
  done
  ((nodes >= 2)) || rehearsal_capture_failure "CoreDNS stayed on $nodes node after $attempt restarts"
  log "CoreDNS spread across $nodes nodes"
  rehearsal_student "deploy the site" 'kubectl apply -f manifests/hello.yaml && kubectl rollout status deployment/hello'
  site_verify
  rehearsal_student "publish the site" 'kubectl create secret generic cloudflared-token --from-literal=token="$(cat token.txt)" && kubectl apply -f manifests/cloudflared.yaml && kubectl rollout status deployment/cloudflared'
  rehearsal_tunnel_verify
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

seat_up() {
  rehearsal_load "$1"
  rehearsal_machines
  rehearsal_cluster
  rehearsal_student_site
  log "$SEAT_NAME rehearsal up: https://$SEAT_SITE_HOST"
}

rehearsal_cluster_names() {
  local raw
  raw="$(seat_omnictl get clusters -o json)" || return 1
  jq -s -r '.[].metadata.id' <<<"$raw"
}

seat_reset() {
  local clusters cluster deadline raw ids id volid leftovers
  rehearsal_load "$1"
  clusters="$(rehearsal_cluster_names)" || exit 1
  for cluster in $clusters; do
    log "deleting cluster $cluster while its machines are online"
    LAB_OMNI_TIMEOUT="$REHEARSAL_DELETE_TIMEOUT" seat_omnictl cluster delete "$cluster" >/dev/null ||
      rehearsal_capture_failure "cluster $cluster could not be deleted"
  done
  deadline=$((SECONDS + REHEARSAL_DELETE_TIMEOUT))
  while [[ -n "$(rehearsal_cluster_names)" ]]; do
    ((SECONDS < deadline)) || rehearsal_capture_failure "clusters still exist after ${REHEARSAL_DELETE_TIMEOUT}s: $(rehearsal_cluster_names | paste -sd' ')"
    sleep 5
  done
  seat_delete_pool_vms
  leftovers="$(pve_storage_isos "$SEAT_ISO_STORAGE")" || exit 1
  while IFS= read -r volid; do
    [[ -n "$volid" ]] || continue
    pve_delete_volume "$volid" || exit 1
    log "install image $volid removed"
  done <<<"$leftovers"
  seat_omnictl delete installationmediaconfigs --all >/dev/null || exit 1
  raw="$(seat_omnictl get links -o json)" || exit 1
  ids="$(jq -s -r '.[].metadata.id' <<<"$raw")"
  for id in $ids; do
    seat_omnictl delete link "$id" >/dev/null 2>&1 || exit 1
  done
  rm -rf "$(lab_kubeconfig)" "$SEAT_STATE/cluster.yaml"
  pve_ssh "pct exec $SEAT_WS_ID -- rm -rf /home/$SEAT_WS_USER/.kube" || exit 1
  [[ -z "$(rehearsal_cluster_names)" ]] || die "clusters remain after reset"
  raw="$(seat_omnictl get links -o json)" || exit 1
  [[ "$(jq -s 'length' <<<"$raw")" == 0 ]] || die "machines remain in the $SEAT_NAME Omni after reset"
  leftovers="$(seat_pool_vms)" || exit 1
  [[ -z "$leftovers" ]] || die "pool $SEAT_NAME still holds VMs after reset: $(cut -f2 <<<"$leftovers" | paste -sd' ')"
  leftovers="$(pve_storage_isos "$SEAT_ISO_STORAGE")" || exit 1
  [[ -z "$leftovers" ]] || die "$SEAT_ISO_STORAGE still holds images after reset: $(paste -sd' ' <<<"$leftovers")"
  raw="$(seat_omnictl get installationmediaconfigs -o json)" || exit 1
  [[ "$(jq -s 'length' <<<"$raw")" == 0 ]] || die "installation media presets remain in the $SEAT_NAME Omni after reset"
  log "$SEAT_NAME reset: clusters, machines, VMs, templates, install images and media presets removed, the Omni, workspace, logins and tunnel kept"
}
