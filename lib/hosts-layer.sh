readonly HOSTS_NAME_PATTERN='^[a-z][a-z0-9-]{0,15}$'

LAB_HOSTS_STATE="$LAB_STATE/hosts"
SHARED_STATE="$LAB_STATE/shared"
HOST_NAME=""
HOST_INDEX=""
HOST_SEATS=""

hosts_names() {
  local file index
  for file in "$LAB_HOSTS_STATE"/*/host.env; do
    [[ -r "$file" ]] || continue
    index="$(sed -n 's/^HOST_INDEX=//p' "$file")"
    printf '%s %s\n' "$index" "$(basename "$(dirname "$file")")"
  done | sort -n | cut -d' ' -f2
}

hosts_primary() {
  local name
  for name in $(hosts_names); do
    if [[ "$(sed -n 's/^HOST_INDEX=//p' "$LAB_HOSTS_STATE/$name/host.env")" == 0 ]]; then
      printf '%s\n' "$name"
    fi
  done
}

host_select() {
  local name="$1" file
  [[ "$name" =~ $HOSTS_NAME_PATTERN ]] || die "host names are lowercase letters, digits and dashes, got \"$name\""
  file="$LAB_HOSTS_STATE/$name/host.env"
  [[ -r "$file" ]] || die "no host named $name. Add it with ./lab hosts add $name <index> <seats>"
  HOST_INDEX="$(sed -n 's/^HOST_INDEX=//p' "$file")"
  HOST_SEATS="$(sed -n 's/^HOST_SEATS=//p' "$file")"
  [[ "$HOST_INDEX" =~ ^[0-9]$ && "$HOST_SEATS" =~ ^[0-9]+$ ]] || die "$file needs HOST_INDEX from 0 to 9 and HOST_SEATS"
  HOST_NAME="$name"
  HOST_STATE="$LAB_HOSTS_STATE/$name"
  LAB_PVE_TARGET="$HOST_STATE/target.env"
}

host_load() {
  lab_load_config
  host_select "$1"
  mkdir -p "$SHARED_STATE" "$LAB_SEATS_STATE"
  pve_load_target || exit 1
}

host_switch() {
  [[ "$1" == "$HOST_NAME" ]] && return 0
  host_select "$1"
  pve_load_target || exit 1
}

host_pve_label() {
  printf 'pve%s' "$HOST_INDEX"
}

hosts_require_primary() {
  [[ -n "$(hosts_primary)" ]] || die "no host has index 0, which runs the lab sign-in. Add one with ./lab hosts add <name> 0 <seats>"
}

seat_host_of() {
  local file
  file="$LAB_SEATS_STATE/seat$(printf '%02d' "$((10#$1))")/host"
  if [[ -s "$file" ]]; then
    cat "$file"
  fi
}

host_seats_on() {
  local name="$1" dir
  for dir in "$LAB_SEATS_STATE"/seat[0-9][0-9]; do
    if [[ -s "$dir/host" && "$(<"$dir/host")" == "$name" ]]; then
      printf '%s\n' "${dir##*/seat}"
    fi
  done
}

lab_seat_numbers() {
  local dir
  for dir in "$LAB_SEATS_STATE"/seat[0-9][0-9]; do
    if [[ -d "$dir" ]]; then
      printf '%s\n' "${dir##*/seat}"
    fi
  done
}

seat_place() {
  local number="$1" seat name limit
  seat="$(printf '%02d' "$((10#$number))")"
  [[ -n "$(seat_host_of "$seat")" ]] && return 0
  for name in $(hosts_names); do
    limit="$(sed -n 's/^HOST_SEATS=//p' "$LAB_HOSTS_STATE/$name/host.env")"
    if (($(host_seats_on "$name" | grep -c . || true) < limit)); then
      mkdir -p "$LAB_SEATS_STATE/seat$seat"
      printf '%s\n' "$name" >"$LAB_SEATS_STATE/seat$seat/host"
      return 0
    fi
  done
  die "no host has room for seat $seat: $(hosts_capacity)"
}

hosts_capacity() {
  local name
  for name in $(hosts_names); do
    printf '%s %s of %s\n' "$name" "$(host_seats_on "$name" | grep -c . || true)" "$(sed -n 's/^HOST_SEATS=//p' "$LAB_HOSTS_STATE/$name/host.env")"
  done | paste -sd',' | sed 's/,/, /g'
}

hosts_add() {
  local name="$1" index="$2" seats="$3" other
  lab_load_config
  [[ "$name" =~ $HOSTS_NAME_PATTERN ]] || die "host names are lowercase letters, digits and dashes, got \"$name\""
  [[ "$index" =~ ^[0-9]$ ]] || die "a host index is a digit from 0 to 9, got \"$index\""
  [[ "$seats" =~ ^[0-9]+$ ]] || die "a host's seat count is a number, got \"$seats\""
  [[ ! -e "$LAB_HOSTS_STATE/$name/host.env" ]] || die "host $name already exists"
  for other in $(hosts_names); do
    [[ "$(sed -n 's/^HOST_INDEX=//p' "$LAB_HOSTS_STATE/$other/host.env")" != "$index" ]] || die "host $other already has index $index"
  done
  mkdir -p "$LAB_HOSTS_STATE/$name"
  chmod 700 "$LAB_HOSTS_STATE" "$LAB_HOSTS_STATE/$name"
  printf 'HOST_INDEX=%s\nHOST_SEATS=%s\n' "$index" "$seats" >"$LAB_HOSTS_STATE/$name/host.env"
  log "host $name added with index $index for $seats seats, its Proxmox at https://$(host_name "pve$index")"
}

hosts_set_seats() {
  local name="$1" seats="$2" placed
  lab_load_config
  host_select "$name"
  [[ "$seats" =~ ^[0-9]+$ ]] || die "a host's seat count is a number, got \"$seats\""
  placed="$(host_seats_on "$name" | grep -c . || true)"
  ((seats >= placed)) || die "host $name already holds $placed seats, delete some before lowering its count to $seats"
  printf 'HOST_INDEX=%s\nHOST_SEATS=%s\n' "$HOST_INDEX" "$seats" >"$HOST_STATE/host.env"
  log "host $name now takes $seats seats"
}

hosts_remove() {
  local name="$1"
  lab_load_config
  host_select "$name"
  [[ -z "$(host_seats_on "$name")" ]] || die "host $name still holds seats $(host_seats_on "$name" | paste -sd' ')"
  [[ ! -s "$HOST_STATE/connector-token" ]] || die "host $name still runs the lab, run ./lab host down $name first"
  [[ ! -s "$HOST_STATE/access/connector-token" ]] || die "host $name still has Cloudflare Access, run ./lab access down $name first"
  rm -rf "${HOST_STATE:?}"
  log "host $name removed from the lab"
}

hosts_list() {
  local name target placed
  lab_load_config
  for name in $(hosts_names); do
    host_select "$name"
    placed="$(host_seats_on "$name" | paste -sd' ')"
    target=none
    [[ -s "$HOST_STATE/target.env" ]] && target="$(sed -n 's/^PVE_NODE=//p' "$HOST_STATE/target.env")"
    printf '%-10s index %s  pve https://%s  node %-18s seats %s of %s: %s\n' \
      "$name" "$HOST_INDEX" "$(host_name "$(host_pve_label)")" "$target" \
      "$(host_seats_on "$name" | grep -c . || true)" "$HOST_SEATS" "${placed:-none}"
  done
}
