#!/usr/bin/env bash
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export FAKE="$WORK/fake"
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

EXPECTED_ENDPOINT=https://lab.example.invalid
SECRET_TOKEN=SECRETJOINTOKENVALUE0123456789abcdefghijkl

cat >"$FAKE_BIN/clusterctls" <<'EOF'
#!/usr/bin/env bash
[[ -f "$FAKE/clusterctls-fail" ]] && exit 1
printf "export OMNI_ENDPOINT='%s'\n" "$(<"$FAKE/endpoint")"
printf "export OMNI_SERVICE_ACCOUNT_KEY='fake'\n"
EOF

cat >"$FAKE_BIN/omnictl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/calls"
case "$*" in
  "get links -o json") key=links ;;
  "get machinestatusmetrics -o json") key=metrics ;;
  "get machinesetnodes -o json") key=nodes ;;
  "get jointokens -o json") key=tokens ;;
  "get jointokenstatuses -o json") key=tokenstatuses ;;
  "get installationmediaconfigs -o json") key=presets ;;
  "jointoken create"*)
    key=create
    if [[ ! -f "$FAKE/fail-create" ]]; then
      cp "$FAKE/tokens-created" "$FAKE/tokens"
      exit 0
    fi
    ;;
  "jointoken revoke"*) key=revoke ;;
  "jointoken delete"*)
    key=delete
    if [[ ! -f "$FAKE/fail-delete" ]]; then
      sed -i "/$3/d" "$FAKE/tokens"
      exit 0
    fi
    ;;
  "media preset create"*)
    key=presetcreate
    if [[ ! -f "$FAKE/fail-presetcreate" ]]; then
      cp "$FAKE/presets-created" "$FAKE/presets"
      exit 0
    fi
    ;;
  "media preset delete"*)
    key=presetdelete
    if [[ ! -f "$FAKE/fail-presetdelete" ]]; then
      sed -i "/\"id\":\"$4\"/d" "$FAKE/presets"
      exit 0
    fi
    ;;
  "get clusters -o json") key=clusters ;;
  "cluster delete"*)
    key=clusterdelete
    if [[ ! -f "$FAKE/fail-clusterdelete" ]]; then
      sed -i '/talos-lab/d' "$FAKE/clusters"
      if [[ -f "$FAKE/delete-changes-home" ]]; then
        sed -i '1d' "$FAKE/nodes"
      fi
      exit 0
    fi
    ;;
  "delete link "*)
    key=deletelink
    if [[ ! -f "$FAKE/fail-deletelink" ]]; then
      if [[ ! -f "$FAKE/links-survive" ]]; then
        sed -i "/$3/d" "$FAKE/links"
      fi
      exit 0
    fi
    ;;
  *) echo "unexpected omnictl call: $*" >&2; exit 64 ;;
esac
if [[ -f "$FAKE/fail-$key" ]]; then
  echo "boom while running: $*" >&2
  exit 1
fi
[[ -f "$FAKE/$key" ]] && cat "$FAKE/$key"
exit 0
EOF
cat >"$FAKE_BIN/cf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/cf-calls"
case "$*" in
  "tunnels list"*) cat "$FAKE/cf-tunnels" ;;
  "dns records list"*) cat "$FAKE/cf-dns" ;;
  "tunnels connections cleanup"*) exit 0 ;;
  "tunnels config update"*) exit 0 ;;
  "tunnels create"*)
    n="${4##*-}"
    uuid="$(printf '22222222-2222-4222-8222-%012d' "$((10#${n//[!0-9]/0}))")"
    jq -c --arg id "$uuid" --arg name "$4" '. + [{id: $id, name: $name, deleted_at: null}]' "$FAKE/cf-tunnels" >"$FAKE/cf-tunnels.new"
    mv "$FAKE/cf-tunnels.new" "$FAKE/cf-tunnels"
    if [[ -f "$FAKE/cf-create-changes-other" ]]; then
      jq -c 'map(select(.name != "home-tunnel"))' "$FAKE/cf-tunnels" >"$FAKE/cf-tunnels.new"
      mv "$FAKE/cf-tunnels.new" "$FAKE/cf-tunnels"
    fi
    ;;
  "dns records create"*)
    jq -c --argjson rec "$7" '. + [$rec + {id: ("rec-" + $rec.name)}]' "$FAKE/cf-dns" >"$FAKE/cf-dns.new"
    mv "$FAKE/cf-dns.new" "$FAKE/cf-dns"
    ;;
  "tunnels token get"*)
    if [[ -f "$FAKE/cf-token" ]]; then
      cat "$FAKE/cf-token"
    else
      echo "boom $*" >&2
      exit 1
    fi
    ;;
  "tunnels delete"*)
    if [[ -f "$FAKE/cf-delete-fail" ]]; then
      echo "tunnel has active connections" >&2
      exit 1
    fi
    jq -c --arg id "$3" 'map(select(.id != $id))' "$FAKE/cf-tunnels" >"$FAKE/cf-tunnels.new"
    mv "$FAKE/cf-tunnels.new" "$FAKE/cf-tunnels"
    if [[ -f "$FAKE/cf-delete-changes-other" ]]; then
      jq -c 'map(select(.name != "home-tunnel"))' "$FAKE/cf-tunnels" >"$FAKE/cf-tunnels.new"
      mv "$FAKE/cf-tunnels.new" "$FAKE/cf-tunnels"
    fi
    ;;
  "dns records delete"*)
    jq -c --arg id "$4" 'map(select(.id != $id))' "$FAKE/cf-dns" >"$FAKE/cf-dns.new"
    mv "$FAKE/cf-dns.new" "$FAKE/cf-dns"
    ;;
  *) echo "unexpected cf call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$FAKE_BIN/clusterctls" "$FAKE_BIN/omnictl" "$FAKE_BIN/cf"

other_id() { printf 'aaaaaaaa-0000-4000-8000-%012d' "$1"; }
LAB_A=1ab51de0-7a10-4000-8000-000000000001
LAB_B=1ab51de0-7a10-4000-8000-000000000002
LAB_C=1ab51de0-7a10-4000-8000-000000000003

