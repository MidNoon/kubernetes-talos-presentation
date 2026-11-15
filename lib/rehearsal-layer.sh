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

rehearsal_clone_vm() {
  local index="$1" response
  response="$(pve_api POST "/nodes/$PVE_NODE/qemu/$SEAT_TEMPLATE_ID/clone" \
    --data-urlencode "newid=${SEAT_VM_IDS[index]}" \
    --data-urlencode "name=${SEAT_VM_NAMES[index]}" \
    --data-urlencode "pool=$SEAT_NAME")" || return 1
  pve_wait_response "$response" 300 || return 1
  response="$(pve_api PUT "/nodes/$PVE_NODE/qemu/${SEAT_VM_IDS[index]}/config" \
    --data-urlencode "smbios1=uuid=${SEAT_MACHINE_IDS[index]}")" || return 1
  pve_wait_response "$response" 60
}

rehearsal_machines() {
  local index state
  [[ "$(pve_vm_state "$SEAT_TEMPLATE_ID" "$SEAT_TEMPLATE_NAME")" == stopped ]] || die "$SEAT_TEMPLATE_NAME is missing, run ./lab seats create first"
  for index in "${!SEAT_VM_IDS[@]}"; do
    state="$(pve_vm_state "${SEAT_VM_IDS[index]}" "${SEAT_VM_NAMES[index]}")" || exit 1
    [[ "$state" == absent ]] || die "${SEAT_VM_NAMES[index]} already exists and is $state, run ./lab seat $SEAT reset first"
  done
  for index in "${!SEAT_VM_IDS[@]}"; do
    rehearsal_clone_vm "$index" || exit 1
    log "cloned $SEAT_TEMPLATE_NAME into ${SEAT_VM_NAMES[index]} (${SEAT_VM_IDS[index]}) in pool $SEAT_NAME"
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
  local clusters cluster deadline raw ids id vms vmid name template
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
  vms="$(seat_pool_vms)" || exit 1
  while IFS=$'\t' read -r vmid name; do
    [[ -n "$vmid" && "$vmid" != "$SEAT_TEMPLATE_ID" ]] || continue
    pve_delete_vm "$vmid" "$name" || exit 1
    log "VM $name ($vmid) removed"
  done <<<"$vms"
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
  template="$(pve_vm_state "$SEAT_TEMPLATE_ID" "$SEAT_TEMPLATE_NAME")" || exit 1
  [[ "$template" == stopped ]] || die "$SEAT_TEMPLATE_NAME is $template after reset"
  [[ "$(seat_pool_vms | grep -c . || true)" == 1 ]] || die "pool $SEAT_NAME still holds VMs besides the template: $(seat_pool_vms | cut -f2 | paste -sd' ')"
  log "$SEAT_NAME reset: clusters, machines and VMs removed, the template, Omni, workspace, logins and tunnel kept"
}
