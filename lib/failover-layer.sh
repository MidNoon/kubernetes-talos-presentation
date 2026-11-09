readonly FAILOVER_BASELINE_SECONDS=20
readonly FAILOVER_SETTLE_SECONDS=15
readonly FAILOVER_RECOVERY_TIMEOUT=300
readonly FAILOVER_RETURN_TIMEOUT=420

FAILOVER_PROBE_PID=""

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
  raw="$(omni_query get clustermachineidentities "$1" -o json)" || return 1
  jq -er '.spec.nodename' <<<"$raw"
}

failover_probe_loop() {
  local out="$1" url="$2" started body code rc pod node
  while :; do
    started="$(date +%s%3N)"
    rc=0
    body="$(lab_public_curl --silent --max-time 3 --write-out '\n%{http_code}' "$url" 2>/dev/null)" || rc=$?
    code="${body##*$'\n'}"
    body="${body%$'\n'*}"
    pod="$(jq -r '.pod // ""' <<<"$body" 2>/dev/null || true)"
    node="$(jq -r '.node // ""' <<<"$body" 2>/dev/null || true)"
    printf '%s,%s,%s,%s,%s\n' "$started" "${code:-000}" "$rc" "$pod" "$node" >>"$out"
    sleep 1
  done
}

failover_stop_probe() {
  if [[ -n "$FAILOVER_PROBE_PID" ]]; then
    kill "$FAILOVER_PROBE_PID" 2>/dev/null || true
    wait "$FAILOVER_PROBE_PID" 2>/dev/null || true
    FAILOVER_PROBE_PID=""
  fi
}

