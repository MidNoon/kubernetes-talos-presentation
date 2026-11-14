readonly LAB_HARD_CAP=10
readonly LAB_JOIN_TOKEN_NAME=talos-lab
readonly LAB_JOIN_TOKEN_TTL=1h
readonly LAB_PRESET_NAME=talos-lab
readonly LAB_CLUSTER_NAME=talos-lab
readonly LAB_TALOS_VERSION=1.14.5
readonly LAB_KUBERNETES_VERSION=1.37.2
readonly LAB_MACHINE_IDS=(
  1ab51de0-7a10-4000-8000-000000000001
  1ab51de0-7a10-4000-8000-000000000002
  1ab51de0-7a10-4000-8000-000000000003
)
readonly LAB_VM_IDS=(9101 9102 9103)
readonly LAB_VM_NAMES=(talos-lab-cp talos-lab-worker-a talos-lab-worker-b)

LAB_WATCHDOG_INTERVAL="${LAB_WATCHDOG_INTERVAL:-5}"
LAB_WATCHDOG_MAX_FAILURES="${LAB_WATCHDOG_MAX_FAILURES:-3}"
LAB_REGISTER_TIMEOUT="${LAB_REGISTER_TIMEOUT:-600}"
LAB_REGISTER_POLL="${LAB_REGISTER_POLL:-5}"
LAB_VM_STOP_FN="${LAB_VM_STOP_FN:-pve_stop_lab_vms}"
LAB_VM_START_FN="${LAB_VM_START_FN:-pve_start_lab_vm}"
LAB_WATCHDOG_PARENT_PID="${LAB_WATCHDOG_PARENT_PID:-$$}"

lab_cluster_template() {
  printf '%s/cluster/talos-lab.yaml' "$LAB_STATE"
}

cap_is_lab_id() {
  local id
  for id in "${LAB_MACHINE_IDS[@]}"; do
    [[ "$1" == "$id" ]] && return 0
  done
  return 1
}

cap_live_link_ids() {
  local raw ids
  raw="$(omni_query get links -o json)" || return 1
  ids="$(jq -s -r '
    if all(.[]; .metadata.type == "Links.omni.sidero.dev"
        and (.metadata.id | type == "string")
        and (.metadata.id | test("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")))
    then .[].metadata.id
    else error("unexpected link record") end' <<<"$raw" 2>&1)" || {
    fail "Omni link listing was not in the expected format: $ids"
    return 1
  }
  if [[ -n "$ids" ]]; then
    printf '%s\n' "$ids"
  fi
}

cap_registered_limit() {
  local raw limit
  raw="$(omni_query get machinestatusmetrics -o json)" || return 1
  limit="$(jq -s -r '
    if length == 1
        and .[0].metadata.type == "MachineStatusMetrics.omni.sidero.dev"
        and (.[0].spec.registeredmachineslimit | type == "number")
    then .[0].spec.registeredmachineslimit
    else error("unexpected metrics record") end' <<<"$raw" 2>&1)" || {
    fail "Omni machine metrics were not in the expected format: $limit"
    return 1
  }
  [[ "$limit" =~ ^[1-9][0-9]*$ ]] || {
    fail "Omni reported an invalid registered machine limit: $limit"
    return 1
  }
  printf '%s\n' "$limit"
}

cap_effective_limit() {
  if (($1 < LAB_HARD_CAP)); then
    printf '%s\n' "$1"
  else
    printf '%s\n' "$LAB_HARD_CAP"
  fi
}

