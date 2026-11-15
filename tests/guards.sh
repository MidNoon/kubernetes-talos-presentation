#!/usr/bin/env bash
set -uo pipefail

LAB_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export FAKE="$WORK/fake"
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
export PATH="$FAKE_BIN:$PATH"

LONG_CONNECTOR_TOKEN="eyJhIjoiYWNjb3VudCIsInQiOiJ0dW5uZWwiLCJzIjoic2VjcmV0In0$(printf 'x%.0s' $(seq 1 80))"
SECRET_PASSWORD=SeatPasswordValue42

cat >"$FAKE_BIN/cf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE/cf-calls"
case "$*" in
  "tunnels list"*) cat "$FAKE/cf-tunnels" ;;
  "dns records list"*) cat "$FAKE/cf-dns" ;;
  "tunnels connections cleanup"*) exit 0 ;;
  "tunnels config update"*) exit 0 ;;
  "tunnels create"*)
    uuid="$(printf '22222222-2222-4222-8222-%012d' "$(jq 'length' "$FAKE/cf-tunnels")")"
    jq -c --arg id "$uuid" --arg name "$4" '. + [{id: $id, name: $name, deleted_at: null}]' "$FAKE/cf-tunnels" >"$FAKE/cf-tunnels.new"
    mv "$FAKE/cf-tunnels.new" "$FAKE/cf-tunnels"
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
    ;;
  "dns records delete"*)
    jq -c --arg id "$4" 'map(select(.id != $id))' "$FAKE/cf-dns" >"$FAKE/cf-dns.new"
    mv "$FAKE/cf-dns.new" "$FAKE/cf-dns"
    ;;
  *) echo "unexpected cf call: $*" >&2; exit 64 ;;
esac
EOF
chmod +x "$FAKE_BIN/cf"

reset_fake() {
  rm -rf "$FAKE" "$WORK/state"
  mkdir -p "$FAKE"
  printf '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null}]\n' >"$FAKE/cf-tunnels"
  printf '[{"id":"other-rec","name":"other.zone.example","type":"A","content":"192.0.2.1"},{"id":"www-rec","name":"www.zone.example","type":"CNAME","content":"home-tunnel-id.cfargotunnel.com"}]\n' >"$FAKE/cf-dns"
  : >"$FAKE/cf-calls"
  printf '{"data":[{"vmid":100,"name":"unrelated","status":"running"},{"vmid":9011,"name":"seat01-cp","status":"stopped"},{"vmid":9012,"name":"intruder","status":"running"}]}\n' >"$FAKE/pve-qemu"
  printf '{"data":[{"vmid":"9010","name":"omni01","status":"running"}]}\n' >"$FAKE/pve-lxc"
  : >"$FAKE/pve-calls"
}

