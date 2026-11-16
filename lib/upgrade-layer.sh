readonly UPGRADE_BASELINE_SECONDS=20
readonly UPGRADE_TIMEOUT=2400
readonly UPGRADE_REBALANCE_TIMEOUT=180

upgrade_node_states() {
  local raw
  raw="$(lab_kubectl get nodes -o json --request-timeout=10s 2>/dev/null)" || {
    printf 'unreadable\n'
    return 0
  }
  jq -r '.items[]
    | [.metadata.name,
       "talos=" + ((.status.nodeInfo.osImage | capture("v(?<v>[0-9.]+)") | .v) // "unknown"),
       "kubelet=" + (.status.nodeInfo.kubeletVersion | ltrimstr("v")),
       "ready=" + ([.status.conditions[] | select(.type == "Ready") | .status][0]),
       (if .spec.unschedulable == true then "cordoned" else "schedulable" end)]
    | join(" ")' <<<"$raw" | sort
}

upgrade_wait() {
  local talos_version="$1" kubernetes_version="$2" deadline=$((SECONDS + UPGRADE_TIMEOUT)) states previous="" line count
  while ((SECONDS < deadline)); do
    states="$(upgrade_node_states)"
    if [[ "$states" != "$previous" ]]; then
      while IFS= read -r line; do
        grep -qxF "$line" <<<"$previous" || site_mark "node $line"
      done <<<"$states"
      previous="$states"
    fi
    count="$(grep -c "talos=$talos_version kubelet=$kubernetes_version ready=True schedulable$" <<<"$states" || true)"
    if ((count == ${#SEAT_VM_IDS[@]})); then
      return 0
    fi
    sleep 2
  done
  fail "nodes did not all reach Talos $talos_version and Kubernetes $kubernetes_version within ${UPGRADE_TIMEOUT}s: $(paste -sd';' <<<"$states")"
}

upgrade_sync() {
  local talos_version="$1" kubernetes_version="$2" template="$SEAT_STATE/cluster.yaml"
  rehearsal_render_template "$talos_version" "$kubernetes_version" >"$template"
  seat_omnictl cluster template validate -f "$template" >/dev/null || site_run_capture_failure "the upgraded cluster template is invalid"
  LAB_OMNI_TIMEOUT=300 seat_omnictl cluster template sync -f "$template" >/dev/null || site_run_capture_failure "syncing the upgraded cluster template failed"
}

seat_upgrade() {
  local url t0 count
  rehearsal_load "$1"
  [[ -s "$(lab_kubeconfig)" ]] || die "$SEAT_NAME has no cluster, run ./lab seat $SEAT up first"
  count="$(upgrade_node_states | grep -c "talos=$LAB_TALOS_VERSION kubelet=$LAB_KUBERNETES_VERSION ready=True schedulable$" || true)"
  ((count == ${#SEAT_VM_IDS[@]})) || die "$SEAT_NAME is not on Talos $LAB_TALOS_VERSION and Kubernetes $LAB_KUBERNETES_VERSION everywhere, run ./lab seat $SEAT reset and up first: $(upgrade_node_states | paste -sd';')"
  url="https://$SEAT_SITE_HOST/whoami"
  lab_public_curl --silent --fail --max-time 8 --output /dev/null "$url" || die "$url is not answering, run ./lab seat $SEAT up first"
  site_wait_spread 30 || die "replicas are not spread across both workers before the upgrade"

  site_run_begin "upgrade" "$url"
  log "probing $url for ${UPGRADE_BASELINE_SECONDS}s before the upgrade"
  sleep "$UPGRADE_BASELINE_SECONDS"

  t0="$(date +%s%3N)"
  site_mark "updating Talos from $LAB_TALOS_VERSION to $LAB_TALOS_UPGRADE_VERSION"
  upgrade_sync "$LAB_TALOS_UPGRADE_VERSION" "$LAB_KUBERNETES_VERSION"
  upgrade_wait "$LAB_TALOS_UPGRADE_VERSION" "$LAB_KUBERNETES_VERSION" || site_run_capture_failure "the Talos upgrade did not finish"
  site_mark "every node runs Talos $LAB_TALOS_UPGRADE_VERSION"
  site_wait_spread "$UPGRADE_REBALANCE_TIMEOUT" || site_run_capture_failure "replicas did not spread back after the Talos upgrade"
  site_mark "replicas span both workers after the Talos upgrade"

  site_mark "updating Kubernetes from $LAB_KUBERNETES_VERSION to $LAB_KUBERNETES_UPGRADE_VERSION"
  upgrade_sync "$LAB_TALOS_UPGRADE_VERSION" "$LAB_KUBERNETES_UPGRADE_VERSION"
  upgrade_wait "$LAB_TALOS_UPGRADE_VERSION" "$LAB_KUBERNETES_UPGRADE_VERSION" || site_run_capture_failure "the Kubernetes upgrade did not finish"
  site_mark "every node runs Kubernetes $LAB_KUBERNETES_UPGRADE_VERSION"
  rehearsal_wait_cluster_ready
  site_wait_spread "$UPGRADE_REBALANCE_TIMEOUT" || site_run_capture_failure "replicas did not spread back after the Kubernetes upgrade"
  site_mark "Omni reports the cluster ready and replicas span both workers"

  site_run_summarize "$t0"
  rehearsal_guide_status true
  log "upgrade run saved in $SITE_RUN_DIR"
}