write_links() {
  local id
  : >"$FAKE/links"
  for id in "$@"; do
    printf '{"metadata":{"type":"Links.omni.sidero.dev","id":"%s"},"spec":{"connected":true}}\n' "$id" >>"$FAKE/links"
  done
}

write_others() {
  local i ids=()
  for ((i = 1; i <= $1; i++)); do ids+=("$(other_id "$i")"); done
  shift
  write_links "${ids[@]}" "$@"
}

write_limit() {
  printf '{"metadata":{"type":"MachineStatusMetrics.omni.sidero.dev","id":"metrics"},"spec":{"registeredmachinescount":7,"registeredmachineslimit":%s}}\n' "$1" >"$FAKE/metrics"
}

write_nodes() {
  local i
  : >"$FAKE/nodes"
  for ((i = 1; i <= $1; i++)); do
    printf '{"metadata":{"type":"MachineSetNodes.omni.sidero.dev","id":"%s","labels":{"omni.sidero.dev/cluster":"home"}}}\n' "$(other_id "$i")" >>"$FAKE/nodes"
  done
}

token_doc() {
  printf '{"metadata":{"type":"JoinTokens.omni.sidero.dev","id":"%s"},"spec":{"name":"%s","revoked":%s}}\n' "$1" "$2" "$3"
}

reset_fake() {
  rm -rf "$FAKE" "$WORK/state"
  mkdir -p "$FAKE"
  printf '%s' "$EXPECTED_ENDPOINT" >"$FAKE/endpoint"
  : >"$FAKE/calls"
  write_others 7
  write_limit 10
  write_nodes 7
  {
    token_doc OTHERTOKENVALUEONE home-token false
    token_doc OTHERTOKENVALUETWO bare-metal false
  } >"$FAKE/tokens"
  {
    cat "$FAKE/tokens"
    token_doc "$SECRET_TOKEN" talos-lab false
  } >"$FAKE/tokens-created"
  printf '{"metadata":{"type":"JoinTokenStatuses.omni.sidero.dev","id":"x"},"spec":{"name":"talos-lab","isdefault":false}}\n' >"$FAKE/tokenstatuses"
  printf '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null}]\n' >"$FAKE/cf-tunnels"
  printf '[{"id":"other-rec","name":"other.zone.example","type":"A","content":"192.0.2.1"}]\n' >"$FAKE/cf-dns"
  : >"$FAKE/cf-calls"
  printf '{"metadata":{"type":"Clusters.omni.sidero.dev","id":"home"}}\n' >"$FAKE/clusters"
  printf '{"data":[{"vmid":100,"name":"unrelated","status":"running"},{"vmid":9101,"name":"talos-lab-cp","status":"running"},{"vmid":9102,"name":"talos-lab-worker-a","status":"running"},{"vmid":9103,"name":"talos-lab-worker-b","status":"running"}]}\n' >"$FAKE/pve-vms"
  : >"$FAKE/pve-calls"
  printf '{"metadata":{"type":"InstallationMediaConfigs.omni.sidero.dev","id":"other-preset"},"spec":{"jointoken":"OTHERTOKENVALUEONE"}}\n' >"$FAKE/presets"
  {
    cat "$FAKE/presets"
    printf '{"metadata":{"type":"InstallationMediaConfigs.omni.sidero.dev","id":"talos-lab"},"spec":{"jointoken":"%s"}}\n' "$SECRET_TOKEN"
  } >"$FAKE/presets-created"
}

load_libs() {
  source "$LAB_ROOT/lib/common.sh"
  source "$LAB_ROOT/lib/omni.sh"
  source "$LAB_ROOT/lib/pve-api.sh"
  source "$LAB_ROOT/lib/cap.sh"
  source "$LAB_ROOT/lib/machines-layer.sh"
  source "$LAB_ROOT/lib/site-layer.sh"
  source "$LAB_ROOT/lib/tunnel-layer.sh"
  source "$LAB_ROOT/lib/failover-layer.sh"
  source "$LAB_ROOT/lib/students-layer.sh"
  CF_CONFIGURED_HOSTNAME=lab.zone.example
  LAB_STATE="$WORK/state"
  mkdir -p "$LAB_STATE"
  LAB_CONFIG="$WORK/lab.env"
  printf 'LAB_OMNI_PROFILE=fake\nLAB_OMNI_ENDPOINT=%s\nLAB_OMNI_PROTECTED_CLUSTER=home\nLAB_CF_ACCOUNT_ID=acct\nLAB_TUNNEL_ZONE=zone.example\nLAB_TUNNEL_HOSTNAME=lab.zone.example\n' "$EXPECTED_ENDPOINT" >"$LAB_CONFIG"
  LAB_CF_ACCOUNT_ID=acct
  LAB_TUNNEL_ZONE=zone.example
  LAB_TUNNEL_HOSTNAME=lab.zone.example
  LAB_TUNNEL_DELETE_ATTEMPTS=2
  LAB_TUNNEL_DELETE_DELAY=0
  LAB_PVE_TARGET="$WORK/pve-target.env"
  printf 'PVE_URL=https://x\nPVE_NODE=pve\nPVE_TOKEN_ID=t\nPVE_TOKEN_SECRET=s\nPVE_TLS_PIN=p\nPVE_ISO_STORAGE=local\nPVE_DISK_STORAGE=local-lvm\nPVE_BRIDGE=vmbr0\n' >"$LAB_PVE_TARGET"
  pve_api() {
    printf '%s %s\n' "$1" "$2" >>"$FAKE/pve-calls"
    case "$1 $2" in
      "GET /nodes/pve/qemu") cat "$FAKE/pve-vms" ;;
      GET\ */tasks/*) printf '{"data":{"status":"stopped","exitstatus":"OK"}}\n' ;;
      GET\ */content*) printf '{"data":[]}\n' ;;
      POST\ */status/stop)
        sed -i '/1ab51de0/s/"connected":true/"connected":false/' "$FAKE/links"
        printf '{"data":"UPID:fake"}\n'
        ;;
      DELETE\ */qemu/*)
        local vmid="${2##*/qemu/}"
        vmid="${vmid%%\?*}"
        jq -c --argjson id "$vmid" '.data |= map(select(.vmid != $id))' "$FAKE/pve-vms" >"$FAKE/pve-vms.new"
        mv "$FAKE/pve-vms.new" "$FAKE/pve-vms"
        printf '{"data":"UPID:fake"}\n'
        ;;
      *) printf '{"data":"UPID:fake"}\n' ;;
    esac
  }
  LAB_OMNI_PROFILE=fake
  LAB_OMNI_ENDPOINT="$EXPECTED_ENDPOINT"
  LAB_OMNI_PROTECTED_CLUSTER=home
  LAB_WATCHDOG_INTERVAL=0.05
  LAB_REGISTER_POLL=0.05
  LAB_REGISTER_TIMEOUT=2
  LAB_VM_STOP_FN=fake_vm_stop
  LAB_VM_START_FN=fake_vm_start
}

