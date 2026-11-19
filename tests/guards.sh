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
  "zero-trust access applications list"*) cat "$FAKE/cf-apps" ;;
  "zero-trust access service-tokens list"*) cat "$FAKE/cf-service-tokens" ;;
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
  printf '[{"id":"other-app","name":"vpn","domain":"vpn.zone.example"},{"id":"access-app","name":"talos-lab-access-0","domain":"ssh0.zone.example"}]\n' >"$FAKE/cf-apps"
  printf '[{"id":"other-token","name":"ci"},{"id":"access-token","name":"talos-lab-access"}]\n' >"$FAKE/cf-service-tokens"
  : >"$FAKE/cf-calls"
  printf '{"data":[{"vmid":100,"name":"unrelated","status":"running"},{"vmid":9011,"name":"seat01-cp","status":"stopped"},{"vmid":9012,"name":"intruder","status":"running"}]}\n' >"$FAKE/pve-qemu"
  printf '{"data":[{"vmid":"9010","name":"omni01","status":"running"}]}\n' >"$FAKE/pve-lxc"
  : >"$FAKE/pve-calls"
}

load_libs() {
  source "$LAB_ROOT/lib/common.sh"
  source "$LAB_ROOT/lib/pve-api.sh"
  source "$LAB_ROOT/lib/cloudflare.sh"
  source "$LAB_ROOT/lib/hosts-layer.sh"
  source "$LAB_ROOT/lib/host-layer.sh"
  source "$LAB_ROOT/lib/seats-layer.sh"
  source "$LAB_ROOT/lib/rehearsal-layer.sh"
  source "$LAB_ROOT/lib/site-layer.sh"
  source "$LAB_ROOT/lib/failover-layer.sh"
  source "$LAB_ROOT/lib/upgrade-layer.sh"
  source "$LAB_ROOT/lib/access-layer.sh"
  source "$LAB_ROOT/lib/install-layer.sh"
  source "$LAB_ROOT/lib/local-layer.sh"
  source "$LAB_ROOT/lib/campus-layer.sh"
  LAB_STATE="$WORK/state"
  SHARED_STATE="$LAB_STATE/shared"
  LAB_HOSTS_STATE="$LAB_STATE/hosts"
  ACCESS_STATE="$LAB_STATE/access"
  LAB_SEATS_STATE="$LAB_STATE/seats"
  mkdir -p "$SHARED_STATE" "$LAB_SEATS_STATE" "$LAB_HOSTS_STATE/campus"
  printf 'HOST_INDEX=0\nHOST_SEATS=4\n' >"$LAB_HOSTS_STATE/campus/host.env"
  host_select campus
  mkdir -p "$HOST_STATE"
  CF_ACCESS_INDEX=0
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
  LAB_TUNNEL_NAME=talos-lab-host-0
  cf_allowed tunnels create --name talos-lab-host-0 --config-source cloudflare || return 1
  LAB_TUNNEL_NAME=talos-student-07
  cf_allowed tunnels create --name talos-student-07 --config-source cloudflare
}
test_cf_allowlist_refuses_a_tunnel_that_is_not_current() {
  LAB_TUNNEL_NAME=talos-lab-host-0
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
  for host in team07 omni07 kube07 shell07 auth pve0 pve9; do
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
  printf '[{"id":"home-tunnel-id","name":"home-tunnel"},{"id":"t1","name":"talos-lab-host-0"},{"id":"t2","name":"talos-student-03"}]\n' >"$FAKE/cf-tunnels"
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
  [[ "$SEAT_TEMPLATE_ID" == 9079 && "$SEAT_TEMPLATE_NAME" == seat07-template && "$SEAT_PVE_USER" == student07@lab && "$SEAT_SHELL_HOST" == shell07.zone.example ]] || return 1
  [[ "$SEAT_ISO_STORAGE" == seat07-iso && "$SEAT_ISO_PATH" == /var/lib/talos-lab/iso/seat07 ]]
}
test_seat_numbers_with_leading_zeros_are_decimal() {
  seat_use 08
  [[ "$SEAT_INDEX" == 8 && "$SEAT_CT_ID" == 9080 ]]
}
test_seat_identities_never_overlap() {
  local n all=()
  for n in $(seq 1 "$SEAT_MAX"); do
    seat_use "$n"
    all+=("$SEAT_CT_ID" "$SEAT_WS_ID" "$SEAT_TEMPLATE_ID" "${SEAT_VM_IDS[@]}" "${SEAT_MACHINE_IDS[@]}" "$SEAT_SUBNET" "$SEAT_WS_ADDR" "$SEAT_ISO_STORAGE" "$SEAT_ISO_PATH")
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
  mkdir -p "$LAB_SEATS_STATE/seat01" "$LAB_SEATS_STATE/seat03" "$LAB_SEATS_STATE/seat05"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat01/host"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat03/host"
  printf 'home\n' >"$LAB_SEATS_STATE/seat05/host"
  ingress="$(host_render_ingress)" || return 1
  [[ "$(jq -r '.[-1].service' <<<"$ingress")" == http_status:404 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "omni03.zone.example") | .service' <<<"$ingress")" == http://10.88.3.2:8080 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "kube01.zone.example") | .service' <<<"$ingress")" == http://10.88.1.2:8095 ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "pve0.zone.example") | .originRequest.noTLSVerify' <<<"$ingress")" == true ]] || return 1
  [[ "$(jq -r '.[] | select(.hostname == "shell03.zone.example") | .service' <<<"$ingress")" == http://10.88.3.3:8443 ]] || return 1
  [[ "$(jq 'length' <<<"$ingress")" == 9 ]]
}
test_dex_config_carries_hashes_not_passwords() {
  local config
  mkdir -p "$LAB_SEATS_STATE/seat02"
  printf 'secret\n' >"$SHARED_STATE/dex-client-secret"
  printf 'pve-secret\n' >"$SHARED_STATE/proxmox-client-secret"
  printf 'student02\tstudent02@zone.example\t%s\t$2b$10$hash\tuuid-2\n' "$SECRET_PASSWORD" >"$SHARED_STATE/users.tsv"
  mkdir -p "$LAB_HOSTS_STATE/home"
  printf 'HOST_INDEX=1\nHOST_SEATS=2\n' >"$LAB_HOSTS_STATE/home/host.env"
  config="$(host_render_dex)" || return 1
  ! grep -qF "$SECRET_PASSWORD" <<<"$config" || return 1
  [[ "$(jq -r '.staticPasswords[0].hash' <<<"$config")" == '$2b$10$hash' ]] || return 1
  [[ "$(jq -r '.staticClients[0].redirectURIs[0]' <<<"$config")" == https://omni02.zone.example/oidc/consume ]] || return 1
  [[ "$(jq -r '.staticClients[] | select(.id == "proxmox") | .redirectURIs | join(" ")' <<<"$config")" == "https://pve0.zone.example https://pve1.zone.example" ]]
}
test_seat_numbers_succeed_with_no_seats() {
  set -o pipefail
  [[ "$(lab_seat_numbers | sort -u)" == "" && "$(host_seats_on campus)" == "" ]]
}
test_seat_numbers_list_existing_seats() {
  mkdir -p "$LAB_SEATS_STATE/seat03" "$LAB_SEATS_STATE/seat11"
  [[ "$(lab_seat_numbers | paste -sd' ')" == "03 11" ]]
}
test_host_users_are_added_once_and_removed() {
  printf 'student01\tstudent01@zone.example\tpw\thash\tid\n' >"$SHARED_STATE/users.tsv"
  host_ensure_user student01 || return 1
  [[ "$(grep -c . "$SHARED_STATE/users.tsv")" == 1 ]] || return 1
  host_remove_user student01
  [[ ! -s "$SHARED_STATE/users.tsv" ]]
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

test_guide_readme_is_personal_to_the_seat() {
  local readme
  seat_use 7
  readme="$(seat_render_readme)"
  ! grep -qE '(seat|shell|omni|team|kube|student)NN|`NN`|<class domain>' <<<"$readme" || return 1
  grep -qF 'https://omni07.zone.example' <<<"$readme" || return 1
  grep -qF '`seat07-iso`' <<<"$readme"
}
test_guide_status_markers_name_existing_checks() {
  local markers checks
  markers="$(grep -oE '<!-- status: [a-z-]+ -->' "$LAB_ROOT/docs/hands-on.md" | awk '{print $3}' | sort)"
  checks="$(node -e 'console.log(Object.keys(require(process.argv[1]).CHECKS).sort().join("\n"))' "$LAB_ROOT/workspace/lab-guide/status.js")"
  [[ -n "$markers" && "$markers" == "$checks" ]]
}
test_guide_reads_concatenated_omni_json() {
  node -e '
    const { splitJson } = require(process.argv[1]);
    const objects = splitJson(`{"metadata":{"id":"a"},"spec":{"note":"} {"}}\n{"metadata":{"id":"b"}}`);
    process.exit(objects.length === 2 && objects[1].metadata.id === "b" ? 0 : 1);
  ' "$LAB_ROOT/workspace/lab-guide/status.js"
}
test_guide_names_a_machine_that_rejects_its_configuration() {
  local bin="$WORK/omni-bin" text
  mkdir -p "$bin"
  cat >"$bin/omnictl" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  clusterstatus) printf '{"metadata":{"id":"seat02"},"spec":{"ready":false,"machines":{"total":3,"healthy":1}}}\n' ;;
  clustermachinestatuses)
    printf '{"metadata":{"id":"aaaaaaaa-1111","labels":{"omni.sidero.dev/cluster":"seat02"}},"spec":{"lastconfigerror":"2 errors occurred:\\n\\t* KubeControllerManagerConfig: kube-controller-manager image cannot be empty\\n\\t* the following document kinds are only allowed on control plane machines: [KubeControllerManagerConfig]\\n\\n"}}\n'
    printf '{"metadata":{"id":"bbbbbbbb-2222","labels":{"omni.sidero.dev/cluster":"seat02"}},"spec":{"lastconfigerror":"bad patch"}}\n'
    printf '{"metadata":{"id":"cccccccc-3333","labels":{"omni.sidero.dev/cluster":"seat02"}},"spec":{"lastconfigerror":""}}\n'
    printf '{"metadata":{"id":"dddddddd-4444","labels":{"omni.sidero.dev/cluster":"other"}},"spec":{"lastconfigerror":"elsewhere"}}\n'
    ;;
  machinelabels) printf '{"metadata":{"id":"aaaaaaaa-1111","labels":{"talos-worker-a":null}}}\n{"metadata":{"id":"bbbbbbbb-2222","labels":{"omni.sidero.dev/x":"y"}}}\n' ;;
  *) exit 64 ;;
esac
EOF
  chmod +x "$bin/omnictl"
  text="$(PATH="$bin:$PATH" node -e 'require(process.argv[1]).CHECKS.cluster().then((r) => console.log(JSON.stringify(r)))' "$LAB_ROOT/workspace/lab-guide/status.js")" || return 1
  [[ "$(jq -r .done <<<"$text")" == false ]] || return 1
  [[ "$(jq -r .text <<<"$text")" == "Cluster seat02: 1 of 3 machines healthy, not ready yet. talos-worker-a rejected its configuration: KubeControllerManagerConfig: kube-controller-manager image cannot be empty; the following document kinds are only allowed on control plane machines: [KubeControllerManagerConfig]. bbbbbbbb rejected its configuration: bad patch" ]]
}
test_guide_extension_packs_reproducibly() {
  local first listing
  seat_build_guide || return 1
  first="$(sha256sum "$(seat_guide_vsix)" | cut -d' ' -f1)"
  seat_build_guide || return 1
  [[ "$(sha256sum "$(seat_guide_vsix)" | cut -d' ' -f1)" == "$first" ]] || return 1
  listing="$(unzip -Z1 "$(seat_guide_vsix)")"
  for entry in extension.vsixmanifest extension/package.json extension/extension.js extension/status.js extension/media/guide.js extension/media/guide.css; do
    grep -qxF "$entry" <<<"$listing" || return 1
  done
}
test_guide_seat_info_carries_the_seat_links() {
  local info
  seat_use 3
  printf 'student03\tstudent03@zone.example\t%s\thash\tid\n' "$SECRET_PASSWORD" >"$SHARED_STATE/users.tsv"
  info="$(seat_render_seat_info)"
  jq -e '.seat == "03" and .email == "student03@zone.example" and .links.omni == "https://omni03.zone.example" and .links.proxmox == "https://pve0.zone.example" and .links.site == "https://team03.zone.example" and .upgrade.talos == "1.14.6" and .upgrade.kubernetes == "1.37.2"' <<<"$info" >/dev/null || return 1
  [[ "$(jq -r .password <<<"$info" | wc -c)" -gt 1 ]]
}

