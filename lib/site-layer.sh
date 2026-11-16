readonly SITE_ROLLOUT_TIMEOUT=240s

site_distinct_nodes() {
  local namespace="$1" selector="$2" raw
  raw="$(lab_kubectl -n "$namespace" get pods -l "$selector" -o json)" || return 1
  jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName] | unique | length' <<<"$raw"
}

site_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/$SEAT_NAME-site-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  lab_kubectl get nodes -o wide >"$dir/nodes.txt" 2>&1 || true
  lab_kubectl get pods -A -o wide >"$dir/pods.txt" 2>&1 || true
  lab_kubectl get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
  lab_kubectl describe deployment hello >"$dir/hello-deployment.txt" 2>&1 || true
  lab_kubectl logs deployment/hello --all-containers --tail=80 >"$dir/hello-logs.txt" 2>&1 || true
  die "$reason. Context saved in $dir"
}

site_verify() {
  local nodes attempt body pod seen=""
  nodes="$(site_distinct_nodes default app=hello)" || site_capture_failure "could not read hello pod placement"
  ((nodes == 2)) || site_capture_failure "hello pods are on $nodes nodes, expected 2"
  for ((attempt = 1; attempt <= 40; attempt++)); do
    body="$(lab_kubectl get --raw /api/v1/namespaces/default/services/hello:80/proxy/whoami)" || site_capture_failure "hello service did not answer through the API proxy"
    pod="$(jq -er .pod <<<"$body")" || site_capture_failure "hello answered with an unreadable body: $body"
    grep -qxF "$pod" <<<"$seen" || seen+="$pod"$'\n'
  done
  (($(grep -c . <<<"$seen") == 2)) || site_capture_failure "only saw these pods answer in 40 requests: $seen"
  log "site verified: 2 replicas on 2 nodes, both answering"
}


SITE_PROBE_PID=""
SITE_RUN_DIR=""

site_probe_loop() {
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

site_run_begin() {
  local kind="$1" url="$2"
  SITE_RUN_DIR="$SEAT_STATE/$kind/$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$SITE_RUN_DIR"
  site_probe_loop "$SITE_RUN_DIR/probe.csv" "$url" 9>&- &
  SITE_PROBE_PID=$!
  lab_on_exit site_probe_stop
}

site_probe_stop() {
  if [[ -n "$SITE_PROBE_PID" ]]; then
    kill "$SITE_PROBE_PID" 2>/dev/null || true
    wait "$SITE_PROBE_PID" 2>/dev/null || true
    SITE_PROBE_PID=""
  fi
}

site_mark() {
  printf '%s %s\n' "$(date +%s%3N)" "$1" >>"$SITE_RUN_DIR/timeline.log"
  log "$1"
}

site_run_capture_failure() {
  local reason="$1"
  lab_kubectl get nodes -o wide >"$SITE_RUN_DIR/nodes.txt" 2>&1 || true
  lab_kubectl get pods -A -o wide >"$SITE_RUN_DIR/pods.txt" 2>&1 || true
  lab_kubectl get events -A --sort-by=.lastTimestamp >"$SITE_RUN_DIR/events.txt" 2>&1 || true
  lab_kubectl get endpointslices -o wide >"$SITE_RUN_DIR/endpointslices.txt" 2>&1 || true
  lab_kubectl logs deployment/cloudflared --all-containers --tail=120 >"$SITE_RUN_DIR/cloudflared-logs.txt" 2>&1 || true
  lab_kubectl -n kube-system logs deployment/descheduler --tail=120 >"$SITE_RUN_DIR/descheduler-logs.txt" 2>&1 || true
  die "$reason. Context saved in $SITE_RUN_DIR"
}

site_run_summarize() {
  local t0="$1" summary="$SITE_RUN_DIR/summary.txt"
  site_probe_stop
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
      }' "$SITE_RUN_DIR/probe.csv"
    awk -v t0="$t0" '{ ts = $1; $1 = ""; printf "%+8.1fs%s\n", (ts - t0) / 1000, $0 }' "$SITE_RUN_DIR/timeline.log"
  } >"$summary"
  cat "$summary" >&2
}

site_wait_spread() {
  local timeout="$1" deadline=$((SECONDS + $1)) hello="" cloudflared=""
  while ((SECONDS < deadline)); do
    hello="$(site_distinct_nodes default app=hello)" || hello=unreadable
    cloudflared="$(site_distinct_nodes default app=cloudflared)" || cloudflared=unreadable
    [[ "$hello" == 2 && "$cloudflared" == 2 ]] && return 0
    sleep 2
  done
  fail "replicas did not spread back within ${timeout}s: hello on $hello nodes, cloudflared on $cloudflared nodes"
}