fake_vm_stop() { printf 'stopped\n' >>"$FAKE/vm-events"; }
fake_vm_start() {
  printf 'start %s\n' "$1" >>"$FAKE/vm-events"
  case "$1" in
    9101) write_others 7 "$LAB_A" ;;
    9102) write_others 7 "$LAB_A" "$LAB_B" ;;
    9103) write_others 7 "$LAB_A" "$LAB_B" "$LAB_C" ;;
  esac
}

assert_no_secret() { ! grep -qF "$SECRET_TOKEN" "$WORK/out"; }
assert_no_mutation() { ! grep -qE '^(jointoken|media) ' "$FAKE/calls"; }
assert_out() { grep -qF -- "$1" "$WORK/out"; }

test_structure_has_exactly_three_distinct_machines() {
  ((${#LAB_MACHINE_IDS[@]} == 3 && ${#LAB_VM_IDS[@]} == 3 && ${#LAB_VM_NAMES[@]} == 3)) || return 1
  [[ "$(printf '%s\n' "${LAB_MACHINE_IDS[@]}" | sort -u | wc -l)" == 3 ]]
}
test_gate_passes_at_exactly_the_cap() { cap_gate; }
test_gate_excludes_lab_links_from_others() { write_others 7 "$LAB_A" "$LAB_B" "$LAB_C"; cap_gate; }
test_gate_refuses_eight_others() { write_others 8; write_nodes 7; ! cap_gate; }
test_gate_uses_lower_account_limit() { write_limit 9; ! cap_gate; }
test_gate_clamps_higher_limit_to_ten() { write_limit 50; write_others 8; ! cap_gate; }
test_gate_passes_with_room_under_limit() { write_others 5; write_nodes 5; cap_gate; }
test_gate_aborts_on_links_query_failure() { touch "$FAKE/fail-links"; ! cap_gate; }
test_gate_aborts_on_metrics_query_failure() { touch "$FAKE/fail-metrics"; ! cap_gate; }
test_gate_aborts_on_nodes_query_failure() { touch "$FAKE/fail-nodes"; ! cap_gate; }
test_gate_aborts_on_malformed_links() { printf 'not json\n' >"$FAKE/links"; ! cap_gate; }
test_gate_aborts_on_wrong_link_type() { printf '{"metadata":{"type":"Other","id":"%s"}}\n' "$(other_id 1)" >"$FAKE/links"; ! cap_gate; }
test_gate_aborts_on_non_uuid_link() { printf '{"metadata":{"type":"Links.omni.sidero.dev","id":"nope"}}\n' >"$FAKE/links"; ! cap_gate; }
test_gate_aborts_on_missing_limit() { printf '{"metadata":{"type":"MachineStatusMetrics.omni.sidero.dev","id":"m"},"spec":{}}\n' >"$FAKE/metrics"; ! cap_gate; }
test_gate_aborts_on_zero_limit() { write_limit 0; ! cap_gate; }
test_gate_aborts_on_fractional_limit() { write_limit 9.5; ! cap_gate; }
test_gate_aborts_on_empty_links_with_protected_cluster() { : >"$FAKE/links"; ! cap_gate; }
test_gate_aborts_when_protected_machine_missing_from_links() { write_others 6; ! cap_gate; }
test_gate_aborts_on_empty_protected_cluster() { : >"$FAKE/nodes"; ! cap_gate; }
test_gate_allows_empty_account_without_protected_cluster() { LAB_OMNI_PROTECTED_CLUSTER=; : >"$FAKE/links"; cap_gate; }

test_endpoint_mismatch_never_reaches_omnictl() {
  printf 'https://other-account.example.invalid' >"$FAKE/endpoint"
  ! cap_gate || return 1
  [[ ! -s "$FAKE/calls" ]]
}
test_empty_configured_endpoint_is_refused() {
  LAB_OMNI_ENDPOINT=
  : >"$FAKE/endpoint"
  ! cap_gate || return 1
  [[ ! -s "$FAKE/calls" ]]
}
test_profile_load_failure_never_reaches_omnictl() {
  touch "$FAKE/clusterctls-fail"
  ! cap_gate || return 1
  [[ ! -s "$FAKE/calls" ]]
}

test_preset_refuses_empty_token() { ! cap_preset_create "" 1.14.5 || return 1; assert_no_mutation; }
test_preset_refuses_whitespace_token() { ! cap_preset_create "   " 1.14.5 || return 1; assert_no_mutation; }
test_preset_refuses_missing_arguments() { ! cap_preset_create || return 1; assert_no_mutation; }
test_preset_passes_token_flag() {
  cap_preset_create "$SECRET_TOKEN" 1.14.5 siderolabs/qemu-guest-agent || return 1
  grep -qF -- "--join-token $SECRET_TOKEN" "$FAKE/calls" && grep -qF -- 'media preset create talos-lab' "$FAKE/calls"
}
test_preset_mismatch_is_deleted_and_fails() {
  sed -i "s/$SECRET_TOKEN/DIFFERENT/" "$FAKE/presets-created"
  ! cap_preset_create "$SECRET_TOKEN" 1.14.5 || return 1
  grep -qF 'media preset delete talos-lab' "$FAKE/calls"
}
test_preset_failure_does_not_print_token() { touch "$FAKE/fail-presetcreate"; ! cap_preset_create "$SECRET_TOKEN" 1.14.5; }
test_preset_delete_never_touches_other_presets() {
  cp "$FAKE/presets-created" "$FAKE/presets"
  cap_preset_delete || return 1
  ! grep -qF 'other-preset' "$FAKE/calls"
}

test_token_create_finds_lab_token() { cap_token_create; }
test_token_create_refuses_default_token() {
  printf '{"metadata":{"id":"x"},"spec":{"name":"talos-lab","isdefault":true}}\n' >"$FAKE/tokenstatuses"
  ! cap_token_create
}
test_token_revoke_touches_only_lab_token() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  cap_token_revoke || return 1
  [[ "$(grep -c '^jointoken revoke' "$FAKE/calls")" == 1 ]] || return 1
  grep -qF "jointoken revoke $SECRET_TOKEN" "$FAKE/calls" && ! grep -qF OTHERTOKENVALUE "$FAKE/calls"
}
test_token_revoke_without_force_by_default() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  cap_token_revoke || return 1
  ! grep -qF -- '--force' "$FAKE/calls"
}
test_token_revoke_skips_already_revoked() {
  { token_doc OTHERTOKENVALUEONE home-token false; token_doc "$SECRET_TOKEN" talos-lab true; } >"$FAKE/tokens"
  cap_token_revoke || return 1
  ! grep -q '^jointoken revoke' "$FAKE/calls"
}
test_token_delete_touches_only_lab_token() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  cap_token_delete || return 1
  ! grep -qF OTHERTOKENVALUE "$FAKE/calls"
}
test_token_revoke_failure_does_not_print_token() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  touch "$FAKE/fail-revoke"
  ! cap_token_revoke || return 1
  assert_out '<join-token>'
}
test_token_listing_error_does_not_print_token() {
  printf '{"metadata":{"type":"Wrong","id":"%s"},"spec":{"name":"talos-lab"}}\n' "$SECRET_TOKEN" >"$FAKE/tokens"
  ! cap_token_ids
}

