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