load_libs() {
  source "$LAB_ROOT/lib/common.sh"
  source "$LAB_ROOT/lib/pve-api.sh"
  source "$LAB_ROOT/lib/cloudflare.sh"
  source "$LAB_ROOT/lib/host-layer.sh"
  source "$LAB_ROOT/lib/seats-layer.sh"
  source "$LAB_ROOT/lib/rehearsal-layer.sh"
  source "$LAB_ROOT/lib/site-layer.sh"
  source "$LAB_ROOT/lib/failover-layer.sh"
  LAB_STATE="$WORK/state"
  HOST_STATE="$LAB_STATE/host"
  LAB_SEATS_STATE="$LAB_STATE/seats"
  mkdir -p "$HOST_STATE" "$LAB_SEATS_STATE"
  LAB_CF_ACCOUNT_ID=acct
  LAB_TUNNEL_ZONE=zone.example
  LAB_TUNNEL_DELETE_ATTEMPTS=2
  LAB_TUNNEL_DELETE_DELAY=0
  PVE_NODE=pve
  pve_api() {
    printf '%s %s\n' "$1" "$2" >>"$FAKE/pve-calls"
    case "$1 $2" in
      "GET /nodes/pve/qemu") cat "$FAKE/pve-qemu" ;;
      "GET /nodes/pve/lxc") cat "$FAKE/pve-lxc" ;;
      GET\ */tasks/*) printf '{"data":{"status":"stopped","exitstatus":"OK"}}\n' ;;
      *) printf '{"data":"UPID:fake"}\n' ;;
    esac
  }
}

cf_allowed() { cf_assert_allowed "$@" 2>/dev/null; }
cf_refused() { ! cf_assert_allowed "$@" 2>/dev/null; }

test_cf_allowlist_permits_lab_tunnels_when_current() {
  LAB_TUNNEL_NAME=talos-lab-host
  cf_allowed tunnels create --name talos-lab-host --config-source cloudflare || return 1
  LAB_TUNNEL_NAME=talos-student-07
  cf_allowed tunnels create --name talos-student-07 --config-source cloudflare
}
test_cf_allowlist_refuses_a_tunnel_that_is_not_current() {
  LAB_TUNNEL_NAME=talos-lab-host
  cf_refused tunnels create --name talos-student-07 --config-source cloudflare
}
test_cf_allowlist_refuses_other_tunnel_names_even_when_current() {
  local name
  for name in home-tunnel talos-student-7 talos-lab talos-student-07x; do
    LAB_TUNNEL_NAME="$name"
    cf_refused tunnels create --name "$name" --config-source cloudflare || return 1
  done
}
test_cf_allowlist_permits_every_lab_hostname() {
  local host
  for host in team07 omni07 kube07 shell07 auth pve; do
    LAB_TUNNEL_HOSTNAME="$host.zone.example"
    cf_allowed dns records create -z zone.example --body "{\"name\":\"$host.zone.example\",\"type\":\"CNAME\"}" || return 1
  done
}
test_cf_allowlist_refuses_other_hostnames() {
  local host
  for host in www.zone.example omni.zone.example team7.zone.example omni01.lab.zone.example omni01.other.example auth.other.example zone.example; do
    LAB_TUNNEL_HOSTNAME="$host"
    cf_refused dns records create -z zone.example --body "{\"name\":\"$host\",\"type\":\"CNAME\"}" || return 1
  done
}
test_cf_allowlist_refuses_a_body_for_a_different_name() {
  LAB_TUNNEL_HOSTNAME=team01.zone.example
  cf_refused dns records create -z zone.example --body '{"name":"www.zone.example","type":"CNAME"}'
}
test_cf_allowlist_refuses_non_cname_records() {
  LAB_TUNNEL_HOSTNAME=team01.zone.example
  cf_refused dns records create -z zone.example --body '{"name":"team01.zone.example","type":"A"}'
}
test_cf_allowlist_refuses_other_zones() {
  LAB_TUNNEL_HOSTNAME=team01.zone.example
  cf_refused dns records list -z other.example || return 1
  cf_refused dns records create -z other.example --body '{"name":"team01.zone.example","type":"CNAME"}'
}
test_cf_allowlist_refuses_ids_that_were_not_looked_up() {
  cf_refused tunnels delete home-tunnel-id --force || return 1
  cf_refused tunnels token get home-tunnel-id || return 1
  cf_refused dns records delete www-rec -z zone.example --force || return 1
  CF_LAB_TUNNEL_ID=22222222-2222-4222-8222-000000000001
  CF_LAB_DNS_RECORD_ID=rec-team01.zone.example
  cf_refused tunnels delete home-tunnel-id --force || return 1
  cf_refused tunnels config update home-tunnel-id || return 1
  cf_refused dns records delete www-rec -z zone.example --force
}
test_cf_allowlist_refuses_unknown_operations() {
  cf_refused zones delete zone.example || return 1
  cf_refused zones settings edit grpc -z zone.example || return 1
  cf_refused
}
test_cf_refused_call_never_reaches_cf() {
  LAB_TUNNEL_NAME=home-tunnel
  ! cf_query tunnels create --name home-tunnel --config-source cloudflare 2>/dev/null || return 1
  ! grep -q 'create' "$FAKE/cf-calls"
}

test_snapshot_lists_only_resources_the_lab_does_not_own() {
  local snapshot
  printf '[{"id":"home-tunnel-id","name":"home-tunnel"},{"id":"t1","name":"talos-lab-host"},{"id":"t2","name":"talos-student-03"}]\n' >"$FAKE/cf-tunnels"
  printf '[{"id":"a","name":"www.zone.example","type":"CNAME","content":"x"},{"id":"b","name":"omni03.zone.example","type":"CNAME","content":"y"},{"id":"c","name":"auth.zone.example","type":"CNAME","content":"y"},{"id":"d","name":"omni.zone.example","type":"CNAME","content":"y"}]\n' >"$FAKE/cf-dns"
  snapshot="$(cf_snapshot_others)" || return 1
  [[ "$snapshot" == $'dns a www.zone.example CNAME x\ndns d omni.zone.example CNAME y\ntunnel home-tunnel-id home-tunnel' ]]
}

test_dns_lookup_refuses_a_non_tunnel_record() {
  printf '[{"id":"x","name":"team01.zone.example","type":"A","content":"192.0.2.9"}]\n' >"$FAKE/cf-dns"
  LAB_TUNNEL_HOSTNAME=team01.zone.example
  ! cf_lookup_dns_record 2>/dev/null
}
test_tunnel_ensure_dns_replaces_a_stale_tunnel_record() {
  printf '[{"id":"old","name":"team01.zone.example","type":"CNAME","content":"11111111-1111-4111-8111-111111111111.cfargotunnel.com"}]\n' >"$FAKE/cf-dns"
  LAB_TUNNEL_HOSTNAME=team01.zone.example
  CF_LAB_TUNNEL_ID=22222222-2222-4222-8222-000000000001
  tunnel_ensure_dns 2>/dev/null || return 1
  [[ "$(jq -r '.[] | select(.name == "team01.zone.example") | .content' "$FAKE/cf-dns")" == "$CF_LAB_TUNNEL_ID.cfargotunnel.com" ]]
}
test_connector_token_is_stored_but_never_printed() {
  CF_LAB_TUNNEL_ID=22222222-2222-4222-8222-000000000001
  printf '"%s"\n' "$LONG_CONNECTOR_TOKEN" >"$FAKE/cf-token"
  tunnel_store_connector_token "$LAB_STATE/token" >"$LAB_STATE/token-out" 2>&1 || return 1
  [[ "$(cat "$LAB_STATE/token")" == "$LONG_CONNECTOR_TOKEN" ]] || return 1
  ! grep -qF "$LONG_CONNECTOR_TOKEN" "$LAB_STATE/token-out"
}
test_malformed_connector_token_is_rejected_quietly() {
  CF_LAB_TUNNEL_ID=22222222-2222-4222-8222-000000000001
  printf '"short-token"\n' >"$FAKE/cf-token"
  ! tunnel_store_connector_token "$LAB_STATE/token" 2>/dev/null || return 1
  [[ ! -f "$LAB_STATE/token" ]]
}
test_tunnel_remove_leaves_other_tunnels() {
  printf '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null},{"id":"t2","name":"talos-student-02","deleted_at":null}]\n' >"$FAKE/cf-tunnels"
  LAB_TUNNEL_NAME=talos-student-02
  tunnel_remove 2>/dev/null || return 1
  [[ "$(jq -r '.[].name' "$FAKE/cf-tunnels")" == home-tunnel ]]
}
test_tunnel_remove_fails_when_delete_keeps_failing() {
  printf '[{"id":"t2","name":"talos-student-02","deleted_at":null}]\n' >"$FAKE/cf-tunnels"
  touch "$FAKE/cf-delete-fail"
  LAB_TUNNEL_NAME=talos-student-02
  ! tunnel_remove 2>/dev/null
}

test_seat_use_derives_isolated_identities() {
  seat_use 7
  [[ "$SEAT" == 07 && "$SEAT_NAME" == seat07 && "$SEAT_VNET" == seat07 ]] || return 1
  [[ "$SEAT_SUBNET" == 10.88.7.0/24 && "$SEAT_GATEWAY" == 10.88.7.1 && "$SEAT_OMNI_ADDR" == 10.88.7.2 ]] || return 1
  [[ "$SEAT_CT_ID" == 9070 && "$SEAT_CT_NAME" == omni07 ]] || return 1
  [[ "${SEAT_VM_IDS[*]}" == "9071 9072 9073" && "${SEAT_VM_NAMES[*]}" == "seat07-cp seat07-worker-a seat07-worker-b" ]] || return 1
  [[ "${SEAT_MACHINE_IDS[0]}" == 1ab51de0-7a10-4000-8000-000000007001 ]] || return 1
  [[ "$SEAT_OMNI_HOST" == omni07.zone.example && "$SEAT_KUBE_HOST" == kube07.zone.example && "$SEAT_SITE_HOST" == team07.zone.example ]] || return 1
  [[ "$SEAT_WS_ID" == 9074 && "$SEAT_WS_NAME" == workspace07 && "$SEAT_WS_ADDR" == 10.88.7.3 ]] || return 1
  [[ "$SEAT_TEMPLATE_ID" == 9079 && "$SEAT_TEMPLATE_NAME" == seat07-template && "$SEAT_PVE_USER" == student07@lab && "$SEAT_SHELL_HOST" == shell07.zone.example ]]
}
test_seat_numbers_with_leading_zeros_are_decimal() {
  seat_use 08
  [[ "$SEAT_INDEX" == 8 && "$SEAT_CT_ID" == 9080 ]]
}
test_seat_identities_never_overlap() {
  local n all=()
  for n in $(seq 1 "$SEAT_MAX"); do
    seat_use "$n"
    all+=("$SEAT_CT_ID" "$SEAT_WS_ID" "$SEAT_TEMPLATE_ID" "${SEAT_VM_IDS[@]}" "${SEAT_MACHINE_IDS[@]}" "$SEAT_SUBNET" "$SEAT_WS_ADDR")
  done
  [[ "$(printf '%s\n' "${all[@]}" | sort | uniq -d)" == "" ]]
}
test_seat_use_refuses_out_of_range() {
  local value
  for value in 0 21 100 abc -1 1.5 ""; do
    ! (seat_use "$value") 2>/dev/null || return 1
  done
}

test_vm_guard_reports_absent_and_state() {
  [[ "$(pve_vm_state 9013 seat01-worker-b)" == absent ]] || return 1
  [[ "$(pve_vm_state 9011 seat01-cp)" == stopped ]]
}
test_vm_guard_refuses_a_foreign_name() {
  ! pve_vm_state 9012 seat01-worker-a 2>/dev/null
}
test_vm_delete_refuses_a_foreign_name() {
  ! pve_delete_vm 9012 seat01-worker-a 2>/dev/null || return 1
  ! grep -q '^DELETE' "$FAKE/pve-calls"
}
test_vm_start_refuses_a_running_vm() {
  printf '{"data":[{"vmid":9011,"name":"seat01-cp","status":"running"}]}\n' >"$FAKE/pve-qemu"
  ! pve_start_vm 9011 seat01-cp 2>/dev/null
}
test_container_guard_handles_string_ids() {
  [[ "$(pve_ct_state 9010 omni01)" == running ]] || return 1
  ! pve_ct_state 9010 omni02 2>/dev/null
}

test_host_ingress_routes_each_seat_and_ends_with_a_catch_all() {
  local ingress
  mkdir -p "$LAB_SEATS_STATE/seat01" "$LAB_SEATS_STATE/seat03"
  ingress="$(host_render_ingress)" || return 1
  [[ "$(jq -r '.[-1].service' <<<"$ingress")" == http_status:404 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "omni03.zone.example") | .service' <<<"$ingress")" == http://10.88.3.2:8080 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "kube01.zone.example") | .service' <<<"$ingress")" == http://10.88.1.2:8095 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "pve.zone.example") | .originRequest.noTLSVerify' <<<"$ingress")" == true ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "shell03.zone.example") | .service' <<<"$ingress")" == http://10.88.3.3:8443 ]] || return 1
  [[ "$(jq 'length' <<<"$ingress")" == 9 ]]
}
test_dex_config_carries_hashes_not_passwords() {
  local config
  mkdir -p "$LAB_SEATS_STATE/seat02"
  printf 'secret\n' >"$HOST_STATE/dex-client-secret"
  printf 'pve-secret\n' >"$HOST_STATE/proxmox-client-secret"
  printf 'student02\tstudent02@zone.example\t%s\t$2b$10$hash\tuuid-2\n' "$SECRET_PASSWORD" >"$HOST_STATE/users.tsv"
  config="$(host_render_dex)" || return 1
  ! grep -qF "$SECRET_PASSWORD" <<<"$config" || return 1
  [[ "$(jq -r '.staticPasswords[0].hash' <<<"$config")" == '$2b$10$hash' ]] || return 1
  [[ "$(jq -r '.staticClients[0].redirectURIs[0]' <<<"$config")" == https://omni02.zone.example/oidc/consume ]] || return 1
  [[ "$(jq -r '.staticClients[] | select(.id == "proxmox") | .redirectURIs[0]' <<<"$config")" == https://pve.zone.example ]]
}
test_seat_numbers_succeed_with_no_seats() {
  set -o pipefail
  [[ "$(host_seat_numbers | sort -u)" == "" ]]
}
test_seat_numbers_list_existing_seats() {
  mkdir -p "$LAB_SEATS_STATE/seat03" "$LAB_SEATS_STATE/seat11"
  [[ "$(host_seat_numbers | paste -sd' ')" == "03 11" ]]
}
test_host_users_are_added_once_and_removed() {
  printf 'student01\tstudent01@zone.example\tpw\thash\tid\n' >"$HOST_STATE/users.tsv"
  host_ensure_user student01 || return 1
  [[ "$(grep -c . "$HOST_STATE/users.tsv")" == 1 ]] || return 1
  host_remove_user student01
  [[ ! -s "$HOST_STATE/users.tsv" ]]
}
test_host_passwords_avoid_look_alike_characters() {
  local password count
  for count in 1 2 3 4 5 6 7 8; do
    password="$(host_random_password)"
    [[ "$password" =~ ^[a-km-np-z2-9]{4}-[a-km-np-z2-9]{4}-[a-km-np-z2-9]{4}$ ]] || return 1
  done
  [[ "$(host_random_password)" != "$(host_random_password)" ]]
}
test_host_query_param_reads_raw_values() {
  local url='https://pve.zone.example/?code=abc123&state=%7B%22realm%22%3A%22lab%22%7D'
  [[ "$(host_query_param "$url" code)" == abc123 ]] || return 1
  [[ "$(host_query_param "$url" state)" == '%7B%22realm%22%3A%22lab%22%7D' ]] || return 1
  ! host_query_param "$url" token >/dev/null
}

test_failover_targets_only_workers() {
  [[ "$(failover_worker_index worker-a)" == 1 && "$(failover_worker_index worker-b)" == 2 ]] || return 1
  ! failover_worker_index cp 2>/dev/null
}
test_failover_waits_after_a_recent_pod_start() {
  local stamp begin
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  lab_kubectl() { printf '{"items":[{"status":{"startTime":"2020-01-01T00:00:00Z"}},{"status":{"startTime":"%s"}}]}\n' "$stamp"; }
  FAILOVER_IMAGE_SETTLE_SECONDS=2
  begin=$SECONDS
  failover_wait_images_settled 2>/dev/null || return 1
  ((SECONDS - begin >= 1))
}
test_failover_does_not_wait_for_old_pods() {
  local begin
  lab_kubectl() { printf '{"items":[{"status":{"startTime":"2020-01-01T00:00:00Z"}}]}\n'; }
  begin=$SECONDS
  failover_wait_images_settled || return 1
  ((SECONDS - begin < 2))
}
test_failover_settle_fails_when_pods_are_unreadable() {
  lab_kubectl() { return 1; }
  ! failover_wait_images_settled
}
test_failover_settle_fails_with_no_pods() {
  lab_kubectl() { printf '{"items":[]}\n'; }
  ! failover_wait_images_settled 2>/dev/null
}

test_lab_exit_hooks_run_each_once() {
  local out="$WORK/hooks"
  : >"$out"
  (
    first() { printf 'first\n' >>"$out"; }
    second() { printf 'second\n' >>"$out"; }
    lab_on_exit first
    lab_on_exit second
    lab_on_exit first
  )
  [[ "$(paste -sd' ' "$out")" == "first second" ]]
}

passed=0
failed=0
for name in $(declare -F | awk '{print $3}' | grep '^test_'); do
  reset_fake
  if (
    load_libs
    "$name"
  ) >"$WORK/out" 2>&1 && ! grep -qF -e "$LONG_CONNECTOR_TOKEN" -e "$SECRET_PASSWORD" "$WORK/out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL %s\n' "$name"
    sed 's/^/  /' "$WORK/out"
    printf '  cf calls:\n'
    sed 's/^/    /' "$FAKE/cf-calls"
  fi
done
printf 'passed=%d failed=%d\n' "$passed" "$failed"
((failed == 0))