test_lock_refuses_second_run() {
  lab_lock first
  ! (lab_lock second) 2>"$WORK/lock-err" || return 1
  grep -qF 'command=first' "$WORK/lock-err"
}

run_watchdog() {
  cap_watchdog_snapshot || return 1
  "$@"
  cap_watchdog_loop &
  local loop=$! deadline=$((SECONDS + 5))
  while kill -0 "$loop" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill "$loop"
      wait "$loop" 2>/dev/null
      return 1
    fi
    sleep 0.05
  done
  wait "$loop"
  [[ -f "$LAB_STATE/watchdog-tripped" ]]
}

test_watchdog_trips_on_unknown_machine() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  run_watchdog write_others 8 || return 1
  grep -qF stopped "$FAKE/vm-events" && grep -qF "jointoken revoke $SECRET_TOKEN --force" "$FAKE/calls"
}
test_watchdog_trips_past_the_cap() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  write_others 8
  write_limit 10
  run_watchdog write_others 8 "$LAB_A" "$LAB_B" "$LAB_C" || return 1
  grep -qF 'passed cap' "$LAB_STATE/watchdog-tripped" && grep -qF stopped "$FAKE/vm-events"
}
test_watchdog_trips_after_repeated_query_failures() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  run_watchdog touch "$FAKE/fail-links" || return 1
  grep -qF stopped "$FAKE/vm-events"
}
test_watchdog_trips_when_parent_run_dies() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  sleep 0 &
  local dead=$!
  wait "$dead"
  LAB_WATCHDOG_PARENT_PID="$dead"
  run_watchdog true || return 1
  grep -qF "exited without stopping" "$LAB_STATE/watchdog-tripped" && grep -qF stopped "$FAKE/vm-events"
}
test_watchdog_tolerates_lab_machines() {
  cap_watchdog_snapshot || return 1
  write_others 7 "$LAB_A" "$LAB_B" "$LAB_C"
  local status=0
  cap_watchdog_evaluate || status=$?
  ((status == 0))
}
test_watchdog_failed_query_is_distinct_from_trip() {
  cap_watchdog_snapshot || return 1
  touch "$FAKE/fail-links"
  local status=0
  cap_watchdog_evaluate || status=$?
  ((status == 2))
}
test_watchdog_stops_vms_even_if_revoke_fails() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  touch "$FAKE/fail-revoke"
  ! cap_trip "reason" || return 1
  grep -qF stopped "$FAKE/vm-events"
}
test_watchdog_revokes_even_if_stop_fails() {
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  LAB_VM_STOP_FN=false
  ! cap_trip "reason" || return 1
  grep -qF 'jointoken revoke' "$FAKE/calls"
}

test_boot_starts_three_in_order_with_a_gate_each() {
  cap_watchdog_snapshot || return 1
  cap_guarded_boot || return 1
  [[ "$(cat "$FAKE/vm-events")" == $'start 9101\nstart 9102\nstart 9103' ]] || return 1
  (("$(grep -c 'get machinestatusmetrics' "$FAKE/calls")" >= 3))
}
test_boot_stops_when_gate_fails_midway() {
  fake_vm_start() {
    printf 'start %s\n' "$1" >>"$FAKE/vm-events"
    write_others 8 "$LAB_A"
  }
  ! cap_guarded_boot || return 1
  [[ "$(cat "$FAKE/vm-events")" == 'start 9101' ]]
}
test_boot_refuses_after_trip() {
  printf 'x\n' >"$LAB_STATE/watchdog-tripped"
  ! cap_guarded_boot || return 1
  [[ ! -f "$FAKE/vm-events" ]]
}
test_boot_aborts_wait_when_watchdog_trips() {
  fake_vm_start() {
    printf 'start %s\n' "$1" >>"$FAKE/vm-events"
    printf 'tripped\n' >"$LAB_STATE/watchdog-tripped"
  }
  ! cap_guarded_boot || return 1
  [[ "$(cat "$FAKE/vm-events")" == 'start 9101' ]]
}

