pve_load_target() {
  local target="${LAB_PVE_TARGET:-$LAB_STATE/pve-target.env}" var
  [[ -r "$target" ]] || {
    fail "Proxmox target file not readable: $target"
    return 1
  }
  source "$target"
  for var in PVE_URL PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_TLS_PIN PVE_ISO_STORAGE PVE_DISK_STORAGE PVE_SSH PVE_SSH_KEY PVE_SSH_KNOWN_HOSTS; do
    [[ -n "${!var:-}" ]] || {
      fail "Proxmox target file $target does not set $var"
      return 1
    }
  done
}

pve_ssh_options() {
  PVE_SSH_OPTIONS=(
    -i "$PVE_SSH_KEY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$PVE_SSH_KNOWN_HOSTS"
    -o ConnectTimeout=10
    -o ServerAliveInterval=15
  )
}

pve_ssh() {
  pve_ssh_options
  ssh "${PVE_SSH_OPTIONS[@]}" "$PVE_SSH" "$@"
}

pve_remote() {
  pve_ssh "$(printf '%q ' env "$@") bash -s"
}

pve_scp() {
  pve_ssh_options
  scp -q "${PVE_SSH_OPTIONS[@]}" "$@"
}

pve_ssh_forward_open() {
  local socket="$1" spec="$2"
  pve_ssh_options
  if [[ -S "$socket" ]]; then
    ssh "${PVE_SSH_OPTIONS[@]}" -S "$socket" -O exit "$PVE_SSH" >/dev/null 2>&1 || rm -f "$socket"
  fi
  ssh "${PVE_SSH_OPTIONS[@]}" -M -S "$socket" -f -N -o ExitOnForwardFailure=yes -L "$spec" "$PVE_SSH" 2>/dev/null 9>&-
}

pve_ssh_forward_close() {
  pve_ssh_options
  ssh "${PVE_SSH_OPTIONS[@]}" -S "$1" -O exit "$PVE_SSH" >/dev/null 2>&1 || true
}

pve_api() {
  local method="$1" path="$2" body status=0
  shift 2
  body="$(curl --silent --show-error --fail-with-body --max-time 120 \
    --insecure --pinnedpubkey "sha256//$PVE_TLS_PIN" \
    --config <(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET") \
    -X "$method" "$PVE_URL/api2/json$path" "$@" 2>&1)" || status=$?
  if ((status != 0)); then
    fail "Proxmox API $method $path failed with curl exit $status: $body"
    return 1
  fi
  printf '%s\n' "$body"
}

pve_uri() {
  jq -rn --arg value "$1" '$value | @uri'
}

pve_wait_task() {
  local upid="$1" timeout="${2:-300}" api="${3:-pve_api}" encoded status deadline
  deadline=$((SECONDS + timeout))
  encoded="$(pve_uri "$upid")"
  while ((SECONDS < deadline)); do
    status="$("$api" GET "/nodes/$PVE_NODE/tasks/$encoded/status")" || return 1
    if jq -e '.data.status == "stopped"' <<<"$status" >/dev/null; then
      if jq -e '.data.exitstatus == "OK"' <<<"$status" >/dev/null; then
        return 0
      fi
      fail "Proxmox task $upid failed: $status"
      return 1
    fi
    sleep 1
  done
  fail "Proxmox task $upid did not finish within ${timeout}s"
}

pve_wait_response() {
  local response="$1" timeout="${2:-300}" api="${3:-pve_api}" upid
  upid="$(jq -r 'if (.data | type) == "string" then .data else "" end' <<<"$response")" || {
    fail "Proxmox returned an unreadable response: $response"
    return 1
  }
  if [[ -n "$upid" ]]; then
    pve_wait_task "$upid" "$timeout" "$api"
  fi
}

pve_guest_state() {
  local kind="$1" id="$2" expected="$3" listing row name
  listing="$(pve_api GET "/nodes/$PVE_NODE/$kind")" || return 1
  row="$(jq -c --argjson id "$id" '.data[] | select((.vmid | tonumber) == $id)' <<<"$listing")" || {
    fail "Proxmox $kind listing was unreadable: $listing"
    return 1
  }
  if [[ -z "$row" ]]; then
    printf 'absent\n'
    return 0
  fi
  name="$(jq -r '.name // ""' <<<"$row")"
  if [[ "$name" != "$expected" ]]; then
    fail "$kind $id is named \"$name\", expected \"$expected\", refusing to touch it"
    return 1
  fi
  jq -r '.status' <<<"$row"
}

pve_vm_state() {
  pve_guest_state qemu "$1" "$2"
}

pve_ct_state() {
  pve_guest_state lxc "$1" "$2"
}

pve_start_vm() {
  local vmid="$1" name="$2" state response
  state="$(pve_vm_state "$vmid" "$name")" || return 1
  if [[ "$state" != stopped ]]; then
    fail "VM $name ($vmid) is $state, expected stopped"
    return 1
  fi
  response="$(pve_api POST "/nodes/$PVE_NODE/qemu/$vmid/status/start")" || return 1
  pve_wait_response "$response" 120
}

pve_stop_vm() {
  local vmid="$1" name="$2" state response
  state="$(pve_vm_state "$vmid" "$name")" || return 1
  [[ "$state" == running ]] || return 0
  response="$(pve_api POST "/nodes/$PVE_NODE/qemu/$vmid/status/stop")" || return 1
  pve_wait_response "$response" 120
}

pve_delete_vm() {
  local vmid="$1" name="$2" state response
  state="$(pve_vm_state "$vmid" "$name")" || return 1
  [[ "$state" != absent ]] || return 0
  if [[ "$state" == running ]]; then
    pve_stop_vm "$vmid" "$name" || return 1
  fi
  response="$(pve_api DELETE "/nodes/$PVE_NODE/qemu/$vmid?purge=1&destroy-unreferenced-disks=1")" || return 1
  pve_wait_response "$response" 300
}

pve_iso_present() {
  local name="$1" listing
  listing="$(pve_api GET "/nodes/$PVE_NODE/storage/$PVE_ISO_STORAGE/content?content=iso")" || return 2
  jq -e --arg volid "$PVE_ISO_STORAGE:iso/$name" '.data | any(.volid == $volid)' <<<"$listing" >/dev/null
}

pve_delete_iso() {
  local name="$1" response status=0
  pve_iso_present "$name" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;;
    *) return 1 ;;
  esac
  response="$(pve_api DELETE "/nodes/$PVE_NODE/storage/$PVE_ISO_STORAGE/content/$(pve_uri "$PVE_ISO_STORAGE:iso/$name")")" || return 1
  pve_wait_response "$response" 120
}

pve_upload_iso() {
  local file="$1" name="$2" response
  response="$(pve_api POST "/nodes/$PVE_NODE/storage/$PVE_ISO_STORAGE/upload" \
    --max-time 1800 \
    -F content=iso \
    -F "filename=@$file;filename=$name")" || return 1
  pve_wait_response "$response" 600
}