guide_yaml_blocks() {
  local block="" inside=false line
  while IFS= read -r line; do
    if [[ "$inside" == true && "$line" == '```' ]]; then
      printf '%s\0' "$block"
      inside=false
      block=""
    elif [[ "$inside" == true ]]; then
      block+="$line"$'\n'
    elif [[ "$line" == '```yaml' ]]; then
      inside=true
    fi
  done <"$LAB_ROOT/docs/hands-on.md"
}
test_guide_shows_each_patch_the_rehearsal_applies() {
  local patch block found
  for patch in "$LAB_ROOT"/patches/*.yaml; do
    found=false
    while IFS= read -r -d '' block; do
      [[ "$block" == "$(<"$patch")"$'\n' ]] && found=true
    done < <(guide_yaml_blocks)
    [[ "$found" == true ]] || return 1
  done
}

test_upgrade_reads_each_node_version_and_state() {
  local states
  lab_kubectl() {
    printf '%s\n' '{"items":[
      {"metadata":{"name":"talos-b"},"spec":{"unschedulable":true},"status":{"nodeInfo":{"osImage":"Talos (v1.14.6)","kubeletVersion":"v1.37.1"},"conditions":[{"type":"Ready","status":"False"}]}},
      {"metadata":{"name":"talos-a"},"spec":{},"status":{"nodeInfo":{"osImage":"Talos (v1.14.5)","kubeletVersion":"v1.37.1"},"conditions":[{"type":"Ready","status":"True"}]}}]}'
  }
  states="$(upgrade_node_states)"
  [[ "$states" == "talos-a talos=1.14.5 kubelet=1.37.1 ready=True schedulable"$'\n'"talos-b talos=1.14.6 kubelet=1.37.1 ready=False cordoned" ]]
}
test_upgrade_reports_an_unreadable_cluster() {
  lab_kubectl() { return 1; }
  [[ "$(upgrade_node_states)" == unreadable ]]
}

test_isolation_keeps_each_seat_to_itself() {
  local rules line_of
  printf '192.0.2.53\n' >"$HOST_STATE/host-dns"
  rules="$(host_render_isolation)"
  line_of() { grep -nF -- "$1" <<<"$rules" | head -1 | cut -d: -f1; }
  grep -qF 'elements = { 192.0.2.53 }' <<<"$rules" || return 1
  [[ "$(grep -cE 'ip saddr 10\.88\.[0-9]+\.0/24 ip daddr 10\.88\.[0-9]+\.0/24 accept' <<<"$rules")" == "$SEAT_MAX" ]] || return 1
  grep -qF 'ip saddr 10.88.7.0/24 ip daddr 10.88.7.0/24 accept' <<<"$rules" || return 1
  grep -qF '10.0.0.0/8' <<<"$rules" && grep -qF '169.254.0.0/16' <<<"$rules" && grep -qF '192.168.0.0/16' <<<"$rules" || return 1
  (($(line_of '@resolvers meta l4proto') < $(line_of 'ip daddr @blocked drop'))) || return 1
  (($(line_of 'ip saddr 10.88.20.0/24 ip daddr 10.88.20.0/24 accept') < $(line_of 'ip daddr @blocked drop'))) || return 1
  (($(line_of 'udp dport 67 accept') < $(line_of '    drop'))) || return 1
  [[ "$(grep -cF 'ip saddr != 10.88.0.0/16 accept' <<<"$rules")" == 2 ]]
}

lab_strict() {
  LAB_ROOT="$LAB_ROOT" WORK="$WORK" bash -euo pipefail -c "$(declare -f load_libs)"$'\nload_libs\n'"$1"
}

test_isolation_check_runs_with_one_seat_and_with_two() {
  printf '192.0.2.53\n' >"$HOST_STATE/host-dns"
  lab_strict "$(
    cat <<'EOF'
pve_ssh() {
  case "$1" in
    "ip -4 -o route get"*) printf '1.1.1.1 via 192.0.2.1 dev vmbr0 src 192.0.2.10 uid 0\n' ;;
    "pct exec"*"bash -s")
      printf '%s\n' "$1" >>"$FAKE/probed"
      awk '/^probe / {print $2, ($2 == "own-omni" || $2 == "internet") ? "open" : "closed"}'
      ;;
    "pct exec"*"getent hosts"*) printf '203.0.113.7 factory.talos.dev\n' ;;
    *) return 64 ;;
  esac
}
host_verify_isolation 01 01 2>"$FAKE/one"
host_verify_isolation 01 $'01\n02' 2>"$FAKE/two"
EOF
  )" || return 1
  grep -qF 'not the host' "$FAKE/one" || return 1
  ! grep -qF 'or seat' "$FAKE/one" || return 1
  grep -qF 'not the host or seat 02' "$FAKE/two" || return 1
  [[ "$(cat "$FAKE/probed")" == $'pct exec 9014 -- bash -s\npct exec 9014 -- bash -s' ]]
}

test_cf_allowlist_permits_the_access_tunnel_and_hostname() {
  LAB_TUNNEL_NAME=talos-lab-access-0
  cf_allowed tunnels create --name talos-lab-access-0 --config-source cloudflare || return 1
  cf_refused tunnels create --name talos-lab-access-1 --config-source cloudflare || return 1
  LAB_TUNNEL_HOSTNAME=ssh0.zone.example
  cf_allowed dns records create -z zone.example --body '{"type":"CNAME","name":"ssh0.zone.example","content":"x.cfargotunnel.com"}' || return 1
  LAB_TUNNEL_HOSTNAME=ssh1.zone.example
  cf_refused dns records create -z zone.example --body '{"type":"CNAME","name":"ssh1.zone.example","content":"x.cfargotunnel.com"}' || return 1
  LAB_TUNNEL_HOSTNAME=ssh2.zone.example
  cf_refused dns records create -z zone.example --body '{"type":"CNAME","name":"ssh2.zone.example","content":"x.cfargotunnel.com"}'
}
test_host_layer_does_not_claim_the_access_tunnel() {
  ! cf_tunnel_name_owned talos-lab-access-0 && ! cf_hostname_owned ssh0.zone.example
}
test_cf_allowlist_limits_access_applications_to_the_lab_one() {
  local body
  CF_ACCESS_TOKEN_ID=token_uuid
  body="$(access_render_app)"
  cf_allowed zero-trust access applications create --body "$body" || return 1
  jq -e '.domain == "ssh0.zone.example" and .policies == [{name: "talos-lab-access-0", decision: "non_identity", include: [{service_token: {token_id: "token_uuid"}}]}] and .type == "self_hosted"' <<<"$body" >/dev/null || return 1
  cf_refused zero-trust access applications create --body "$(jq -c '.domain = "vpn.zone.example"' <<<"$body")" || return 1
  cf_refused zero-trust access applications create --body "$(jq -c '.name = "vpn"' <<<"$body")" || return 1
  cf_refused zero-trust access applications create --body "$(jq -c '.type = "ssh"' <<<"$body")" || return 1
  cf_refused zero-trust access applications delete other-app --force || return 1
  CF_ACCESS_APP_ID=access-app
  cf_allowed zero-trust access applications delete access-app --force || return 1
  cf_refused zero-trust access applications delete other-app --force || return 1
  cf_refused zero-trust access applications update access-app --body "$body"
}
test_cf_allowlist_limits_service_tokens_to_the_lab_one() {
  cf_allowed zero-trust access service-tokens create --name talos-lab-access || return 1
  cf_refused zero-trust access service-tokens create --name ci || return 1
  cf_refused zero-trust access service-tokens delete other-token --force || return 1
  CF_ACCESS_TOKEN_ID=access-token
  cf_allowed zero-trust access service-tokens delete access-token --force || return 1
  cf_refused zero-trust access service-tokens delete other-token --force || return 1
  cf_refused zero-trust access service-tokens refresh access-token
}
test_access_snapshot_covers_everything_but_access_resources() {
  local snapshot
  printf '[{"id":"home-tunnel-id","name":"home-tunnel","deleted_at":null},{"id":"host-id","name":"talos-lab-host-0","deleted_at":null},{"id":"access-id","name":"talos-lab-access-0","deleted_at":null}]\n' >"$FAKE/cf-tunnels"
  printf '[{"id":"ssh-rec","name":"ssh0.zone.example","type":"CNAME","content":"access-id.cfargotunnel.com"},{"id":"pve-rec","name":"pve0.zone.example","type":"CNAME","content":"host-id.cfargotunnel.com"}]\n' >"$FAKE/cf-dns"
  snapshot="$(cf_snapshot_access_others)" || return 1
  [[ "$snapshot" == "$(printf '%s\n' 'access-app other-app vpn vpn.zone.example' 'dns pve-rec pve0.zone.example CNAME host-id.cfargotunnel.com' 'service-token other-token ci' 'tunnel home-tunnel-id home-tunnel' 'tunnel host-id talos-lab-host-0' | sort)" ]] || return 1
  [[ "$(cf_snapshot_others)" == "$(printf '%s\n' 'dns ssh-rec ssh0.zone.example CNAME access-id.cfargotunnel.com' 'tunnel access-id talos-lab-access-0' 'tunnel home-tunnel-id home-tunnel' | sort)" ]] || return 1
  cf_lookup_access || return 1
  [[ "$CF_ACCESS_APP_ID" == access-app && "$CF_ACCESS_TOKEN_ID" == access-token ]]
}
test_access_bootstrap_matches_the_lab_pins_and_paths() {
  local script="$LAB_ROOT/tools/access-bootstrap.sh"
  grep -qxF "CLOUDFLARED_VERSION=$HOST_CLOUDFLARED_VERSION" "$script" || return 1
  grep -qxF "CLOUDFLARED_SHA256=$HOST_CLOUDFLARED_SHA256" "$script" || return 1
  grep -qxF "UNIT=$ACCESS_REMOTE_UNIT" "$script" || return 1
  grep -qxF "BIN=$ACCESS_REMOTE_BIN" "$script" || return 1
  grep -qxF "ETC=$ACCESS_REMOTE_ETC" "$script"
}
test_access_bootstrap_carries_the_key_and_token_it_validates() {
  local script key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPUBLICKEYFORTESTS talos-lab-site'
  mkdir -p "$ACCESS_STATE/ssh" "$WORK/notroot"
  printf '%s\n' "$key" >"$ACCESS_STATE/ssh/id_ed25519.pub"
  mkdir -p "$(access_host_state)"
  printf '%s' "$LONG_CONNECTOR_TOKEN" >"$(access_host_state)/connector-token"
  script="$(access_render_bootstrap)" || return 1
  bash -n <<<"$script" || return 1
  [[ "$(sed -n 2p <<<"$script")" == "set -- '$key' '$LONG_CONNECTOR_TOKEN'" ]] || return 1
  [[ "$(tail -n +3 <<<"$script")" == "$(tail -n +2 "$LAB_ROOT/tools/access-bootstrap.sh")" ]] || return 1
  printf '#!/bin/sh\necho 1000\n' >"$WORK/notroot/id"
  chmod 755 "$WORK/notroot/id"
  ! PATH="$WORK/notroot:$PATH" bash <<<"$script" 2>"$WORK/err" >/dev/null || return 1
  [[ "$(cat "$WORK/err")" == "run this as root" ]] || return 1
  ! bash "$LAB_ROOT/tools/access-bootstrap.sh" 'ssh-rsa AAAA' "$LONG_CONNECTOR_TOKEN" 2>"$WORK/err" || return 1
  grep -qF 'not an ssh-ed25519 public key' "$WORK/err"
}
test_pve_ssh_goes_through_access_only_when_set() {
  PVE_SSH_KEY=key PVE_SSH_KNOWN_HOSTS=known
  pve_ssh_options
  [[ " ${PVE_SSH_OPTIONS[*]} " == *" ConnectTimeout=10 "* && " ${PVE_SSH_OPTIONS[*]} " != *ProxyCommand* ]] || return 1
  PVE_SSH_ACCESS="$WORK/token.env"
  pve_ssh_options
  [[ " ${PVE_SSH_OPTIONS[*]} " == *" ProxyCommand=$LAB_STATE/shared/bin/cloudflared access ssh --hostname %h "* ]] || return 1
  [[ " ${PVE_SSH_OPTIONS[*]} " == *" ControlPath=none "* && " ${PVE_SSH_OPTIONS[*]} " != *ConnectTimeout=10* ]]
}
test_pve_access_needs_the_api_forwarded_to_localhost() {
  mkdir -p "$LAB_STATE/shared/bin"
  printf '#!/bin/sh\n' >"$LAB_STATE/shared/bin/cloudflared"
  chmod 755 "$LAB_STATE/shared/bin/cloudflared"
  printf 'TUNNEL_SERVICE_TOKEN_ID=id.access\nTUNNEL_SERVICE_TOKEN_SECRET=%s\n' "$SECRET_PASSWORD" >"$WORK/token.env"
  PVE_SSH_ACCESS="$WORK/token.env" PVE_SSH=root@ssh0.zone.example PVE_URL=https://pve.example:8006
  ! pve_access_open 2>"$WORK/err" || return 1
  grep -qF 'must be https://127.0.0.1:<port>' "$WORK/err" || return 1
  [[ "$TUNNEL_SERVICE_TOKEN_ID" == id.access ]]
}

test_exit_hooks_run_only_in_the_process_that_registered_them() {
  lab_strict "$(
    cat <<'EOF'
parent_hook() { printf 'parent %s\n' "$BASHPID" >>"$FAKE/hooks"; }
child_hook() { printf 'child\n' >>"$FAKE/hooks"; }
lab_on_exit parent_hook
lab_on_exit parent_hook
inner="$(lab_on_exit child_hook; printf 'inner done')"
printf 'after %s\n' "$inner" >>"$FAKE/hooks"
printf 'main %s\n' "$BASHPID" >>"$FAKE/main"
EOF
  )" || return 1
  [[ "$(cat "$FAKE/hooks")" == "$(printf 'child\nafter inner done\nparent %s' "$(awk '{print $2}' "$FAKE/main")")" ]]
}

test_access_target_sends_every_call_through_access() {
  local file="$WORK/target.env" var
  access_render_target site-host 11111111-2222-3333-4444-555555555555 "$(printf 'A%.0s' {1..43})=" >"$file"
  (
    source "$file"
    for var in PVE_URL PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET PVE_TLS_PIN PVE_DISK_STORAGE PVE_SSH PVE_SSH_KEY PVE_SSH_KNOWN_HOSTS PVE_SSH_ACCESS; do
      [[ -n "${!var:-}" ]] || exit 1
    done
    [[ "$PVE_URL" == https://127.0.0.1:18006 && "$PVE_SSH" == root@ssh0.zone.example && "$PVE_TOKEN_ID" == 'talos-lab@pve!kit' ]] || exit 1
    [[ "$PVE_SSH_ACCESS" == "$ACCESS_STATE/service-token.env" && "$PVE_SSH_KEY" == "$ACCESS_STATE/ssh/id_ed25519" && "$PVE_DISK_STORAGE" == lab-disks ]] || exit 1
    [[ "$PVE_SSH_KNOWN_HOSTS" == "$HOST_STATE/access/known_hosts" ]]
  )
}

test_address_hook_follows_a_new_dhcp_address() {
  local bin="$WORK/hook-bin" hook="$WORK/hook.sh" hosts="$WORK/hosts"
  mkdir -p "$bin"
  printf '#!/bin/sh\necho site-host\n' >"$bin/hostname"
  printf '#!/bin/sh\n:\n' >"$bin/logger"
  printf '#!/bin/sh\necho "$*" >>"%s/systemd-run"\n' "$WORK" >"$bin/systemd-run"
  chmod 755 "$bin"/*
  host_render_address_hook | sed "s|^  hosts=/etc/hosts\$|  hosts=$hosts|" >"$hook"
  run_hook() { env PATH="$bin:$PATH" reason="$1" new_ip_address="$2" sh -c ". '$hook'"; }
  printf '127.0.0.1\tlocalhost\n10.1.2.3\tsite-host.internal site-host\n::1 localhost\n' >"$hosts"
  run_hook RENEW 10.1.2.3 || return 1
  [[ ! -e "$WORK/systemd-run" ]] || return 1
  run_hook EXPIRE 10.9.9.9 || return 1
  [[ ! -e "$WORK/systemd-run" ]] || return 1
  run_hook BOUND 10.1.20.30 || return 1
  [[ "$(cat "$hosts")" == "$(printf '127.0.0.1\tlocalhost\n10.1.20.30\tsite-host.internal site-host\n::1 localhost')" ]] || return 1
  [[ "$(grep -c 'pvesh set /cluster/sdn' "$WORK/systemd-run")" == 1 ]] || return 1
  printf '127.0.0.1\tlocalhost\n' >"$hosts"
  run_hook REBOOT 10.4.5.6 || return 1
  grep -qxF "$(printf '10.4.5.6\tsite-host.internal site-host')" "$hosts"
}

test_campus_rules_drop_new_connections_except_the_opened_services() {
  local rules
  rules="$(campus_render_rules ens18)"
  grep -qxF '    iifname != "ens18" accept' <<<"$rules" || return 1
  ! grep -qF 'tcp dport' <<<"$rules" || return 1
  [[ "$(tail -3 <<<"$rules" | head -1)" == '    drop' ]] || return 1
  rules="$(campus_render_rules ens18 ssh proxmox)"
  grep -qxF '    tcp dport { 22, 8006, 3128 } accept' <<<"$rules" || return 1
  rules="$(campus_render_rules ens18 proxmox)"
  grep -qxF '    tcp dport { 8006, 3128 } accept' <<<"$rules" || return 1
  grep -qxF '    udp dport 68 accept' <<<"$rules" && grep -qxF '    ct state established,related accept' <<<"$rules"
}
test_campus_starts_from_everything_open_without_rules() {
  [[ "$(campus_open_services $'none\nuplink ens18')" == $'ssh\nproxmox' ]] || return 1
  [[ "$(campus_open_services $'rules\nopen proxmox\nuplink ens18')" == proxmox ]] || return 1
  [[ -z "$(campus_open_services $'rules\nuplink ens18')" ]]
}
test_campus_refuses_a_host_reached_without_access() {
  printf 'PVE_URL=https://10.0.0.5:8006\nPVE_NODE=pve\nPVE_TOKEN_ID=t\nPVE_TOKEN_SECRET=s\nPVE_TLS_PIN=p\nPVE_DISK_STORAGE=local\nPVE_SSH=root@10.0.0.5\nPVE_SSH_KEY=k\nPVE_SSH_KNOWN_HOSTS=h\n' >"$HOST_STATE/target.env"
  printf 'LAB_CF_ACCOUNT_ID=acct\nLAB_TUNNEL_ZONE=zone.example\nLAB_OMNI_EULA_NAME=n\nLAB_OMNI_EULA_EMAIL=e\n' >"$WORK/lab.env"
  ! (LAB_CONFIG="$WORK/lab.env" campus_load campus) 2>"$WORK/err" || return 1
  grep -qF 'need a target reached through Cloudflare Access' "$WORK/err"
}

test_guide_says_to_connect_again_when_the_login_expires() {
  local bin="$WORK/kube-bin" text
  mkdir -p "$bin" "$WORK/home/.kube"
  : >"$WORK/home/.kube/config"
  printf '#!/bin/sh\necho "E1118 memcache.go:381] Couldn'"'"'t get current server API group list err=the server has asked for the client to provide credentials" >&2\nexit 1\n' >"$bin/kubectl"
  chmod 755 "$bin/kubectl"
  text="$(HOME="$WORK/home" PATH="$bin:$PATH" node -e 'require(process.argv[1]).runChecks({}, ["nodes"]).then((r) => console.log(r.nodes.text))' "$LAB_ROOT/workspace/lab-guide/status.js")" || return 1
  [[ "$text" == "Your cluster login has expired. Run connect again" ]]
}

fake_flaky_ssh() {
  local message="$1" failures="$2"
  printf '%s\n' "$failures" >"$FAKE/ssh-failures"
  : >"$FAKE/ssh-calls"
  cat >"$WORK/flaky-bin/ssh" <<EOF
#!/usr/bin/env bash
echo call >>"$FAKE/ssh-calls"
left="\$(cat "$FAKE/ssh-failures")"
if ((left > 0)); then
  echo \$((left - 1)) >"$FAKE/ssh-failures"
  echo "$message" >&2
  exit 255
fi
cat
echo "ran \${*: -1}"
EOF
  chmod 755 "$WORK/flaky-bin/ssh"
}
test_pve_ssh_retries_when_the_shared_connection_died_before_the_command() {
  local out
  mkdir -p "$WORK/flaky-bin"
  PVE_SSH_KEY=key PVE_SSH_KNOWN_HOSTS=known PVE_SSH=root@host
  fake_flaky_ssh 'mux_client_request_session: read from master failed: Broken pipe' 2
  out="$(printf 'script\n' | PATH="$WORK/flaky-bin:$PATH" pve_ssh 'bash -s' 2>"$WORK/err")" || return 1
  [[ "$out" == $'script\nran bash -s' && "$(grep -c . "$FAKE/ssh-calls")" == 3 ]] || return 1
  [[ ! -s "$WORK/err" ]]
}
test_pve_ssh_does_not_retry_once_the_command_started() {
  mkdir -p "$WORK/flaky-bin"
  PVE_SSH_KEY=key PVE_SSH_KNOWN_HOSTS=known PVE_SSH=root@host
  fake_flaky_ssh 'client_loop: send disconnect: Broken pipe' 1
  ! PATH="$WORK/flaky-bin:$PATH" pve_ssh 'pct create 9010' </dev/null >/dev/null 2>"$WORK/err" || return 1
  [[ "$(grep -c . "$FAKE/ssh-calls")" == 1 ]] && grep -qF 'client_loop: send disconnect' "$WORK/err" || return 1
  grep -qF 'error: ssh to root@host ended with exit 255 while running: pct create 9010' "$WORK/err"
}

add_test_host() {
  mkdir -p "$LAB_HOSTS_STATE/$1"
  printf 'HOST_INDEX=%s\nHOST_SEATS=%s\n' "$2" "$3" >"$LAB_HOSTS_STATE/$1/host.env"
}
test_hosts_are_ordered_by_index_not_name() {
  add_test_host azure 2 10
  add_test_host home 1 2
  [[ "$(hosts_names | paste -sd' ')" == "campus home azure" && "$(hosts_primary)" == campus ]]
}
test_seats_fill_hosts_in_index_order_up_to_each_count() {
  add_test_host home 1 1
  printf 'HOST_INDEX=0\nHOST_SEATS=2\n' >"$LAB_HOSTS_STATE/campus/host.env"
  seat_place 1 && seat_place 2 && seat_place 3 || return 1
  [[ "$(seat_host_of 1) $(seat_host_of 2) $(seat_host_of 03)" == "campus campus home" ]] || return 1
  [[ "$(host_seats_on campus | paste -sd' ') / $(host_seats_on home)" == "01 02 / 03" ]] || return 1
  seat_place 2 || return 1
  [[ "$(seat_host_of 2)" == campus ]] || return 1
  ! (seat_place 4) 2>"$WORK/err" || return 1
  grep -qF 'no host has room for seat 04: campus 2 of 2, home 1 of 1' "$WORK/err"
}
test_hosts_refuse_a_taken_index_and_a_bad_name() {
  printf 'LAB_CF_ACCOUNT_ID=acct\nLAB_TUNNEL_ZONE=zone.example\nLAB_OMNI_EULA_NAME=n\nLAB_OMNI_EULA_EMAIL=e\n' >"$WORK/lab.env"
  ! (LAB_CONFIG="$WORK/lab.env" hosts_add home 0 4) 2>"$WORK/err" || return 1
  grep -qF 'host campus already has index 0' "$WORK/err" || return 1
  ! (LAB_CONFIG="$WORK/lab.env" hosts_add Home 1 4) 2>/dev/null || return 1
  (LAB_CONFIG="$WORK/lab.env" hosts_add home 1 4) 2>/dev/null || return 1
  [[ "$(cat "$LAB_HOSTS_STATE/home/host.env")" == $'HOST_INDEX=1\nHOST_SEATS=4' ]]
}
test_a_second_host_routes_only_its_own_seats_and_proxmox() {
  local ingress
  add_test_host home 1 2
  mkdir -p "$LAB_SEATS_STATE/seat01" "$LAB_SEATS_STATE/seat05"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat01/host"
  printf 'home\n' >"$LAB_SEATS_STATE/seat05/host"
  host_select home
  ingress="$(host_render_ingress)" || return 1
  [[ "$(jq -r '[.[].hostname // empty] | join(" ")' <<<"$ingress")" == "pve1.zone.example omni05.zone.example kube05.zone.example shell05.zone.example" ]] || return 1
  [[ "$(host_tunnel_name) $(host_services | paste -sd' ')" == "talos-lab-host-1 talos-lab-cloudflared talos-lab-isolation" ]] || return 1
  host_select campus
  [[ "$(host_services | paste -sd' ')" == "talos-lab-dex talos-lab-cloudflared talos-lab-isolation" ]]
}
test_cf_allowlist_permits_each_hosts_tunnel_and_proxmox_name() {
  LAB_TUNNEL_NAME=talos-lab-host-3
  cf_allowed tunnels create --name talos-lab-host-3 --config-source cloudflare || return 1
  LAB_TUNNEL_HOSTNAME=pve3.zone.example
  cf_allowed dns records create -z zone.example --body '{"type":"CNAME","name":"pve3.zone.example","content":"x.cfargotunnel.com"}' || return 1
  LAB_TUNNEL_HOSTNAME=pve.zone.example
  cf_refused dns records create -z zone.example --body '{"type":"CNAME","name":"pve.zone.example","content":"x.cfargotunnel.com"}' || return 1
  LAB_TUNNEL_NAME=talos-lab-host
  cf_refused tunnels create --name talos-lab-host --config-source cloudflare
}
test_owned_records_carry_the_tunnel_they_point_at() {
  printf '[{"id":"a","name":"omni05.zone.example","type":"CNAME","content":"t1.cfargotunnel.com"},{"id":"b","name":"www.zone.example","type":"CNAME","content":"x"},{"id":"c","name":"pve1.zone.example","type":"CNAME","content":"t2.cfargotunnel.com"}]\n' >"$FAKE/cf-dns"
  [[ "$(cf_owned_records)" == $'omni05.zone.example t1.cfargotunnel.com\npve1.zone.example t2.cfargotunnel.com' ]]
}
test_access_names_follow_the_host_index() {
  CF_ACCESS_INDEX=2
  [[ "$(cf_access_name) $(cf_access_hostname)" == "talos-lab-access-2 ssh2.zone.example" ]] || return 1
  CF_ACCESS_TOKEN_ID=token_uuid
  cf_allowed zero-trust access applications create --body "$(access_render_app)" || return 1
  cf_refused zero-trust access applications create --body "$(access_render_app | jq -c '.domain = "ssh1.zone.example"')"
}
test_guide_links_each_seat_to_its_hosts_proxmox() {
  local readme
  add_test_host home 1 2
  host_select home
  seat_use 5
  readme="$(seat_render_readme)" || return 1
  grep -qF 'https://pve1.zone.example' <<<"$readme" && ! grep -qF 'pve<host>' <<<"$readme"
}

test_install_script_reports_every_key_the_lab_reads() {
  local state key
  state="$(bash "$LAB_ROOT/tools/proxmox-install.sh" status 2>/dev/null)" || return 1
  for key in debian kernel pve_kernel proxmox network revert_armed dhclient uplink; do
    grep -qE "^$key=" <<<"$state" || return 1
  done
  ! bash "$LAB_ROOT/tools/proxmox-install.sh" reinstall-everything 2>/dev/null
}
test_install_status_values_are_read_by_key() {
  local state=$'debian=trixie\nkernel=pve\nnetwork=ifupdown2\nuplink=ens18 address=10.0.0.5'
  [[ "$(install_value kernel "$state") $(install_value network "$state") $(install_value uplink "$state")" == "pve ifupdown2 ens18" ]] || return 1
  [[ -z "$(install_value proxmox "$state")" ]]
}

test_local_seed_hands_the_vm_its_host_key_and_bootstrap() {
  local data
  add_test_host home 1 2
  host_select home
  CF_ACCESS_INDEX=1
  mkdir -p "$(local_dir)" "$(access_host_state)"
  ssh-keygen -q -t ed25519 -N '' -C home -f "$(local_dir)/ssh_host_ed25519_key"
  printf 'abcd-efgh-jkmn\n' >"$(local_dir)/root-password"
  printf '#!/usr/bin/env bash\nset -- %s\necho bootstrap\n' "'key' '$LONG_CONNECTOR_TOKEN'" >"$(access_host_state)/bootstrap.sh"
  data="$(local_render_user_data)" || return 1
  uv run --quiet --with pyyaml python -I -c '
import sys, yaml
d = yaml.safe_load(sys.stdin)
assert d["hostname"] == "home" and d["ssh_pwauth"] is False and d["manage_etc_hosts"] is False
assert d["ssh_keys"]["ed25519_private"].startswith("-----BEGIN OPENSSH PRIVATE KEY-----")
assert d["write_files"][0]["content"].splitlines()[2] == "echo bootstrap"
assert ["touch", "/etc/cloud/cloud-init.disabled"] in d["runcmd"]
' <<<"$data" || return 1
  local_ensure_keys 2>/dev/null || return 1
  [[ "$(cat "$(access_known_hosts)")" == "ssh1.zone.example $(cut -d' ' -f1,2 "$(local_dir)/ssh_host_ed25519_key.pub")" ]]
}

test_host_lists_succeed_under_set_e_when_the_last_seat_is_elsewhere() {
  add_test_host home 1 2
  mkdir -p "$LAB_SEATS_STATE/seat01" "$LAB_SEATS_STATE/seat02"
  printf 'home\n' >"$LAB_SEATS_STATE/seat01/host"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat02/host"
  lab_strict "$(
    cat <<'EOF'
add_test_host() { mkdir -p "$LAB_HOSTS_STATE/$1"; printf 'HOST_INDEX=%s\nHOST_SEATS=%s\n' "$2" "$3" >"$LAB_HOSTS_STATE/$1/host.env"; }
add_test_host azure 2 4
seats="$(host_seats_on home)"
primary="$(hosts_primary)"
none="$(seat_host_of 7)"
all="$(lab_seat_numbers)"
printf '%s|%s|%s|%s\n' "$seats" "$primary" "$none" "$(paste -sd' ' <<<"$all")" >"$FAKE/strict"
EOF
  )" || return 1
  [[ "$(cat "$FAKE/strict")" == "01|campus||01 02" ]]
}

test_pve_remote_runs_a_dropped_script_again_and_prints_one_result() {
  local out
  mkdir -p "$WORK/flaky-bin"
  PVE_SSH_KEY=key PVE_SSH_KNOWN_HOSTS=known PVE_SSH=root@host
  fake_flaky_ssh 'Connection to host closed by remote host.' 1
  out="$(printf 'echo ensure\n' | PATH="$WORK/flaky-bin:$PATH" pve_remote A=1 2>"$WORK/err")" || return 1
  [[ "$out" == $'echo ensure\nran env A=1  bash -s' && "$(grep -c . "$FAKE/ssh-calls")" == 2 ]] || return 1
  grep -qF 'running the script again' "$WORK/err"
}

test_host_verify_refuses_a_hidden_host_and_names_the_way_back() {
  ! (
    pve_ssh() { [[ "$1" == "systemctl is-enabled talos-lab-cloudflared"* ]] && printf 'disabled\n'; }
    host_verify
  ) 2>"$WORK/err" || return 1
  grep -qF 'campus is hidden from the internet, run ./lab host show campus first' "$WORK/err"
}

test_host_hide_stops_the_connector_and_names_a_site_still_answering() {
  local host
  LAB_TUNNEL_ZONE=zone.example
  mkdir -p "$LAB_SEATS_STATE/seat01" "$LAB_SEATS_STATE/seat02"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat01/host"
  printf 'campus\n' >"$LAB_SEATS_STATE/seat02/host"
  ! (
    host_load() { :; }
    pve_ssh() {
      printf '%s\n' "$1" >>"$FAKE/ssh-calls"
      [[ "$1" != "systemctl is-enabled"* ]] || printf 'enabled\n'
    }
    host_public_status() {
      printf '%s\n' "$1" >>"$FAKE/probed"
      [[ "$1" == https://team02.* ]] && printf '200' || printf '530'
    }
    host_hide_one campus
  ) 2>"$WORK/err" || return 1
  grep -qxF 'systemctl disable --now --quiet talos-lab-cloudflared' "$FAKE/ssh-calls" || return 1
  for host in auth pve0 omni01 kube01 shell01 omni02 kube02 shell02 team01 team02; do
    grep -qxF "https://$host.zone.example/" "$FAKE/probed" || return 1
  done
  grep -qF 'team02 (200) still answer' "$WORK/err"
}

test_seat_omnictl_runs_again_when_its_forward_drops_and_prints_one_result() {
  local out
  mkdir -p "$WORK/omni-bin" "$LAB_SEATS_STATE/seat01"
  printf 'key\n' >"$LAB_SEATS_STATE/seat01/omni-service-account.key"
  cat >"$WORK/omni-bin/omnictl" <<'EOF'
#!/bin/sh
runs=$(cat "$FAKE/omni-runs" 2>/dev/null || echo 0)
echo $((runs + 1)) >"$FAKE/omni-runs"
if [ "$runs" = 0 ]; then
  echo partial
  echo 'dial tcp 127.0.0.1:18080: connect: connection refused' >&2
  exit 1
fi
echo "done $*"
EOF
  chmod 755 "$WORK/omni-bin/omnictl"
  out="$(
    SEAT=01 SEAT_STATE="$LAB_SEATS_STATE/seat01"
    host_omnictl_local() { printf '%s' "$WORK/omni-bin/omnictl"; }
    seat_omni_forward_open() { SEAT_OMNI_FORWARD=http://127.0.0.1:1; }
    seat_omni_forward_close() { touch "$FAKE/reopened"; }
    pve_ssh_forward_alive() { [[ "$(cat "$FAKE/omni-runs" 2>/dev/null)" != 1 || -e "$FAKE/reopened" ]]; }
    seat_omnictl get clusters -o json 2>"$WORK/err"
  )" || return 1
  [[ "$out" == "done get clusters -o json" && "$(cat "$FAKE/omni-runs")" == 2 ]] || return 1
  grep -qF 'dropped during omnictl get clusters, running it again' "$WORK/err" || return 1
  ! grep -qF 'connection refused' "$WORK/err"
}

test_seat_omnictl_reports_a_failure_on_a_live_forward_once() {
  local status=0
  mkdir -p "$WORK/omni-bin" "$LAB_SEATS_STATE/seat01"
  printf 'key\n' >"$LAB_SEATS_STATE/seat01/omni-service-account.key"
  printf '#!/bin/sh\necho run >>"$FAKE/omni-runs"\necho "NotFound" >&2\nexit 3\n' >"$WORK/omni-bin/omnictl"
  chmod 755 "$WORK/omni-bin/omnictl"
  (
    SEAT=01 SEAT_STATE="$LAB_SEATS_STATE/seat01"
    host_omnictl_local() { printf '%s' "$WORK/omni-bin/omnictl"; }
    seat_omni_forward_open() { SEAT_OMNI_FORWARD=http://127.0.0.1:1; }
    pve_ssh_forward_alive() { :; }
    seat_omnictl delete link x
  ) 2>"$WORK/err" || status=$?
  [[ "$status" == 3 && "$(grep -c . "$FAKE/omni-runs")" == 1 ]] || return 1
  grep -qxF 'NotFound' "$WORK/err"
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
