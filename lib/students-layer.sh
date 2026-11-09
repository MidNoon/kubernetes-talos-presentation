readonly STUDENT_MAX=20

student_token_path() {
  printf '%s/students/team%02d.token' "$LAB_STATE" "$((10#$1))"
}

student_use() {
  LAB_TUNNEL_NAME="$(printf 'talos-student-%02d' "$((10#$1))")"
  LAB_TUNNEL_HOSTNAME="$(printf 'team%02d.%s' "$((10#$1))" "$LAB_TUNNEL_ZONE")"
  LAB_TUNNEL_TOKEN_FILE="$(student_token_path "$1")"
}

students_listings() {
  STUDENTS_TUNNELS="$(cf_query tunnels list --is-deleted false --per-page 1000)" || return 1
  STUDENTS_RECORDS="$(cf_query dns records list -z "$LAB_TUNNEL_ZONE" --per-page 5000)" || return 1
}

students_snapshot_others() {
  local result
  students_listings || return 1
  result="$(
    jq -r '(if type == "object" and has("result") then .result else . end)[]
      | select(.name | test("^talos-student-[0-9]{2}$") | not)
      | "tunnel \(.id) \(.name)"' <<<"$STUDENTS_TUNNELS" | sort
    jq -r --arg zone "$LAB_TUNNEL_ZONE" '(if type == "object" and has("result") then .result else . end)[]
      | select(((.name | test("^team[0-9]{2}\\.")) and ((.name | sub("^[^.]+\\."; "")) == $zone)) | not)
      | "dns \(.id) \(.name) \(.type) \(.content)"' <<<"$STUDENTS_RECORDS" | sort
  )" || {
    fail "Cloudflare listings were not in the expected format"
    return 1
  }
  printf '%s\n' "$result"
}

students_existing_numbers() {
  local result
  students_listings || return 1
  result="$(
    jq -r '(if type == "object" and has("result") then .result else . end)[]
      | .name | capture("^talos-student-(?<n>[0-9]{2})$")? | .n' <<<"$STUDENTS_TUNNELS"
    jq -r --arg zone "$LAB_TUNNEL_ZONE" '(if type == "object" and has("result") then .result else . end)[]
      | select((.name | sub("^[^.]+\\."; "")) == $zone)
      | .name | capture("^team(?<n>[0-9]{2})\\.")? | .n' <<<"$STUDENTS_RECORDS"
  )" || {
    fail "Cloudflare listings were not in the expected format"
    return 1
  }
  if [[ -n "$result" ]]; then
    sort -u <<<"$result"
  fi
}

students_create() {
  local count="${1:-}" number before after
  if [[ ! "$count" =~ ^[1-9][0-9]*$ ]] || ((count > STUDENT_MAX)); then
    die "students create needs a count from 1 to $STUDENT_MAX, got \"$count\""
  fi
  lab_load_config
  cf_load_config
  before="$(students_snapshot_others)" || exit 1
  mkdir -p "$LAB_STATE/tunnel" "$LAB_STATE/students"
  for ((number = 1; number <= count; number++)); do
    (
      student_use "$number"
      tunnel_provision
      log "ready: https://$LAB_TUNNEL_HOSTNAME token saved in $LAB_TUNNEL_TOKEN_FILE"
    ) || exit 1
  done
  after="$(students_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed while creating student tunnels. Before: $before. After: $after"
  log "$count student tunnels ready, other tunnels and DNS records unchanged"
}

students_delete() {
  local before after number numbers remaining
  lab_load_config
  cf_load_config
  before="$(students_snapshot_others)" || exit 1
  numbers="$(students_existing_numbers)" || exit 1
  while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    (
      student_use "$number"
      tunnel_remove_current
    ) || exit 1
  done <<<"$numbers"
  rm -rf "$LAB_STATE/students"
  remaining="$(students_existing_numbers)" || exit 1
  [[ -z "$remaining" ]] || die "student resources left behind for numbers: $remaining"
  after="$(students_snapshot_others)" || exit 1
  [[ "$before" == "$after" ]] || die "other Cloudflare resources changed while deleting student tunnels. Before: $before. After: $after"
  log "student tunnels removed, other tunnels and DNS records unchanged"
}
