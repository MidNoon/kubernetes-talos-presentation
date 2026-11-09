readonly SITE_ROLLOUT_TIMEOUT=240s

site_require_cluster() {
  local context
  [[ -s "$(lab_kubeconfig)" ]] || die "no lab kubeconfig at $(lab_kubeconfig), run ./lab cluster up first"
  context="$(lab_kubectl config current-context)" || die "could not read the lab kubeconfig context"
  [[ "$context" == *"$LAB_CLUSTER_NAME"* ]] || die "kubeconfig context $context does not belong to cluster $LAB_CLUSTER_NAME"
}

site_distinct_nodes() {
  local namespace="$1" selector="$2" raw
  raw="$(lab_kubectl -n "$namespace" get pods -l "$selector" -o json)" || return 1
  jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | .spec.nodeName] | unique | length' <<<"$raw"
}

site_capture_failure() {
  local reason="$1" dir
  dir="$LAB_STATE/failures/site-$(date +%Y%m%dT%H%M%S)"
  mkdir -p "$dir"
  lab_kubectl get nodes -o wide >"$dir/nodes.txt" 2>&1 || true
  lab_kubectl get pods -A -o wide >"$dir/pods.txt" 2>&1 || true
  lab_kubectl get events -A --sort-by=.lastTimestamp >"$dir/events.txt" 2>&1 || true
  lab_kubectl describe deployment hello >"$dir/hello-deployment.txt" 2>&1 || true
  lab_kubectl logs deployment/hello --all-containers --tail=80 >"$dir/hello-logs.txt" 2>&1 || true
  die "$reason. Context saved in $dir"
}

site_rebalance_coredns() {
  local attempt nodes=0
  for ((attempt = 1; attempt <= 4; attempt++)); do
    lab_kubectl -n kube-system rollout restart deployment/coredns >/dev/null
    lab_kubectl -n kube-system rollout status deployment/coredns --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null ||
      site_capture_failure "CoreDNS did not finish rolling out"
    nodes="$(site_distinct_nodes kube-system k8s-app=kube-dns)" || site_capture_failure "could not read CoreDNS placement"
    if ((nodes >= 2)); then
      log "CoreDNS spread across $nodes nodes"
      return 0
    fi
  done
  site_capture_failure "CoreDNS stayed on $nodes node after $((attempt - 1)) restarts"
}

site_verify() {
  local nodes attempt body pod seen=""
  lab_load_config
  site_require_cluster
  nodes="$(site_distinct_nodes default app=hello)" || site_capture_failure "could not read hello pod placement"
  ((nodes == 2)) || site_capture_failure "hello pods are on $nodes nodes, expected 2"
  for ((attempt = 1; attempt <= 40; attempt++)); do
    body="$(lab_kubectl get --raw /api/v1/namespaces/default/services/hello:80/proxy/whoami)" || site_capture_failure "hello service did not answer through the API proxy"
    pod="$(jq -er .pod <<<"$body")" || site_capture_failure "hello answered with an unreadable body: $body"
    if ! grep -qxF "$pod" <<<"$seen"; then
      seen+="$pod"$'\n'
    fi
  done
  (($(grep -c . <<<"$seen") == 2)) || site_capture_failure "only saw these pods answer in 40 requests: $seen"
  log "site verified: 2 replicas on 2 nodes, both answering"
}

site_up() {
  lab_load_config
  site_require_cluster
  site_rebalance_coredns
  lab_kubectl apply -f "$LAB_ROOT/manifests/hello.yaml" >/dev/null
  lab_kubectl rollout status deployment/hello --timeout="$SITE_ROLLOUT_TIMEOUT" >/dev/null ||
    site_capture_failure "hello deployment did not finish rolling out"
  site_verify
}
