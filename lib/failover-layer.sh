readonly FAILOVER_BASELINE_SECONDS=20
readonly FAILOVER_SETTLE_SECONDS=15
readonly FAILOVER_RECOVERY_TIMEOUT=300
readonly FAILOVER_RETURN_TIMEOUT=420
readonly FAILOVER_REBALANCE_TIMEOUT=180

FAILOVER_IMAGE_SETTLE_SECONDS="${FAILOVER_IMAGE_SETTLE_SECONDS:-120}"

failover_wait_images_settled() {
  local raw newest remaining
  raw="$(lab_kubectl get pods -l 'app in (hello,cloudflared)' -o json)" || return 1
  newest="$(jq -er '[.items[].status.startTime | select(. != null) | fromdate] | max' <<<"$raw")" || return 1
  remaining=$((newest + FAILOVER_IMAGE_SETTLE_SECONDS - $(date +%s)))
  if ((remaining > 0)); then
    log "waiting ${remaining}s so recently pulled images reach disk before the power cut"
    sleep "$remaining"
  fi
}

failover_worker_index() {
  case "$1" in
    worker-a) printf '1\n' ;;
    worker-b) printf '2\n' ;;
    *)
      fail "unknown failover target \"$1\", expected worker-a or worker-b"
      return 1
      ;;
  esac
}

failover_node_for_machine() {
  local raw
  raw="$(seat_omnictl get clustermachineidentities "$1" -o json)" || return 1
  jq -er '.spec.nodename' <<<"$raw"
}

failover_node_state() {
  local raw
  raw="$(lab_kubectl get node "$1" -o json 2>/dev/null)" || {
    printf 'query-failed\n'
    return 0
  }
  jq -r '[.status.conditions[] | select(.type == "Ready") | .status][0]' <<<"$raw"
}

failover_ready_endpoints_on() {
  local raw
  raw="$(lab_kubectl get endpointslices -l kubernetes.io/service-name=hello -o json 2>/dev/null)" || {
    printf 'query-failed\n'
    return 0
  }
  jq -r --arg node "$1" '[.items[].endpoints[]? | select(.nodeName == $node and .conditions.ready != false)] | length' <<<"$raw"
}

failover_ready_away_from() {
  local selector="$1" dead="$2" raw
  raw="$(lab_kubectl get pods -l "$selector" -o json 2>/dev/null)" || {
    printf 'query-failed\n'
    return 0
  }
  jq -r --arg dead "$dead" \
    '[.items[] | select(.metadata.deletionTimestamp == null and .spec.nodeName != $dead) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length' <<<"$raw"
}

failover_watch_recovery() {
  local dead="$1" deadline state endpoints hello cloudflared
  local node_done=false endpoints_done=false hello_done=false cloudflared_done=false
  deadline=$((SECONDS + FAILOVER_RECOVERY_TIMEOUT))
  while ((SECONDS < deadline)); do
    state="$(failover_node_state "$dead")"
    endpoints="$(failover_ready_endpoints_on "$dead")"
    hello="$(failover_ready_away_from app=hello "$dead")"
    cloudflared="$(failover_ready_away_from app=cloudflared "$dead")"
    if [[ "$node_done" == false && ("$state" == False || "$state" == Unknown) ]]; then
      node_done=true
      site_mark "node $dead marked not Ready, condition is $state"
    fi
    if [[ "$endpoints_done" == false && "$endpoints" == 0 ]]; then
      endpoints_done=true
      site_mark "the Service stopped sending traffic to node $dead"
    fi
    if [[ "$hello_done" == false && "$hello" == 2 ]]; then
      hello_done=true
      site_mark "both hello replicas Ready on the surviving worker"
    fi
    if [[ "$cloudflared_done" == false && "$cloudflared" == 2 ]]; then
      cloudflared_done=true
      site_mark "both cloudflared replicas Ready on the surviving worker"
    fi
    if [[ "$node_done" == true && "$endpoints_done" == true && "$hello_done" == true && "$cloudflared_done" == true ]]; then
      return 0
    fi
    sleep 1
  done
  fail "recovery incomplete after ${FAILOVER_RECOVERY_TIMEOUT}s: node=$state endpoints_on_dead_node=$endpoints hello=$hello cloudflared=$cloudflared"
}

failover_wait_node_ready() {
  local node="$1" deadline
  deadline=$((SECONDS + FAILOVER_RETURN_TIMEOUT))
  while ((SECONDS < deadline)); do
    if [[ "$(failover_node_state "$node")" == True ]]; then
      return 0
    fi
    sleep 1
  done
  fail "node $node did not return to Ready within ${FAILOVER_RETURN_TIMEOUT}s"
}

failover_run() {
  local requested="$1" target="$2" index vmid name id node t0 url coredns_on
  index="$(failover_worker_index "$target")" || exit 1
  rehearsal_load "$requested"
  [[ -s "$(lab_kubeconfig)" ]] || die "$SEAT_NAME has no cluster, run ./lab seat $SEAT up first"
  vmid="${SEAT_VM_IDS[index]}"
  name="${SEAT_VM_NAMES[index]}"
  id="${SEAT_MACHINE_IDS[index]}"
  url="https://$SEAT_SITE_HOST/whoami"
  node="$(failover_node_for_machine "$id")" || exit 1
  [[ -n "$node" ]] || die "could not find the Kubernetes node for $name"

  lab_public_curl --silent --fail --max-time 8 --output /dev/null "$url" || die "$url is not answering, run ./lab seat $SEAT up first"
  [[ "$(site_distinct_nodes default app=hello)" == 2 ]] || die "hello replicas are not spread across both workers"
  [[ "$(site_distinct_nodes default app=cloudflared)" == 2 ]] || die "cloudflared replicas are not spread across both workers"
  coredns_on="$(lab_kubectl -n kube-system get pods -l k8s-app=kube-dns -o json | jq -r --arg node "$node" '[.items[] | select(.spec.nodeName == $node)] | length')"

  failover_wait_images_settled || die "could not read pod start times before the failover"

  site_run_begin "failover" "$url"
  log "target is $name on node $node, which runs $coredns_on CoreDNS pods, probing $url for ${FAILOVER_BASELINE_SECONDS}s first"
  sleep "$FAILOVER_BASELINE_SECONDS"

  t0="$(date +%s%3N)"
  site_mark "hard stopping $name"
  pve_stop_vm "$vmid" "$name" || site_run_capture_failure "could not stop $name"
  site_mark "$name powered off"
  failover_watch_recovery "$node" || site_run_capture_failure "the cluster did not recover from losing $name"
  sleep "$FAILOVER_SETTLE_SECONDS"

  site_mark "starting $name again"
  pve_start_vm "$vmid" "$name" || site_run_capture_failure "could not start $name"
  failover_wait_node_ready "$node" || site_run_capture_failure "node $node did not return to Ready"
  site_mark "node $node Ready again"

  site_wait_spread "$FAILOVER_REBALANCE_TIMEOUT" || site_run_capture_failure "the descheduler did not move replicas back to $node"
  site_mark "the descheduler moved replicas back, both deployments span both workers"

  site_run_summarize "$t0"
  log "failover run saved in $SITE_RUN_DIR"
}
