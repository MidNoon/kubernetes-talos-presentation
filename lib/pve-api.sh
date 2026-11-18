readonly PVE_API_USER=talos-lab@pve
readonly PVE_API_TOKEN_NAME=kit
readonly PVE_API_ROLES=PVEVMAdmin,PVEDatastoreAdmin,PVESDNUser,PVEPoolAdmin
readonly PVE_SSH_ATTEMPTS=4
readonly PVE_SSH_BEFORE_SESSION='mux_client_request_session|Control socket connect|kex_exchange_identification|websocket: bad handshake|Connection closed by UNKNOWN|during banner exchange|Connection timed out'

pve_load_target() {
  local target="${LAB_PVE_TARGET:-$LAB_STATE/pve-target.env}" var
  [[ -r "$target" ]] || {
    fail "Proxmox target file not readable: $target"
    return 1
  }
  source "$target"
  for var in PVE_URL PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_TLS_PIN PVE_DISK_STORAGE PVE_SSH PVE_SSH_KEY PVE_SSH_KNOWN_HOSTS; do
    [[ -n "${!var:-}" ]] || {
      fail "Proxmox target file $target does not set $var"
      return 1
    }
  done
  if [[ -n "${PVE_SSH_ACCESS:-}" ]]; then
    pve_access_open || return 1
  fi
}

pve_access_master() {
  printf '%s/access/master' "$LAB_STATE"
}

pve_access_env() {
  local cloudflared="$LAB_STATE/host/bin/cloudflared"
  [[ -r "$PVE_SSH_ACCESS" ]] || {
    fail "Cloudflare Access service token not readable at $PVE_SSH_ACCESS, run ./lab access up"
    return 1
  }
  [[ -x "$cloudflared" ]] || {
    fail "cloudflared is not at $cloudflared, run ./lab access up"
    return 1
  }
  set -a
  source "$PVE_SSH_ACCESS"
  set +a
}

pve_access_open() {
  local port
  pve_access_env || return 1
  [[ "$PVE_URL" =~ ^https://127\.0\.0\.1:([0-9]+)$ ]] || {
    fail "PVE_URL is $PVE_URL, but with PVE_SSH_ACCESS set it must be https://127.0.0.1:<port>, the local end of the forward to the host's API"
    return 1
  }
  port="${BASH_REMATCH[1]}"
  mkdir -p "$LAB_STATE/access"
  pve_ssh_forward_open "$(pve_access_master)" "127.0.0.1:$port:127.0.0.1:8006" || {
    fail "could not reach $PVE_SSH through Cloudflare Access with a forward from 127.0.0.1:$port to its API"
    return 1
  }
  if ((BASHPID == $$)); then
    lab_on_exit pve_access_close
  fi
}

pve_access_close() {
  pve_ssh_forward_close "$(pve_access_master)"
}

pve_ssh_options() {
  PVE_SSH_OPTIONS=(
    -i "$PVE_SSH_KEY"
    -o IdentitiesOnly=yes
    -o BatchMode=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$PVE_SSH_KNOWN_HOSTS"
    -o ServerAliveInterval=15
  )
  if [[ -n "${PVE_SSH_ACCESS:-}" ]]; then
    PVE_SSH_OPTIONS+=(
      -o ConnectTimeout=30
      -o "ProxyCommand=$(printf '%q' "$LAB_STATE/host/bin/cloudflared") access ssh --hostname %h"
      -o ControlPath=none
    )
  else
    PVE_SSH_OPTIONS+=(-o ConnectTimeout=10)
  fi
}

pve_ssh() {
  local err attempt status
  pve_ssh_options
  err="$(mktemp)"
  for ((attempt = 1; ; attempt++)); do
    status=0
    ssh "${PVE_SSH_OPTIONS[@]}" "$PVE_SSH" "$@" 2>"$err" || status=$?
    if ((status == 255 && attempt < PVE_SSH_ATTEMPTS)) && grep -qE "$PVE_SSH_BEFORE_SESSION" "$err"; then
      sleep "$attempt"
      continue
    fi
    cat "$err" >&2
    rm -f "$err"
    if ((status == 255)); then
      printf 'error: ssh to %s ended with exit 255 while running: %.160s\n' "$PVE_SSH" "$*" >&2
    fi
    return "$status"
  done
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

pve_ssh_forward_alive() {
  pve_ssh_options
  ssh "${PVE_SSH_OPTIONS[@]}" -S "$1" -O check "$PVE_SSH" >/dev/null 2>&1
}

pve_ssh_forward_close() {
  pve_ssh_options
  ssh "${PVE_SSH_OPTIONS[@]}" -S "$1" -O exit "$PVE_SSH" >/dev/null 2>&1 || true
}

pve_api() {
  local method="$1" path="$2" body status attempt
  shift 2
  for ((attempt = 1; ; attempt++)); do
    status=0
    body="$(curl --silent --show-error --fail-with-body --max-time 120 \
      --insecure --pinnedpubkey "sha256//$PVE_TLS_PIN" \
      --config <(printf 'header = "Authorization: PVEAPIToken=%s=%s"\n' "$PVE_TOKEN_ID" "$PVE_TOKEN_SECRET") \
      -X "$method" "$PVE_URL/api2/json$path" "$@" 2>&1)" || status=$?
    if ((status != 7 || attempt >= PVE_SSH_ATTEMPTS)) || [[ -z "${PVE_SSH_ACCESS:-}" ]]; then
      break
    fi
    log "the Proxmox API forward through Cloudflare Access is gone, reopening it"
    pve_access_open || break
  done
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

pve_storage_isos() {
  local storage="$1" listing
  listing="$(pve_api GET "/nodes/$PVE_NODE/storage/$storage/content?content=iso")" || return 1
  jq -r '.data[].volid' <<<"$listing"
}

pve_delete_volume() {
  local volid="$1" storage="${1%%:*}" response
  response="$(pve_api DELETE "/nodes/$PVE_NODE/storage/$storage/content/$(pve_uri "$volid")")" || return 1
  pve_wait_response "$response" 120
}