assert_allowed() { omni_assert_allowed "$@" 2>/dev/null; }
assert_refused() { ! omni_assert_allowed "$@" 2>/dev/null; }

test_allowlist_permits_lab_operations() {
  assert_allowed get links -o json &&
    assert_allowed jointoken create talos-lab --ttl 1h &&
    assert_allowed jointoken revoke someid &&
    assert_allowed jointoken delete someid --force &&
    assert_allowed media preset create talos-lab --arch amd64 &&
    assert_allowed media preset delete talos-lab &&
    assert_allowed media download talos-lab --output /tmp/ &&
    assert_allowed cluster template validate -f "$(lab_cluster_template)" &&
    assert_allowed cluster template sync -f "$(lab_cluster_template)" &&
    assert_allowed cluster delete talos-lab --destroy-disconnected-machines &&
    assert_allowed delete link "$LAB_A" &&
    assert_allowed kubeconfig /tmp/k --cluster talos-lab --service-account
}
test_allowlist_refuses_home_cluster_delete() { assert_refused cluster delete talos-default; }
test_allowlist_refuses_nameless_cluster_delete() { assert_refused cluster delete; }
test_allowlist_refuses_other_link_delete() { assert_refused delete link "$(other_id 1)"; }
test_allowlist_refuses_nameless_link_delete() { assert_refused delete link; }
test_allowlist_refuses_all_links_delete() { assert_refused delete link --all; }
test_allowlist_refuses_generic_cluster_delete() { assert_refused delete cluster talos-default; }
test_allowlist_refuses_generic_lab_cluster_delete() { assert_refused delete clusters talos-lab; }
test_allowlist_refuses_other_preset_delete() { assert_refused media preset delete other-preset; }
test_allowlist_refuses_other_preset_create() { assert_refused media preset create other-preset; }
test_allowlist_refuses_other_download() { assert_refused media download other-preset; }
test_allowlist_refuses_other_token_create() { assert_refused jointoken create other; }
test_allowlist_refuses_make_default() { assert_refused jointoken make-default someid; }
test_allowlist_refuses_nameless_revoke() { assert_refused jointoken revoke; }
test_allowlist_refuses_other_template_file() { assert_refused cluster template sync -f /elsewhere.yaml; }
test_allowlist_refuses_template_delete() { assert_refused cluster template delete -f "$(lab_cluster_template)"; }
test_allowlist_refuses_home_kubeconfig() { assert_refused kubeconfig /tmp/k --cluster talos-default; }
test_allowlist_refuses_clusterless_kubeconfig() { assert_refused kubeconfig /tmp/k; }
test_allowlist_refuses_serviceaccount_destroy() { assert_refused serviceaccount destroy some-account; }
test_allowlist_refuses_apply() { assert_refused apply -f x; }
test_allowlist_refuses_no_arguments() { assert_refused; }
test_refused_call_never_reaches_omnictl() {
  ! omni_run cluster delete talos-default || return 1
  [[ ! -s "$FAKE/calls" ]]
}

test_template_names_only_the_lab_machines() {
  local path
  cluster_render_template
  path="$(lab_cluster_template)"
  [[ "$(grep -c '^name: talos-lab$' "$path")" == 1 ]] || return 1
  [[ "$(grep -c '^kind: Machine$' "$path")" == 3 ]] || return 1
  grep -qE '^  - 1ab51de0-7a10-4000-8000-000000000001$' "$path" || return 1
  [[ "$(grep -c 'aaaaaaaa\|talos-default' "$path")" == 0 ]]
}

test_vm_guard_refuses_non_lab_id() { ! pve_lab_vm_name 100; }
test_vm_guard_refuses_foreign_name_on_lab_id() {
  sed -i 's/talos-lab-worker-a/someone-else/' "$FAKE/pve-vms"
  pve_load_target || return 1
  ! pve_lab_vm_state 9102
}
test_vm_stop_skips_foreign_name_on_lab_id() {
  sed -i 's/talos-lab-worker-a/someone-else/' "$FAKE/pve-vms"
  ! pve_stop_lab_vms || return 1
  ! grep -q 'POST .*/9102/' "$FAKE/pve-calls"
}
test_vm_stop_leaves_unrelated_vm_alone() {
  pve_stop_lab_vms || return 1
  ! grep -q 'POST .*/100/' "$FAKE/pve-calls"
}
test_vm_start_refuses_foreign_name() {
  sed -i 's/talos-lab-cp/someone-else/' "$FAKE/pve-vms"
  ! pve_start_lab_vm 9101 || return 1
  ! grep -q '^POST' "$FAKE/pve-calls"
}

setup_reset() {
  write_others 7 "$LAB_A" "$LAB_B" "$LAB_C"
  printf '{"metadata":{"type":"Clusters.omni.sidero.dev","id":"talos-lab"}}\n' >>"$FAKE/clusters"
  cp "$FAKE/tokens-created" "$FAKE/tokens"
  cp "$FAKE/presets-created" "$FAKE/presets"
}