failover_mark() {
  printf '%s %s\n' "$(date +%s%3N)" "$1" >>"$FAILOVER_DIR/timeline.log"
  log "$1"
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
      failover_mark "node $dead marked not Ready, condition is $state"
    fi
    if [[ "$endpoints_done" == false && "$endpoints" == 0 ]]; then
      endpoints_done=true
      failover_mark "the Service stopped sending traffic to node $dead"
    fi
    if [[ "$hello_done" == false && "$hello" == 2 ]]; then
      hello_done=true
      failover_mark "both hello replicas Ready on the surviving worker"
    fi
    if [[ "$cloudflared_done" == false && "$cloudflared" == 2 ]]; then
      cloudflared_done=true
      failover_mark "both cloudflared replicas Ready on the surviving worker"
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

failover_capture_failure() {
  local reason="$1"
  lab_kubectl get nodes -o wide >"$FAILOVER_DIR/nodes.txt" 2>&1 || true
  lab_kubectl get pods -A -o wide >"$FAILOVER_DIR/pods.txt" 2>&1 || true
  lab_kubectl get events -A --sort-by=.lastTimestamp >"$FAILOVER_DIR/events.txt" 2>&1 || true
  lab_kubectl get endpointslices -o wide >"$FAILOVER_DIR/endpointslices.txt" 2>&1 || true
  lab_kubectl logs deployment/cloudflared --all-containers --tail=120 >"$FAILOVER_DIR/cloudflared-logs.txt" 2>&1 || true
  die "$reason. Context saved in $FAILOVER_DIR"
}

failover_summarize() {
  local t0="$1" summary="$FAILOVER_DIR/summary.txt"
  {
    awk -F, -v t0="$t0" '
      function close_window() {
        if (run > 0) {
          printf "failed: %d request(s) from %+.1fs to %+.1fs\n", run, (first - t0) / 1000, (last - t0) / 1000
          run = 0
        }
      }
      {
        total++
        if ($2 == "200") {
          if ($5 != "") nodes[$5]++
          close_window()
        } else {
          failed++
          reasons["http=" $2 " curl=" $3]++
          if (run == 0) first = $1
          last = $1
          run++
        }
      }
      END {
        close_window()
        printf "requests: %d total, %d failed\n", total, failed + 0
        for (r in reasons) printf "failure type %s: %d\n", r, reasons[r]
        for (n in nodes) printf "answered by %s: %d\n", n, nodes[n]
      }' "$FAILOVER_DIR/probe.csv"
    awk -v t0="$t0" '{ ts = $1; $1 = ""; printf "%+8.1fs%s\n", (ts - t0) / 1000, $0 }' "$FAILOVER_DIR/timeline.log"
  } >"$summary"
  cat "$summary" >&2
}

failover_run() {
  local target="$1" index vmid name id node t0 url coredns_on
  index="$(failover_worker_index "$target")" || exit 1
  vmid="${LAB_VM_IDS[index]}"
  name="${LAB_VM_NAMES[index]}"
  id="${LAB_MACHINE_IDS[index]}"
  lab_load_config
  cf_load_config
  pve_load_target || exit 1
  site_require_cluster
  url="https://$LAB_TUNNEL_HOSTNAME/whoami"
  node="$(failover_node_for_machine "$id")" || exit 1
  [[ -n "$node" ]] || die "could not find the Kubernetes node for $name"

  FAILOVER_DIR="$LAB_STATE/failover/$(date +%Y%m%dT%H%M%S)-$target"
  mkdir -p "$FAILOVER_DIR"
  lab_public_curl --silent --fail --max-time 8 --output /dev/null "$url" || die "$url is not answering, run ./lab tunnel up first"
  [[ "$(site_distinct_nodes default app=hello)" == 2 ]] || die "hello replicas are not spread across both workers"
  [[ "$(site_distinct_nodes default app=cloudflared)" == 2 ]] || die "cloudflared replicas are not spread across both workers"
  coredns_on="$(lab_kubectl -n kube-system get pods -l k8s-app=kube-dns -o json | jq -r --arg node "$node" '[.items[] | select(.spec.nodeName == $node)] | length')"

  failover_probe_loop "$FAILOVER_DIR/probe.csv" "$url" &
  FAILOVER_PROBE_PID=$!
  trap failover_stop_probe EXIT
  log "target is $name on node $node, which runs $coredns_on CoreDNS pods, probing $url for ${FAILOVER_BASELINE_SECONDS}s first"
  sleep "$FAILOVER_BASELINE_SECONDS"

  t0="$(date +%s%3N)"
  failover_mark "hard stopping $name"
  pve_stop_lab_vm "$vmid" || failover_capture_failure "could not stop $name"
  failover_mark "$name powered off"
  failover_watch_recovery "$node" || failover_capture_failure "the cluster did not recover from losing $name"
  sleep "$FAILOVER_SETTLE_SECONDS"

  cap_gate || failover_capture_failure "cap gate refused restarting $name"
  failover_mark "starting $name again"
  pve_start_lab_vm "$vmid" || failover_capture_failure "could not start $name"
  failover_wait_node_ready "$node" || failover_capture_failure "node $node did not return to Ready"
  failover_mark "node $node Ready again"
  sleep "$FAILOVER_SETTLE_SECONDS"

  failover_mark "restarting both deployments to rebalance across the workers"
  lab_kubectl rollout restart deployment/hello deployment/cloudflared >/dev/null
  lab_kubectl rollout status deployment/hello --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null || failover_capture_failure "hello rollout failed after recovery"
  lab_kubectl rollout status deployment/cloudflared --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null || failover_capture_failure "cloudflared rollout failed after recovery"
  sleep "$FAILOVER_SETTLE_SECONDS"
  [[ "$(site_distinct_nodes default app=hello)" == 2 ]] || failover_capture_failure "hello did not rebalance across both workers"
  [[ "$(site_distinct_nodes default app=cloudflared)" == 2 ]] || failover_capture_failure "cloudflared did not rebalance across both workers"
  failover_mark "rebalanced across both workers"

  failover_stop_probe
  failover_summarize "$t0"
  log "failover run saved in $FAILOVER_DIR"
}