cap_protected_machine_ids() {
  local raw ids
  [[ -n "${LAB_OMNI_PROTECTED_CLUSTER:-}" ]] || return 0
  raw="$(omni_query get machinesetnodes -o json)" || return 1
  ids="$(jq -s -r --arg cluster "$LAB_OMNI_PROTECTED_CLUSTER" '
    if all(.[]; .metadata.type == "MachineSetNodes.omni.sidero.dev")
    then .[] | select(.metadata.labels["omni.sidero.dev/cluster"] == $cluster) | .metadata.id
    else error("unexpected machine set node record") end' <<<"$raw" 2>&1)" || {
    fail "Omni machine set listing was not in the expected format: $ids"
    return 1
  }
  if [[ -z "$ids" ]]; then
    fail "protected cluster $LAB_OMNI_PROTECTED_CLUSTER lists no machines, refusing to trust the count"
    return 1
  fi
  printf '%s\n' "$ids"
}

cap_gate() {
  local ids limit protected cap id others=()
  ids="$(cap_live_link_ids)" || return 1
  limit="$(cap_registered_limit)" || return 1
  protected="$(cap_protected_machine_ids)" || return 1
  cap="$(cap_effective_limit "$limit")"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! cap_is_lab_id "$id"; then
      others+=("$id")
    fi
  done <<<"$ids"

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if cap_is_lab_id "$id"; then
      fail "lab machine $id is a member of protected cluster $LAB_OMNI_PROTECTED_CLUSTER"
      return 1
    fi
    if ! grep -qxF "$id" <<<"$ids"; then
      fail "protected cluster machine $id is missing from the live link list, refusing to trust the count"
      return 1
    fi
  done <<<"$protected"

  if ((${#others[@]} + ${#LAB_MACHINE_IDS[@]} > cap)); then
    fail "cap gate refused: ${#others[@]} non-lab links + ${#LAB_MACHINE_IDS[@]} lab machines exceeds cap $cap (hard cap $LAB_HARD_CAP, account limit $limit). Non-lab links: ${others[*]}"
    return 1
  fi
  log "cap gate passed: ${#others[@]} non-lab links + ${#LAB_MACHINE_IDS[@]} lab machines within cap $cap"
}

cap_token_ids() {
  local raw ids active_only="${1:-false}"
  raw="$(omni_query get jointokens -o json)" || return 1
  ids="$(jq -s -r --arg name "$LAB_JOIN_TOKEN_NAME" --argjson active_only "$active_only" '
    if all(.[]; .metadata.type == "JoinTokens.omni.sidero.dev" and (.metadata.id | type == "string"))
    then .[] | select(.spec.name == $name)
             | select(($active_only | not) or ((.spec.revoked // false) | not))
             | .metadata.id
    else error("unexpected join token record") end' <<<"$raw" 2>/dev/null)" || {
    fail "Omni join token listing was not in the expected format"
    return 1
  }
  if [[ -n "$ids" ]]; then
    printf '%s\n' "$ids"
  fi
}

cap_token_id() {
  local ids count
  ids="$(cap_token_ids true)" || return 1
  count="$(grep -c . <<<"$ids" || true)"
  if ((count != 1)); then
    fail "expected exactly one active join token named $LAB_JOIN_TOKEN_NAME, found $count"
    return 1
  fi
  printf '%s\n' "$ids"
}

cap_token_require_not_default() {
  local raw matches
  raw="$(omni_query get jointokenstatuses -o json)" || return 1
  matches="$(jq -s -r --arg name "$LAB_JOIN_TOKEN_NAME" \
    '[.[] | select(.spec.name == $name and (.spec.isdefault // false))] | length' <<<"$raw" 2>/dev/null)" || {
    fail "Omni join token status listing was not in the expected format"
    return 1
  }
  if [[ "$matches" != 0 ]]; then
    fail "join token $LAB_JOIN_TOKEN_NAME is the account default, refusing to use it"
    return 1
  fi
}

cap_token_create() {
  local existing
  existing="$(cap_token_ids)" || return 1
  if [[ -n "$existing" ]]; then
    cap_token_delete || return 1
  fi
  omni_query jointoken create "$LAB_JOIN_TOKEN_NAME" --ttl "$LAB_JOIN_TOKEN_TTL" >/dev/null || return 1
  cap_token_id >/dev/null || return 1
  cap_token_require_not_default || return 1
  log "lab join token created with ttl $LAB_JOIN_TOKEN_TTL"
}

cap_token_revoke() {
  local ids id status=0 force=()
  if [[ "${1:-}" == --force ]]; then
    force=(--force)
  fi
  ids="$(cap_token_ids true)" || return 1
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    local LAB_SCRUB="$id"
    omni_query jointoken revoke "$id" "${force[@]}" >/dev/null || status=1
  done <<<"$ids"
  if ((status == 0)); then
    log "lab join token revoked"
  fi
  return "$status"
}

cap_token_delete() {
  local ids id status=0
  ids="$(cap_token_ids)" || return 1
  [[ -n "$ids" ]] || return 0
  while IFS= read -r id; do
    local LAB_SCRUB="$id"
    omni_query jointoken delete "$id" --force >/dev/null || status=1
  done <<<"$ids"
  if ((status == 0)); then
    log "lab join token deleted"
  fi
  return "$status"
}

cap_preset_exists() {
  local raw exists
  raw="$(omni_query get installationmediaconfigs -o json)" || return 1
  exists="$(jq -s -r --arg name "$LAB_PRESET_NAME" 'any(.[]; .metadata.id == $name)' <<<"$raw" 2>/dev/null)" || {
    fail "Omni media preset listing was not in the expected format"
    return 1
  }
  [[ "$exists" == true ]]
}

cap_preset_stored_token() {
  local raw token
  raw="$(omni_query get installationmediaconfigs -o json)" || return 1
  token="$(jq -s -r --arg name "$LAB_PRESET_NAME" \
    '.[] | select(.metadata.id == $name) | .spec.jointoken // ""' <<<"$raw" 2>/dev/null)" || {
    fail "Omni media preset listing was not in the expected format"
    return 1
  }
  printf '%s\n' "$token"
}

cap_preset_create() {
  if (($# < 2)); then
    fail "cap_preset_create needs a join token and a Talos version"
    return 1
  fi
  local LAB_SCRUB="$1"
  local talos_version="$2" extension stored args=()
  shift 2
  if [[ ! "$LAB_SCRUB" =~ ^[[:graph:]]+$ ]]; then
    fail "refusing to create media preset without a join token, omnictl would fall back to the default token"
    return 1
  fi
  args=(media preset create "$LAB_PRESET_NAME" --arch amd64 --talos-version "$talos_version" --join-token "$LAB_SCRUB")
  for extension in "$@"; do
    args+=(--extensions "$extension")
  done
  omni_query "${args[@]}" >/dev/null || return 1
  stored="$(cap_preset_stored_token)" || return 1
  if [[ "$stored" != "$LAB_SCRUB" ]]; then
    cap_preset_delete || true
    fail "media preset $LAB_PRESET_NAME does not reference the lab join token, deleted it"
    return 1
  fi
  log "media preset $LAB_PRESET_NAME created with the lab join token"
}

cap_preset_delete() {
  if cap_preset_exists; then
    omni_query media preset delete "$LAB_PRESET_NAME" >/dev/null
    log "media preset $LAB_PRESET_NAME deleted"
  fi
}

cap_tripped() {
  [[ -f "$LAB_STATE/watchdog-tripped" ]]
}

cap_trip() {
  local reason="$1" status=0
  printf '%s %s\n' "$(date -Is)" "$reason" >"$LAB_STATE/watchdog-tripped"
  printf 'error: cap watchdog tripped: %s\n' "$reason" >&2
  if ! "$LAB_VM_STOP_FN"; then
    status=1
    printf 'error: cap watchdog could not stop the lab VMs, stop them by hand now\n' >&2
  fi
  if ! cap_token_revoke --force; then
    status=1
    printf 'error: cap watchdog could not revoke the lab join token, it expires within %s\n' "$LAB_JOIN_TOKEN_TTL" >&2
  fi
  return "$status"
}

cap_watchdog_evaluate() {
  local ids limit cap id total=0 unknown=()
  ids="$(cap_live_link_ids)" || return 2
  limit="$(cap_registered_limit)" || return 2
  cap="$(cap_effective_limit "$limit")"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    total=$((total + 1))
    if cap_is_lab_id "$id"; then
      continue
    fi
    if ! grep -qxF "$id" "$LAB_STATE/watchdog-baseline"; then
      unknown+=("$id")
    fi
  done <<<"$ids"
  if ((total > cap)); then
    printf 'total links %d passed cap %d' "$total" "$cap"
    return 1
  fi
  if ((${#unknown[@]} > 0)); then
    printf 'unknown machines appeared: %s' "${unknown[*]}"
    return 1
  fi
}

cap_watchdog_loop() {
  local failures=0 reason status
  while :; do
    if ! kill -0 "$LAB_WATCHDOG_PARENT_PID" 2>/dev/null; then
      cap_trip "lab run $LAB_WATCHDOG_PARENT_PID exited without stopping the watchdog" || true
      return 0
    fi
    status=0
    reason="$(cap_watchdog_evaluate)" || status=$?
    case "$status" in
      0)
        failures=0
        ;;
      1)
        cap_trip "$reason" || true
        return 0
        ;;
      *)
        failures=$((failures + 1))
        if ((failures >= LAB_WATCHDOG_MAX_FAILURES)); then
          cap_trip "could not read Omni state $failures times in a row" || true
          return 0
        fi
        ;;
    esac
    sleep "$LAB_WATCHDOG_INTERVAL"
  done
}

cap_watchdog_snapshot() {
  local ids id
  ids="$(cap_live_link_ids)" || return 1
  mkdir -p "$LAB_STATE"
  rm -f "$LAB_STATE/watchdog-tripped"
  : >"$LAB_STATE/watchdog-baseline"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    if ! cap_is_lab_id "$id"; then
      printf '%s\n' "$id" >>"$LAB_STATE/watchdog-baseline"
    fi
  done <<<"$ids"
}

cap_watchdog_start() {
  cap_watchdog_snapshot || return 1
  cap_watchdog_loop &
  LAB_WATCHDOG_PID=$!
  lab_on_exit cap_watchdog_stop
  log "cap watchdog running as pid $LAB_WATCHDOG_PID"
}

cap_watchdog_stop() {
  if [[ -n "${LAB_WATCHDOG_PID:-}" ]]; then
    kill "$LAB_WATCHDOG_PID" 2>/dev/null || true
    wait "$LAB_WATCHDOG_PID" 2>/dev/null || true
    LAB_WATCHDOG_PID=
  fi
}

cap_wait_for_link() {
  local machine_id="$1" deadline=$((SECONDS + LAB_REGISTER_TIMEOUT)) ids
  while ((SECONDS < deadline)); do
    if cap_tripped; then
      fail "cap watchdog tripped while waiting for $machine_id: $(cat "$LAB_STATE/watchdog-tripped")"
      return 1
    fi
    ids="$(cap_live_link_ids)" || return 1
    if grep -qxF "$machine_id" <<<"$ids"; then
      return 0
    fi
    sleep "$LAB_REGISTER_POLL"
  done
  fail "machine $machine_id did not register within ${LAB_REGISTER_TIMEOUT}s"
}

cap_guarded_boot() {
  local index
  for index in "${!LAB_VM_IDS[@]}"; do
    if cap_tripped; then
      fail "cap watchdog tripped before starting ${LAB_VM_NAMES[index]}: $(cat "$LAB_STATE/watchdog-tripped")"
      return 1
    fi
    cap_gate || return 1
    log "starting ${LAB_VM_NAMES[index]}"
    "$LAB_VM_START_FN" "${LAB_VM_IDS[index]}" || return 1
    cap_wait_for_link "${LAB_MACHINE_IDS[index]}" || return 1
    log "${LAB_VM_NAMES[index]} registered as ${LAB_MACHINE_IDS[index]}"
  done
}