test_reset_removes_only_lab_resources() {
  setup_reset
  (lab_reset) || return 1
  grep -qxF "cluster delete talos-lab" "$FAKE/calls" || return 1
  [[ "$(grep -c '^delete link ' "$FAKE/calls")" == 3 ]] || return 1
  ! grep -q '^delete link aaaaaaaa' "$FAKE/calls" || return 1
  [[ "$(grep -c '^DELETE .*/qemu/' "$FAKE/pve-calls")" == 3 ]] || return 1
  ! grep -q 'qemu/100' "$FAKE/pve-calls" || return 1
  ! grep -qE 'OTHERTOKENVALUE|other-preset' "$FAKE/calls"
}
test_reset_starts_cluster_teardown_before_removing_links_workers_first() {
  setup_reset
  (lab_reset) || return 1
  local order
  order="$(grep -E "^(cluster delete|delete link)" "$FAKE/calls")"
  [[ "$order" == $'cluster delete talos-lab\ndelete link 1ab51de0-7a10-4000-8000-000000000003\ndelete link 1ab51de0-7a10-4000-8000-000000000002\ndelete link 1ab51de0-7a10-4000-8000-000000000001' ]]
}
test_reset_removes_links_when_cluster_is_already_gone() {
  setup_reset
  sed -i '/talos-lab/d' "$FAKE/clusters"
  (lab_reset) || return 1
  [[ "$(grep -c '^delete link ' "$FAKE/calls")" == 3 ]] && ! grep -q '^cluster delete' "$FAKE/calls"
}
test_omni_call_times_out_with_a_clear_error() {
  mkdir -p "$WORK/slow-bin"
  printf '#!/usr/bin/env bash\nsleep 30\n' >"$WORK/slow-bin/omnictl"
  chmod +x "$WORK/slow-bin/omnictl"
  PATH="$WORK/slow-bin:$PATH"
  LAB_OMNI_TIMEOUT=1
  ! omni_query get links -o json || return 1
  assert_out 'timed out after 1s'
}
test_reset_stops_vms_before_deleting_the_cluster() {
  setup_reset
  (lab_reset) || return 1
  [[ "$(grep -c 'status/stop' "$FAKE/pve-calls")" == 3 ]] || return 1
  [[ "$(grep -c '1ab51de0' "$FAKE/links")" == 0 ]]
}
test_reset_aborts_without_protected_baseline() {
  setup_reset
  touch "$FAKE/fail-nodes"
  ! (lab_reset) || return 1
  ! grep -qE '^(cluster delete|delete link)' "$FAKE/calls" || return 1
  ! grep -q 'status/stop' "$FAKE/pve-calls"
}
test_reset_detects_protected_membership_change() {
  setup_reset
  touch "$FAKE/delete-changes-home"
  ! (lab_reset)
}
test_reset_refuses_foreign_vm_name_before_mutating() {
  setup_reset
  sed -i 's/talos-lab-worker-b/someone-else/' "$FAKE/pve-vms"
  ! (lab_reset) || return 1
  ! grep -qE '^(cluster delete|delete link)' "$FAKE/calls" || return 1
  ! grep -q '^POST' "$FAKE/pve-calls"
}
test_reset_reports_surviving_links() {
  setup_reset
  touch "$FAKE/links-survive"
  ! (lab_reset) || return 1
  assert_out 'reset left resources behind'
}
test_reset_succeeds_when_nothing_exists() {
  printf '{"data":[{"vmid":100,"name":"unrelated","status":"running"}]}\n' >"$FAKE/pve-vms"
  (lab_reset) || return 1
  ! grep -qE '^(cluster delete|delete link)' "$FAKE/calls"
}
test_reset_never_prints_lab_token() {
  setup_reset
  touch "$FAKE/fail-delete"
  ! (lab_reset)
}

LAB_TUNNEL_UUID=11111111-1111-4111-8111-111111111111
LONG_CONNECTOR_TOKEN="$(printf 'c%.0s' {1..140})"

setup_tunnel() {
  printf '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null},{"id":"%s","name":"talos-lab","deleted_at":null}]\n' "$LAB_TUNNEL_UUID" >"$FAKE/cf-tunnels"
  printf '[{"id":"other-rec","name":"other.zone.example","type":"A","content":"192.0.2.1"},{"id":"lab-rec","name":"lab.zone.example","type":"CNAME","content":"%s.cfargotunnel.com"}]\n' "$LAB_TUNNEL_UUID" >"$FAKE/cf-dns"
}

cf_allowed() { cf_assert_allowed "$@" 2>/dev/null; }
cf_refused() { ! cf_assert_allowed "$@" 2>/dev/null; }

test_cf_allowlist_permits_lab_operations() {
  CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"
  CF_LAB_DNS_RECORD_ID=lab-rec
  cf_allowed tunnels list --name talos-lab --is-deleted false &&
    cf_allowed tunnels create --name talos-lab --config-source cloudflare &&
    cf_allowed tunnels token get "$LAB_TUNNEL_UUID" &&
    cf_allowed tunnels config update "$LAB_TUNNEL_UUID" --tunnel-config-ingress @f &&
    cf_allowed tunnels connections cleanup "$LAB_TUNNEL_UUID" &&
    cf_allowed tunnels delete "$LAB_TUNNEL_UUID" --force &&
    cf_allowed dns records list -z zone.example --name-exact lab.zone.example &&
    cf_allowed dns records create -z zone.example --body '{"name":"lab.zone.example","type":"CNAME"}' &&
    cf_allowed dns records delete lab-rec -z zone.example --force
}
test_cf_allowlist_refuses_deleting_other_tunnel() { CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"; cf_refused tunnels delete home-tunnel-id --force; }
test_cf_allowlist_refuses_delete_before_lookup() { cf_refused tunnels delete "$LAB_TUNNEL_UUID" --force; }
test_cf_allowlist_refuses_other_tunnel_token() { CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"; cf_refused tunnels token get home-tunnel-id; }
test_cf_allowlist_refuses_other_tunnel_config() { CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"; cf_refused tunnels config update home-tunnel-id; }
test_cf_allowlist_refuses_other_tunnel_name() { cf_refused tunnels create --name home-tunnel --config-source cloudflare; }
test_cf_allowlist_refuses_other_zone_list() { cf_refused dns records list -z other.example; }
test_cf_allowlist_refuses_other_zone_create() { cf_refused dns records create -z other.example --body '{"name":"lab.zone.example","type":"CNAME"}'; }
test_cf_allowlist_refuses_other_hostname_create() { cf_refused dns records create -z zone.example --body '{"name":"www.zone.example","type":"CNAME"}'; }
test_cf_allowlist_refuses_non_cname_create() { cf_refused dns records create -z zone.example --body '{"name":"lab.zone.example","type":"A"}'; }
test_cf_allowlist_refuses_other_record_delete() { CF_LAB_DNS_RECORD_ID=lab-rec; cf_refused dns records delete other-rec -z zone.example --force; }
test_cf_allowlist_refuses_record_delete_before_lookup() { cf_refused dns records delete lab-rec -z zone.example --force; }
test_cf_allowlist_refuses_zone_operations() { cf_refused zones delete zone.example; }
test_cf_allowlist_refuses_no_arguments() { cf_refused; }
test_cf_refused_call_never_reaches_cf() {
  CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"
  ! cf_query tunnels delete home-tunnel-id --force || return 1
  [[ ! -s "$FAKE/cf-calls" ]]
}

test_endpoint_count_ignores_endpoints_marked_not_ready() {
  lab_kubectl() { printf '%s\n' '{"items":[{"endpoints":[{"nodeName":"dead","conditions":{"ready":false}},{"nodeName":"alive","conditions":{"ready":true}}]}]}'; }
  [[ "$(failover_ready_endpoints_on dead)" == 0 && "$(failover_ready_endpoints_on alive)" == 1 ]]
}
test_endpoint_count_treats_unset_ready_as_ready() {
  lab_kubectl() { printf '%s\n' '{"items":[{"endpoints":[{"nodeName":"node","conditions":{}}]}]}'; }
  [[ "$(failover_ready_endpoints_on node)" == 1 ]]
}

write_student_token() { printf '"%s"\n' "$LONG_CONNECTOR_TOKEN" >"$FAKE/cf-token"; }

test_students_create_makes_one_tunnel_and_record_each() {
  write_student_token
  (students_create 3) || return 1
  [[ "$(jq -r '[.[].name | select(startswith("talos-student-"))] | length' "$FAKE/cf-tunnels")" == 3 ]] || return 1
  [[ "$(jq -r '[.[].name | select(startswith("team"))] | length' "$FAKE/cf-dns")" == 3 ]] || return 1
  [[ "$(jq -r '[.[] | select(.name == "team03.zone.example")] | length' "$FAKE/cf-dns")" == 1 ]] || return 1
  [[ "$(cat "$LAB_STATE/students/team03.token")" == "$LONG_CONNECTOR_TOKEN" ]] || return 1
  ! grep -qF "$LONG_CONNECTOR_TOKEN" "$WORK/out"
}
test_students_create_is_idempotent() {
  write_student_token
  (students_create 2) || return 1
  (students_create 2) || return 1
  [[ "$(grep -c '^tunnels create' "$FAKE/cf-calls")" == 2 ]] || return 1
  [[ "$(grep -c '^dns records create' "$FAKE/cf-calls")" == 2 ]]
}
test_students_create_refuses_bad_counts() {
  write_student_token
  ! (students_create 0) || return 1
  ! (students_create 21) || return 1
  ! (students_create abc) || return 1
  ! (students_create) || return 1
  ! grep -qE '^(tunnels create|dns records create)' "$FAKE/cf-calls"
}
test_students_create_detects_other_resources_changing() {
  write_student_token
  touch "$FAKE/cf-create-changes-other"
  ! (students_create 1) || return 1
  assert_out 'other Cloudflare resources changed'
}

seed_students() {
  printf '%s\n' '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null},{"id":"lab-id","name":"talos-lab","deleted_at":null},{"id":"decoy-id","name":"talos-student-x","deleted_at":null},{"id":"33333333-3333-4333-8333-000000000001","name":"talos-student-01","deleted_at":null},{"id":"33333333-3333-4333-8333-000000000008","name":"talos-student-08","deleted_at":null}]' >"$FAKE/cf-tunnels"
  printf '%s\n' '[{"id":"other-rec","name":"other.zone.example","type":"A","content":"192.0.2.1"},{"id":"lab-rec","name":"lab.zone.example","type":"CNAME","content":"44444444-4444-4444-8444-000000000000.cfargotunnel.com"},{"id":"decoy-rec","name":"teamwork.zone.example","type":"A","content":"192.0.2.2"},{"id":"rec-1","name":"team01.zone.example","type":"CNAME","content":"33333333-3333-4333-8333-000000000001.cfargotunnel.com"},{"id":"rec-8","name":"team08.zone.example","type":"CNAME","content":"33333333-3333-4333-8333-000000000008.cfargotunnel.com"}]' >"$FAKE/cf-dns"
}

test_students_delete_removes_only_student_resources() {
  seed_students
  (students_delete) || return 1
  [[ "$(jq -c '[.[].name] | sort' "$FAKE/cf-tunnels")" == '["home-tunnel","talos-lab","talos-student-x"]' ]] || return 1
  [[ "$(jq -c '[.[].name] | sort' "$FAKE/cf-dns")" == '["lab.zone.example","other.zone.example","teamwork.zone.example"]' ]]
}
test_students_delete_refuses_a_non_tunnel_record_on_a_team_name() {
  seed_students
  jq -c 'map(if .name == "team01.zone.example" then .type = "A" | .content = "192.0.2.9" else . end)' "$FAKE/cf-dns" >"$FAKE/cf-dns.new"
  mv "$FAKE/cf-dns.new" "$FAKE/cf-dns"
  ! (students_delete) || return 1
  ! grep -q '^dns records delete rec-1' "$FAKE/cf-calls"
}
test_students_delete_detects_other_resources_changing() {
  seed_students
  touch "$FAKE/cf-delete-changes-other"
  ! (students_delete) || return 1
  assert_out 'other Cloudflare resources changed'
}
test_students_delete_is_a_noop_when_nothing_exists() {
  (students_delete) || return 1
  ! grep -q ' delete ' "$FAKE/cf-calls"
}
test_student_numbers_with_leading_zeros_are_decimal() {
  [[ "$(student_token_path 08)" == *'/team08.token' && "$(student_token_path 7)" == *'/team07.token' ]]
}

test_cf_allowlist_permits_student_tunnel_when_current() {
  LAB_TUNNEL_NAME=talos-student-07
  LAB_TUNNEL_HOSTNAME=team07.zone.example
  cf_allowed tunnels create --name talos-student-07 --config-source cloudflare &&
    cf_allowed dns records create -z zone.example --body '{"name":"team07.zone.example","type":"CNAME"}'
}
test_cf_allowlist_refuses_malformed_student_name() {
  LAB_TUNNEL_NAME=talos-student-7
  cf_refused tunnels create --name talos-student-7 --config-source cloudflare
}
test_cf_allowlist_refuses_home_tunnel_name_even_when_current() {
  LAB_TUNNEL_NAME=home-tunnel
  cf_refused tunnels create --name home-tunnel --config-source cloudflare
}
test_cf_allowlist_refuses_unowned_hostname_even_when_current() {
  LAB_TUNNEL_HOSTNAME=www.zone.example
  cf_refused dns records create -z zone.example --body '{"name":"www.zone.example","type":"CNAME"}'
}
test_cf_allowlist_refuses_team_hostname_in_other_zone() {
  LAB_TUNNEL_HOSTNAME=team01.other.example
  cf_refused dns records create -z zone.example --body '{"name":"team01.other.example","type":"CNAME"}'
}

test_failover_waits_after_a_recent_pod_start() {
  local stamp begin
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lab_kubectl() { printf '{"items":[{"status":{"startTime":"2020-01-01T00:00:00Z"}},{"status":{"startTime":"%s"}}]}\n' "$stamp"; }
  FAILOVER_IMAGE_SETTLE_SECONDS=2
  begin=$SECONDS
  failover_wait_images_settled || return 1
  ((SECONDS - begin >= 1))
}
test_failover_does_not_wait_for_old_pods() {
  local begin
  lab_kubectl() { printf '%s\n' '{"items":[{"status":{"startTime":"2020-01-01T00:00:00Z"}}]}'; }
  FAILOVER_IMAGE_SETTLE_SECONDS=30
  begin=$SECONDS
  failover_wait_images_settled || return 1
  ((SECONDS - begin < 5))
}
test_failover_settle_fails_when_pods_are_unreadable() {
  lab_kubectl() { return 1; }
  ! failover_wait_images_settled
}
test_failover_settle_fails_with_no_pods() {
  lab_kubectl() { printf '%s\n' '{"items":[]}'; }
  ! failover_wait_images_settled
}

test_failover_targets_only_workers() {
  [[ "$(failover_worker_index worker-a)" == 1 && "$(failover_worker_index worker-b)" == 2 ]] || return 1
  ! failover_worker_index control-plane
}

test_hostname_must_be_one_level_below_zone() {
  LAB_TUNNEL_HOSTNAME=a.b.zone.example
  ! (cf_load_config)
}
test_hostname_must_be_inside_zone() {
  LAB_TUNNEL_HOSTNAME=lab.other.example
  ! (cf_load_config)
}

test_tunnel_down_removes_only_lab_tunnel_and_record() {
  setup_tunnel
  (tunnel_down) || return 1
  [[ "$(jq -r '.[].name' "$FAKE/cf-tunnels")" == home-tunnel ]] || return 1
  [[ "$(jq -r '.[].name' "$FAKE/cf-dns")" == other.zone.example ]] || return 1
  [[ "$(grep -c '^tunnels delete ' "$FAKE/cf-calls")" == 1 ]] || return 1
  [[ "$(grep -c '^dns records delete ' "$FAKE/cf-calls")" == 1 ]] || return 1
  ! grep -qE 'delete (home-tunnel-id|other-rec)' "$FAKE/cf-calls"
}
test_tunnel_down_is_a_noop_when_nothing_exists() {
  (tunnel_down) || return 1
  ! grep -q ' delete ' "$FAKE/cf-calls"
}
test_tunnel_down_refuses_a_non_tunnel_record_on_the_hostname() {
  setup_tunnel
  printf '[{"id":"lab-rec","name":"lab.zone.example","type":"A","content":"192.0.2.9"}]\n' >"$FAKE/cf-dns"
  ! (tunnel_down) || return 1
  ! grep -q ' delete ' "$FAKE/cf-calls"
}
test_tunnel_down_detects_other_resources_changing() {
  setup_tunnel
  touch "$FAKE/cf-delete-changes-other"
  ! (tunnel_down) || return 1
  assert_out 'other Cloudflare resources changed'
}
test_tunnel_down_fails_when_delete_keeps_failing() {
  setup_tunnel
  touch "$FAKE/cf-delete-fail"
  ! (tunnel_down)
}
test_reset_removes_the_lab_tunnel_and_keeps_the_home_tunnel() {
  setup_reset
  setup_tunnel
  (lab_reset) || return 1
  [[ "$(jq -r '.[].name' "$FAKE/cf-tunnels")" == home-tunnel ]]
}

test_connector_token_is_stored_but_never_printed() {
  setup_tunnel
  CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"
  printf '"%s"\n' "$LONG_CONNECTOR_TOKEN" >"$FAKE/cf-token"
  (tunnel_store_connector_token) || return 1
  [[ "$(cat "$(lab_tunnel_token_file)")" == "$LONG_CONNECTOR_TOKEN" ]] || return 1
  ! grep -qF "$LONG_CONNECTOR_TOKEN" "$WORK/out"
}
test_malformed_connector_token_is_rejected_quietly() {
  setup_tunnel
  CF_LAB_TUNNEL_ID="$LAB_TUNNEL_UUID"
  printf '"short-%s"\n' "$SECRET_TOKEN" >"$FAKE/cf-token"
  ! (tunnel_store_connector_token) || return 1
  [[ ! -f "$(lab_tunnel_token_file)" ]]
}

passed=0
failed=0
for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
  reset_fake
  if (
    load_libs
    "$name"
  ) >"$WORK/out" 2>&1 && assert_no_secret; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$name"
    sed 's/^/  /' "$WORK/out"
    printf '  omnictl calls:\n'
    sed 's/^/    /' "$FAKE/calls"
  fi
done
printf 'passed=%d failed=%d\n' "$passed" "$failed"
((failed == 0))
