#!/usr/bin/env bash
# =============================================================================
# migrate.sh - oVirt -> Proxmox VE disk migration via a helper ("datamover") VM
#
# Lives in the shared NFS directory together with migrate.conf and disks.csv.
#
#   oVirt host:  ./migrate.sh export  <vm> [vm...]   shut down, move disks RO to
#                                                    the datamover, export qcow2
#                ./migrate.sh restore <vm> [vm...]   put disks back on the original
#                                                    VM (rollback), incl. boot disk
#                ./migrate.sh release <vm> [vm...]   detach disks from the datamover
#                                                    after a successful migration
#   PVE host:    ./migrate.sh import [--start]       listen + import + attach (+ start VM)
#   anywhere:    ./migrate.sh status [--watch [s]]   progress, rate, ETA
#                ./migrate.sh list                   VMs by size; on PVE: what is imported
#   oVirt host:  ./migrate.sh lookup <vm-name>...    disks of a VM + ready-made disks.csv lines
#
# Options: -y/--yes  -n/--dry-run  -f/--force  -s/--start  -r/--restore-on-abort  -w/--watch [sec]
# See README.md for configuration and procedure.
# =============================================================================
set -uo pipefail
export LC_ALL=C

BASE=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
CONF="${MIGRATE_CONF:-$BASE/migrate.conf}"   # override with MIGRATE_CONF=/path
CSV="$BASE/disks.csv"
LOGS="$BASE/logs"
STATE="$BASE/state"

# All settings live in migrate.conf - nothing customer-specific in this script.
# Runtime flags (set by command line options):
YES=0; DRY_RUN=0; FORCE=0; START_VM=0; WATCH=0; RESTORE_ON_ABORT=0

# ---- helpers ----------------------------------------------------------------
ts()   { date +%H:%M:%S; }
log()  { printf '%s  %s\n' "$(ts)" "$*"; }
warn() { printf '%s  WARN   %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s  ERROR  %s\n' "$(ts)" "$*" >&2; exit 1; }
hm()   { local s=${1:-0}; ((s < 0)) && s=0; printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60)); }
gib()  { awk -v b="${1:-0}" 'BEGIN{printf "%.1fG", b/1073741824}'; }

# ---- configuration -------------------------------------------------------------
# Required settings per command; "?NAME" = must be defined but may be empty.
VARS_OVIRT=(ENGINE_URL ENGINE_USER ENGINE_CA DATAMOVER_VM DM_INTERFACE DEFAULT_INTERFACE
            SHUTDOWN_TIMEOUT DEVICE_TIMEOUT SNAPSHOT_TIMEOUT PAR EXPORT_MAX_PCT)
VARS_PVE=(STORAGE MAX_POOL_PCT POLL ?DISK_OPTS)
VARS_STATUS=(STORAGE MAX_POOL_PCT EXPORT_MAX_PCT RATE_WINDOW STALL_SEC)
VARS_NUMERIC=(SHUTDOWN_TIMEOUT DEVICE_TIMEOUT SNAPSHOT_TIMEOUT PAR MAX_POOL_PCT EXPORT_MAX_PCT POLL RATE_WINDOW STALL_SEC)
VARS_OPTIONAL=(ENGINE_PASS ENGINE_PASS_FILE)

# Load migrate.conf and check that every setting the command needs is present.
# Stops early with a clear list instead of failing halfway with "unbound variable".
# Names prefixed with "?" must exist but may be empty.
load_config() {
  [[ -r $CONF ]] || die "config $CONF not found - see README (Configuration)"
  # The conf is sourced as root, so nobody else may be able to change it.
  [[ -z $(find "$CONF" -perm -o+w 2>/dev/null) ]] || die "$CONF is world-writable - fix with: chmod o-w $CONF"
  # shellcheck source=/dev/null
  source "$CONF" || die "error while reading $CONF"
  local v missing=() bad=()
  for v in "$@"; do
    if [[ $v == \?* ]]; then v=${v#\?}; [[ -v $v ]] || missing+=("$v"); continue; fi
    if [[ ! -v $v || -z ${!v} ]]; then missing+=("$v")
    elif [[ " ${VARS_NUMERIC[*]} " == *" $v "* && ! ${!v} =~ ^[1-9][0-9]*$ ]]; then bad+=("$v=${!v}"); fi
  done
  ((${#missing[@]} == 0)) || die "missing or empty in $CONF: ${missing[*]}"
  ((${#bad[@]} == 0))     || die "must be a whole number > 0 in $CONF: ${bad[*]}"
  [[ ! -v MAX_POOL_PCT ]]   || ((MAX_POOL_PCT <= 100))   || die "MAX_POOL_PCT must be <= 100 in $CONF"
  [[ ! -v EXPORT_MAX_PCT ]] || ((EXPORT_MAX_PCT <= 100)) || die "EXPORT_MAX_PCT must be <= 100 in $CONF"
  for v in "${VARS_OPTIONAL[@]}"; do [[ -v $v ]] || printf -v "$v" '%s' ""; done
}

confirm() { ((YES)) && return 0; local a; read -rp "$1 [y/N] " a; [[ $a == [yY] ]]; }

tmux_hint() {
  [[ -n ${TMUX:-} || -n ${STY:-} ]] && return 0
  warn "Not running inside tmux/screen - running in a tmux session is recommended."
  warn "An SSH disconnect would otherwise kill running transfers."
  ((YES)) || sleep 3
}

is_ovirt() { [[ -d /rhev/data-center ]]; }
is_pve()   { command -v qm >/dev/null 2>&1 && command -v pvesm >/dev/null 2>&1; }
host_kind() { if is_ovirt; then echo "an oVirt host"; elif is_pve; then echo "a PVE host"; else echo "neither an oVirt nor a PVE host"; fi; }

# Checked first in every host-specific command, before config or login, so running
# a command on the wrong host gives a clear message instead of a follow-up error.
need_host() { # ovirt|pve command
  case $1 in
    ovirt) is_ovirt || die "'$2' only works on the oVirt host - this is $(host_kind)" ;;
    pve)   is_pve   || die "'$2' only works on the PVE host - this is $(host_kind)" ;;
  esac
}

# All data lines of disks.csv, without comments and Windows line endings.
csv_all() {
  [[ -r $CSV ]] || die "$CSV not found"
  tr -d '\r' < "$CSV" | awk -F';' '{ gsub(/[ \t]*;[ \t]*/, ";"); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "") }
                                  $0 !~ /^(#|$)/ && NF >= 5'
}

# Catch typos in disks.csv before anything happens: invalid slots or IDs, duplicates,
# and exactly one boot disk per PVE VM. A wrong line here would move the wrong disk.
csv_check() {
  local errs
  errs=$(csv_all | awk -F';' '
    { key = $1 "-" $4
      if ($2 !~ /^[0-9]+$/)                           print "  " $1 ": invalid PVE VMID \"" $2 "\""
      if ($3 !~ /^[0-9a-f-]{36}$/)                     print "  " key ": invalid oVirt disk ID \"" $3 "\""
      if ($4 !~ /^(scsi|sata|virtio|ide)[0-9]+$/)      print "  " $1 ": invalid PVE slot \"" $4 "\""
      if ($5 != "0" && $5 != "1")                      print "  " key ": boot must be 0 or 1"
      if (seen[key]++)                                 print "  " key ": listed twice"
      if (slot[$2 ";" $4]++)                           print "  VM " $2 ": slot " $4 " used twice"
      if (disk[$3]++)                                  print "  disk " $3 " listed twice"
      if (($1 in vm) && vm[$1] != $2)                  print "  " $1 ": different VMIDs (" vm[$1] ", " $2 ")"
      vm[$1] = $2; boots[$2] += ($5 == "1") }
    END { for (v in boots) if (boots[v] != 1) print "  VM " v ": needs exactly one boot disk (has " boots[v] ")" }')
  [[ -z $errs ]] || die "disks.csv has errors:"$'\n'"$errs"
}
csv_rows()  { csv_all | awk -F';' -v n="$1" '$1 == n'; }
csv_match() { csv_all | awk -F';' -v b="$1" '($1 "-" $4) == b' | head -1; }
ovirt_name(){ awk -F';' 'NR==1{print ($6 != "" ? $6 : $1)}' <<<"$1"; }
exported()  {
  [[ -e $LOGS/$1.stale ]] && return 1     # invalidated by a restore - must be exported again
  [[ -e $BASE/$1.qcow2 || -e $BASE/importing/$1.qcow2 || -e $BASE/imported/$1.qcow2 ]]
}

# One lock per VM, so two runs can't move the same disks at the same time.
# The lock file is local (/run/lock), because flock over NFS isn't reliable.
lock_vm() {
  local fd
  exec {fd}>"/run/lock/migrate-$1.lock"
  flock -n "$fd" || die "another export/restore/release for '$1' is already running"
  LOCK_FDS+=" $fd"
}
LOCK_FDS=""
# Background helpers must not inherit the VM locks, or a lock would outlive the script.
close_locks() { local f; for f in $LOCK_FDS; do eval "exec $f>&-"; done; }

# ---- oVirt REST API -----------------------------------------------------------
# Escape a value for a curl config file (-K): backslashes and double quotes.
curl_esc() { local v=${1//\\/\\\\}; printf '%s' "${v//\"/\\\"}"; }

# Log in once via the engine's SSO token endpoint - the same way the oVirt SDKs do.
# Works with Keycloak (oVirt 4.5) and the legacy internal domain. Credentials and
# token go to curl via -K <(...), so they never show up in ps.
sso_login() {
  local out
  out=$(curl -sS "${TLS[@]}" -H 'Accept: application/json' -K <(
          printf 'data-urlencode = "grant_type=password"\ndata-urlencode = "scope=ovirt-app-api"\n'
          printf 'data-urlencode = "username=%s"\n' "$(curl_esc "$ENGINE_USER")"
          printf 'data-urlencode = "password=%s"\n' "$(curl_esc "$ENGINE_PASS")"
        ) "${ENGINE_URL%/api}/sso/oauth/token") || die "cannot reach ${ENGINE_URL%/api}/sso/oauth/token"
  TOKEN=$(py '
import sys, json
try: d = json.loads(sys.stdin.read())
except ValueError: d = {}
print(d.get("access_token", "")) if d.get("access_token") else \
  sys.stderr.write("%s\n" % (d.get("error_description") or d.get("error") or "no JSON answer - check ENGINE_URL"))' <<<"$out" 2>/tmp/.migrate-sso-err.$$)
  if [[ -z $TOKEN ]]; then
    local e; e=$(cat /tmp/.migrate-sso-err.$$); rm -f /tmp/.migrate-sso-err.$$
    die "login as '$ENGINE_USER' failed: $e (oVirt 4.5 with Keycloak: admin@ovirt@internalsso)"
  fi
  rm -f /tmp/.migrate-sso-err.$$
}

# Call the oVirt REST API: XML request body, JSON response on stdout.
# Uses -w '%{http_code}' because the curl on oVirt hosts is too old for --fail-with-body.
# With --dry-run only GET requests are sent; everything else is just printed.
api() {
  local m=$1 p=$2 b=${3:-} out code data=()
  # Hard safety net: the only deletions this script ever does are detaching a disk
  # from a VM (the disk itself stays) and removing a snapshot. Anything else - e.g.
  # /disks/... which would delete a disk - is refused, whatever the caller wants.
  if [[ $m == DELETE && ! $p =~ ^/vms/[0-9a-fA-F-]+/diskattachments/[0-9a-fA-F-]+\?detach_only=true$ \
                     && ! $p =~ ^/vms/[0-9a-fA-F-]+/snapshots/[0-9a-fA-F-]+$ ]]; then
    die "refusing API call DELETE $p - only disk detaches and snapshot removals are allowed"
  fi
  if ((DRY_RUN)) && [[ $m != GET ]]; then log "  [dry-run] $m $p $b" >&2; echo '{}'; return 0; fi
  [[ -n $b ]] && data=(--data "$b")
  out=$(mktemp)
  code=$(curl -sS -o "$out" -w '%{http_code}' -X "$m" "${TLS[@]}" -K <(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN") \
         -H 'Accept: application/json' -H 'Content-Type: application/xml' \
         "${data[@]}" "$ENGINE_URL$p") || { rm -f "$out"; warn "API $m $p: connection failed"; return 1; }
  if [[ $code != 2* ]]; then
    warn "API $m $p -> HTTP $code: $(tr -d '\n' < "$out" | head -c 300)"; rm -f "$out"; return 1
  fi
  cat "$out"; rm -f "$out"
}

py() { python3 -c "$1" "${@:2}"; }

# Check tools and CA, get the password (conf, file or prompt) and test the login,
# so a bad setup fails before anything is changed.
need_ovirt_api() {
  command -v python3 >/dev/null || die "python3 is required on the oVirt host"
  command -v curl >/dev/null    || die "curl is required on the oVirt host"
  [[ $ENGINE_CA == insecure || -r $ENGINE_CA ]] || die "ENGINE_CA '$ENGINE_CA' not readable (or set ENGINE_CA=insecure)"
  [[ $ENGINE_URL == */ovirt-engine/api ]] || die "ENGINE_URL must end with /ovirt-engine/api (is: $ENGINE_URL)"
  if [[ $ENGINE_CA == insecure ]]; then TLS=(-k); else TLS=(--cacert "$ENGINE_CA"); fi
  if [[ -z $ENGINE_PASS ]]; then
    if [[ -n $ENGINE_PASS_FILE ]]; then
      [[ -r $ENGINE_PASS_FILE ]] || die "ENGINE_PASS_FILE '$ENGINE_PASS_FILE' not readable (missing, or not running as root?)"
      # First line only; strip Windows line endings and surrounding whitespace.
      ENGINE_PASS=$(head -n1 "$ENGINE_PASS_FILE" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [[ -n $ENGINE_PASS ]] || die "ENGINE_PASS_FILE '$ENGINE_PASS_FILE' is empty"
    else
      read -rsp "oVirt engine password for $ENGINE_USER: " ENGINE_PASS; echo
    fi
  fi
  sso_login
  api GET "/" >/dev/null || die "logged in, but the API at $ENGINE_URL refuses the token"
}

# Find a VM by exact name and print "id;status;host_id".
# The API search matches patterns, so the exact match is done in python.
ovirt_vm() {
  local q
  q=$(py 'import urllib.parse,sys; print(urllib.parse.quote("name=" + sys.argv[1]))' "$1")
  api GET "/vms?search=$q" | py '
import sys, json
for v in json.load(sys.stdin).get("vm", []):
    if v.get("name") == sys.argv[1]:
        print("%s;%s;%s" % (v["id"], v.get("status", ""), (v.get("host") or {}).get("id", "")))
        break' "$1"
}
vm_status() { api GET "/vms/$1" | py 'import sys,json; print(json.load(sys.stdin).get("status",""))'; }
host_name() { [[ -n $1 ]] || return 0; api GET "/hosts/$1" | py 'import sys,json; print(json.load(sys.stdin).get("name",""))'; }
# Snapshots of a VM, without the always-present "active" one (that is the VM's
# current state, never a snapshot to delete). Output: id;type;status;date;description
snapshots() {
  api GET "/vms/$1/snapshots" | py '
import sys, json, time
for s in json.load(sys.stdin).get("snapshot", []):
    if s.get("snapshot_type") == "active":
        continue
    d = s.get("date")
    try:
        d = time.strftime("%Y-%m-%d %H:%M", time.localtime(int(d) / 1000))
    except (TypeError, ValueError):
        d = str(d or "?")[:16]
    desc = (s.get("description") or "").replace(";", ",").replace("\n", " ")
    print(";".join([s["id"], s.get("snapshot_type", ""), s.get("snapshot_status", ""), d, desc]))'
}

# Remove ONE snapshot of a VM and wait until oVirt has merged it. Removing a
# snapshot merges its data into the disk - the disk itself is never deleted. The
# snapshot is re-checked right before: it must be a non-active snapshot of exactly
# this VM, otherwise nothing is sent. api() additionally only allows this path.
delete_snapshot() {
  local vm=$1 snap=$2 t=0 list
  list=$(snapshots "$vm")
  # Only a regular, unlocked snapshot of exactly this VM - never the active state,
  # a preview, a stateless snapshot or a disk.
  grep -q "^$snap;regular;ok;" <<<"$list" || die "snapshot $snap is not a regular, unlocked snapshot of VM $vm - refusing to delete"
  api DELETE "/vms/$vm/snapshots/$snap" >/dev/null || die "oVirt refused to remove snapshot $snap - check the oVirt events"
  ((DRY_RUN)) && return 0
  while ((t < SNAPSHOT_TIMEOUT)); do
    sleep 10; t=$((t + 10))
    list=$(snapshots "$vm")
    grep -q "^$snap;" <<<"$list" || return 0
    ((t % 300 == 0)) && log "       still merging snapshot $snap ($(hm "$t"))"
  done
  die "snapshot $snap still not removed after $(hm "$SNAPSHOT_TIMEOUT") - check the tasks in oVirt, rerun export when done"
}

# Print a VM's disks as "diskid;interface;bootable;active;read_only;pass_discard".
# Booleans are lower-cased because the API returns them as strings or bools.
attachments() {
  api GET "/vms/$1/diskattachments" | py '
import sys, json
b = lambda v: str(v).lower()
for a in json.load(sys.stdin).get("disk_attachment", []):
    print(";".join([a["disk"]["id"], a.get("interface", ""), b(a.get("bootable", "false")),
                    b(a.get("active", "false")), b(a.get("read_only", "false")), b(a.get("pass_discard", "false"))]))'
}
disk_info() {
  api GET "/disks/$1" | py '
import sys, json
d = json.load(sys.stdin)
print("%s;%s;%s" % (d.get("name", ""), d.get("provisioned_size", 0), d.get("actual_size", 0)))'
}
nics() {
  api GET "/vms/$1/nics" | py '
import sys, json
for n in json.load(sys.stdin).get("nic", []):
    print("%s;%s;%s" % (n.get("name", ""), (n.get("mac") or {}).get("address", ""), n.get("interface", "")))'
}

att_xml() {
  local pd=""
  [[ ${5:-false} == true ]] && pd="<pass_discard>true</pass_discard>"
  printf '<disk_attachment><disk id="%s"/><interface>%s</interface><bootable>%s</bootable><active>true</active><read_only>%s</read_only>%s</disk_attachment>' \
    "$1" "$2" "$3" "$4" "$pd"
}
deactivate() { api PUT "/vms/$1/diskattachments/$2" '<disk_attachment><active>false</active></disk_attachment>' >/dev/null; }
# detach_only=true: remove the attachment only - the disk itself always stays in oVirt.
detach()     { api DELETE "/vms/$1/diskattachments/$2?detach_only=true" >/dev/null; }
attach()     { api POST "/vms/$1/diskattachments" "$(att_xml "${@:2}")" >/dev/null; }

# oVirt keeps a disk locked for a while after detaching it; attaching too early
# fails with HTTP 409. Wait while the disk is "locked" (max 5 min).
wait_disk_ready() {
  ((DRY_RUN)) && return 0
  local t=0 st=""
  while ((t < 300)); do
    st=$(api GET "/disks/$1" | py 'import sys,json; print(json.load(sys.stdin).get("status",""))')
    case $st in
      locked)  ;;
      illegal) warn "disk $1 is in state 'illegal' in oVirt - check it there"; return 1 ;;
      *)       return 0 ;;
    esac
    sleep 5; t=$((t + 5))
  done
  warn "disk $1 is still locked after 300s"; return 1
}

# Attach once the disk is unlocked; retry a few times in case the lock comes back.
attach_ready() {
  local i
  for i in 1 2 3 4 5 6; do
    wait_disk_ready "$2" && attach "$@" && return 0
    ((DRY_RUN)) && return 1
    log "WAIT   disk $2 not attachable yet - retrying in 10s ($i/6)"
    sleep 10
  done
  return 1
}

wait_inactive() {
  ((DRY_RUN)) && return 0
  local t=0
  while ((t < 120)); do
    [[ $(attachments "$1" | awk -F';' -v d="$2" '$1==d{print $4}') != true ]] && return 0
    sleep 3; t=$((t + 3))
  done
  warn "disk $2 is still active after 120s"; return 1
}

wait_status() {
  local t=0
  while :; do
    [[ $(vm_status "$1") == "$2" ]] && return 0
    ((t >= $3)) && return 1
    sleep 5; t=$((t + 5))
  done
}

# Shut the VM down cleanly. If it doesn't stop in time, ask before a hard stop.
shutdown_vm() {
  [[ $3 == down ]] && { log "VM     $1 is already down"; return 0; }
  log "STOP   $1: sending shutdown (timeout ${SHUTDOWN_TIMEOUT}s)"
  api POST "/vms/$2/shutdown" '<action/>' >/dev/null || die "shutdown request for $1 failed"
  ((DRY_RUN)) && return 0
  if wait_status "$2" down "$SHUTDOWN_TIMEOUT"; then log "VM     $1 is down"; return 0; fi
  warn "$1 did not shut down within ${SHUTDOWN_TIMEOUT}s"
  # A hard power-off can corrupt a guest (e.g. during Windows updates), so it is
  # never automatic - not even with -y.
  ((YES == 0)) || die "aborted - $1 is still running (no hard stop in -y mode); stop it in oVirt and rerun"
  confirm "Power off $1 hard (stop)?" || die "aborted - $1 is still running, nothing was moved for it"
  api POST "/vms/$2/stop" '<action/>' >/dev/null && wait_status "$2" down 180 || die "could not stop $1"
  log "VM     $1 is down (hard stop)"
}

# Map an oVirt disk ID to its /dev/dm-X on this host.
# Returns 1 while the device isn't there yet, 2 if the disk has more than one
# volume (snapshot chain), which would give an incomplete export.
find_volume() {
  local d img="" vols=() v dev
  for d in /rhev/data-center/*/*/images/"$1"; do
    [[ -d $d && $d != */mastersd/* ]] && { img=$d; break; }
  done
  [[ -n $img ]] || return 1
  for v in "$img"/*; do
    [[ -e $v && $v != *.lease && $v != *.meta ]] && vols+=("${v##*/}")
  done
  ((${#vols[@]} == 0)) && return 1
  ((${#vols[@]} > 1)) && { warn "disk $1: ${#vols[@]} volumes in $img (snapshot chain left?)"; return 2; }
  dev=$(readlink -f "$img/${vols[0]}")
  [[ -b $dev ]] || return 1
  echo "$dev"
}

# Save the original disk attachments and MACs before the first disk is moved,
# so restore can rebuild the VM exactly. On a re-run, entries for disks that are
# already on the Datamover are kept from the previous state file.
save_state() {
  ((DRY_RUN)) && return 0
  local f="$STATE/$1.disks" atts old disk line
  atts=$(attachments "$2"); old=$(cat "$f" 2>/dev/null)
  : > "$f.new"
  while IFS=';' read -r _ _ disk _; do
    line=$(grep "^$disk;" <<<"$atts")
    if [[ -n $line ]]; then
      awk -F';' -v OFS=';' '{print $1,$2,$3,$5,$6}' <<<"$line" >> "$f.new"
    elif grep -q "^$disk;" <<<"$old"; then
      grep "^$disk;" <<<"$old" >> "$f.new"
    else
      warn "no original attachment info for disk $disk - restore will fall back to disks.csv"
    fi
  done < <(csv_rows "$1")
  mv "$f.new" "$f"
  if nics "$2" > "$STATE/$1.nics.new" && [[ -s $STATE/$1.nics.new ]]; then
    mv "$STATE/$1.nics.new" "$STATE/$1.nics"
  else
    rm -f "$STATE/$1.nics.new"
  fi
}

# Virtual disk size in bytes. Parsed from the first "virtual size:" line, because
# newer qemu-img versions list child nodes (with the file size) first in --output=json.
# -U: read-only query that also works while the datamover has the disk open.
vsize() { qemu-img info -U "$1" 2>/dev/null | awk -F'[()]' '/^virtual size:/{print $2+0; exit}'; }

# Space on the export share: "total used avail" in bytes.
share_df() { df -P -B1 "$BASE" | awk 'NR==2{print $2, $3, $4}'; }

# Bytes the running exports (other than $1) may still write: their full disk size
# minus what is already allocated in their .part file. Worst case, because a thin
# disk can be filled up to its full size.
export_inflight() {
  local p b sz cur sum=0
  for p in "$BASE"/*.qcow2.part; do
    [[ -e $p ]] || continue
    b=$(basename "$p" .qcow2.part); [[ $b == "${1:-}" ]] && continue
    sz=$(cat "$LOGS/$b.size" 2>/dev/null); [[ $sz =~ ^[0-9]+$ ]] || continue
    cur=$(stat -c '%b %B' "$p" | awk '{printf "%.0f", $1*$2}')
    ((sz > cur)) && sum=$((sum + sz - cur))
  done
  echo "$sum"
}

# True if <bytes> (the full disk size, +1 % for qcow2 metadata) still fit on the
# export share next to the running exports, without exceeding EXPORT_MAX_PCT.
export_space_ok() {
  local need=$(( $1 * 101 / 100 )) inflight tot used avail
  inflight=$(( $(export_inflight "${2:-}") * 101 / 100 ))
  read -r tot used avail < <(share_df)
  [[ -n ${tot:-} && $tot -gt 0 ]] || return 1
  ((need + inflight < avail && (used + inflight + need) * 100 / tot < EXPORT_MAX_PCT))
}

# Runs next to the exports: if the share reaches EXPORT_MAX_PCT anyway, stop all
# exports to it, mark the run as aborted (queued disks won't start) and let conv
# delete the partial files - a full share would stop every VM that uses it.
# Runs in its own session and keeps guarding as long as exports run, even if the
# main script was killed (e.g. SSH disconnect).
export_watchdog() {
  local tot used pct
  while kill -0 "$1" 2>/dev/null || pgrep -f "qemu-img convert .*$BASE/[^ ]*\.qcow2\.part" >/dev/null; do
    read -r tot used _ < <(share_df)
    if [[ -n ${tot:-} && $tot -gt 0 ]]; then
      pct=$((used * 100 / tot))
      if ((pct >= EXPORT_MAX_PCT)); then
        echo "export share reached ${pct}% (limit ${EXPORT_MAX_PCT}%)" > "$ABORT_FLAG"
        warn "ABORT  export share at ${pct}% (limit ${EXPORT_MAX_PCT}%) - stopping all exports to $BASE"
        pkill -f "qemu-img convert .*$BASE/[^ ]*\.qcow2\.part" 2>/dev/null
        return 0
      fi
    fi
    sleep 5
  done
}

# Export one disk. Writes to .qcow2.part and renames only on success, so the
# importer never picks up a half-written file. The marker files feed status.
conv() {
  local dev=$1 name=$2 out="$BASE/$2.qcow2" L=$LOGS size lk
  rm -f "$L/$name".{queued,end,fail,samples,reason,stale}
  fail() { echo "$1" > "$L/$name.reason"; date +%s > "$L/$name.fail"; rm -f "$out.part"; log "FAIL   $name - $1"; }
  if [[ -e $ABORT_FLAG ]]; then fail "not started: $(cat "$ABORT_FLAG")"; return; fi
  size=$(vsize "$dev")
  [[ $size =~ ^[0-9]+$ ]] || { fail "cannot read the disk size of $dev"; return; }
  # Check and reserve under one lock, so parallel workers can't both take the same free space.
  exec {lk}>/run/lock/migrate-export-space.lock; flock "$lk"
  if ! export_space_ok "$size" "$name"; then
    exec {lk}>&-; fail "not enough space on the export share for the full disk size ($(gib "$size"), limit ${EXPORT_MAX_PCT}%)"; return
  fi
  echo "$size" > "$L/$name.size"; : > "$out.part"; date +%s > "$L/$name.start"
  exec {lk}>&-
  if qemu-img convert -p -W -m 16 -O qcow2 "$dev" "$out.part" > "$L/$name.log" 2>&1; then
    date +%s > "$L/$name.end"; mv "$out.part" "$out"; log "DONE   $name exported"
  elif [[ -e $ABORT_FLAG ]]; then
    fail "aborted: $(cat "$ABORT_FLAG") - partial file deleted"
  else
    fail "qemu-img failed - see $L/$name.log"
  fi
}

# Look up the Datamover (sets DM_ID and DM_ATTS). For export it must run on this
# host, because attached disks only become accessible there.
datamover() {
  local dm st host hn
  dm=$(ovirt_vm "$DATAMOVER_VM"); [[ -n $dm ]] || die "datamover VM '$DATAMOVER_VM' not found in oVirt"
  IFS=';' read -r DM_ID st host <<<"$dm"
  if [[ ${1:-} == need_up ]]; then
    [[ $st == up ]] || die "datamover '$DATAMOVER_VM' is '$st' - start it on this host first"
    hn=$(host_name "$host")
    if [[ ${hn%%.*} != "$(hostname -s)" ]]; then
      warn "datamover runs on '$hn', this host is '$(hostname -s)' - disks only become accessible on the datamover's host"
      confirm "Continue anyway?" || exit 1
    fi
  fi
  DM_ATTS=$(attachments "$DM_ID")
}

export_running() { pgrep -f "qemu-img convert.*/$1-[^/]*\.qcow2\.part" >/dev/null; }

# ---- export -------------------------------------------------------------------
# Preflight (read-only) -> confirm -> shut down and move disks -> check devices
# -> export in parallel, largest disk first. Nothing is changed before the
# confirmation, and the original state is saved before the first move.
cmd_export() {
  need_host ovirt export
  (($#)) || die "usage: $0 export <vm> [vm...]"
  load_config "${VARS_OVIRT[@]}"
  need_ovirt_api; tmux_hint
  mkdir -p "$LOGS" "$STATE"
  csv_check
  local uniq; mapfile -t uniq < <(printf '%s\n' "$@" | awk '!s[$0]++'); set -- "${uniq[@]}"
  local vm; for vm in "$@"; do lock_vm "$vm"; done
  datamover need_up

  # -- preflight (read-only) --
  local plan=() p rows ov r id st atts disk slot boot where info dname prov act a line snaplist=() sid stype sstat sdate sdesc
  local -A VMID_OF=() VMST_OF=()
  for vm in "$@"; do
    export_running "$vm" && die "an export of '$vm' is already running"
    rows=$(csv_rows "$vm"); [[ -n $rows ]] || die "'$vm' has no lines in $CSV"
    ov=$(ovirt_name "$rows")
    r=$(ovirt_vm "$ov"); [[ -n $r ]] || die "oVirt VM '$ov' not found"
    IFS=';' read -r id st _ <<<"$r"; VMID_OF[$vm]=$id; VMST_OF[$vm]=$st
    while IFS= read -r line; do
      [[ -n $line ]] && snaplist+=("$vm;$id;$line")
    done < <(snapshots "$id")
    atts=$(attachments "$id")
    while IFS=';' read -r _ _ disk slot boot _; do
      if ((FORCE == 0)) && exported "$vm-$slot"; then where=skip
      elif grep -q "^$disk;" <<<"$atts";    then where=src
      elif grep -q "^$disk;" <<<"$DM_ATTS"; then where=dm
      else where=free; fi
      info=$(disk_info "$disk"); IFS=';' read -r dname prov act <<<"$info"
      [[ -n $dname ]] || die "disk $disk ($vm $slot) not found in oVirt - check disks.csv"
      ((DRY_RUN)) || size_cache_put "$disk" "$prov" "$act"
      plan+=("$vm;$id;$disk;$slot;$boot;$where;$dname;$prov;$act")
    done <<<"$rows"
    while IFS=';' read -r disk _; do
      [[ -n $disk ]] || continue
      grep -q ";$disk;" <<<"$rows" || warn "$vm: disk $disk is attached in oVirt but not in disks.csv - it will NOT be migrated"
    done <<<"$atts"
  done

  # Snapshots: a disk with snapshots consists of several volumes; exporting only the
  # top one would be incomplete. Offer to remove them (merge into the disk) first.
  if ((${#snaplist[@]})); then
    echo
    warn "${#snaplist[@]} snapshot(s) found - the export should be done without snapshots:"
    printf '  %-14s %-16s %-10s %-10s %s\n' VM DATE TYPE STATUS DESCRIPTION >&2
    for p in "${snaplist[@]}"; do
      IFS=';' read -r vm _ sid stype sstat sdate sdesc <<<"$p"
      printf '  %-14s %-16s %-10s %-10s %s\n' "$vm" "$sdate" "$stype" "$sstat" "$sdesc" >&2
      [[ $stype == preview || $sstat == in_preview ]] && die "$vm is previewing a snapshot - commit or undo the preview in oVirt first"
      [[ $sstat == locked ]] && die "$vm: a snapshot operation is still running - wait for it in oVirt, then rerun"
      [[ $stype == regular ]] || die "$vm has a snapshot of type '$stype' - only regular snapshots are removed by this script; handle it in oVirt"
    done
    warn "Removing a snapshot merges it into the disk (the disk stays, only the restore point is gone)."
    if ((YES)); then
      log "SNAP   -y: removing the ${#snaplist[@]} snapshot(s) automatically"
    else
      confirm "Remove these ${#snaplist[@]} snapshot(s) one by one and continue?" \
        || die "aborted - nothing was changed. Remove the snapshots in oVirt, then rerun the export."
    fi
    for p in "${snaplist[@]}"; do
      IFS=';' read -r vm id sid _ _ sdate sdesc <<<"$p"
      log "SNAP   $vm: removing snapshot from $sdate (${sdesc:-no description})"
      delete_snapshot "$id" "$sid"
      ((DRY_RUN)) || log "SNAP   $vm: snapshot removed"
    done
    if ((DRY_RUN == 0)); then
      for vm in "$@"; do
        [[ -z $(snapshots "${VMID_OF[$vm]}") ]] || die "$vm still has snapshots - check oVirt, then rerun"
        # the disks must all still be there
        while IFS=';' read -r _ _ disk slot _; do
          [[ -n $(disk_info "$disk" | cut -d';' -f1) ]] || die "$vm $slot: disk $disk not found after removing the snapshots - check oVirt"
        done < <(csv_rows "$vm")
      done
      log "SNAP   all snapshots removed, all disks present - continuing"
    fi
  fi

  echo
  printf '%-14s %-8s %-7s %-4s %-24s %8s %8s  %s\n' VM STATE SLOT BOOT OVIRT-DISK SIZE ALLOC ACTION
  for p in "${plan[@]}"; do
    IFS=';' read -r vm id disk slot boot where dname prov act <<<"$p"
    case $where in
      src)  a="shut down VM, move disk RO to datamover, export" ;;
      dm)   a="already on datamover, export" ;;
      free) a="unattached (interrupted run) - attach RO to datamover, export" ;;
      skip) a="already exported - skipped (--force to redo)" ;;
    esac
    printf '%-14s %-8s %-7s %-4s %-24s %8s %8s  %s\n' "$vm" "${VMST_OF[$vm]}" "$slot" "$boot" "${dname:0:24}" "$(gib "$prov")" "$(gib "$act")" "$a"
  done
  echo

  # Worst case: every disk is exported at its full size. Checked before anything is shut down.
  local need=0 tot used avail after
  for p in "${plan[@]}"; do
    IFS=';' read -r vm _ disk slot _ where _ prov _ <<<"$p"
    [[ $where == skip ]] && continue
    [[ $prov =~ ^[0-9]+$ ]] || die "$vm $slot: cannot read the size of disk $disk from oVirt"
    need=$((need + prov))
  done
  need=$(( (need + $(export_inflight)) * 101 / 100 ))
  read -r tot used avail < <(share_df)
  [[ ${tot:-0} =~ ^[0-9]+$ && $tot -gt 0 ]] || die "cannot read the free space of the export share $BASE"
  after=$(( (used + need) * 100 / tot ))
  log "SPACE  export share: $(gib "$used") of $(gib "$tot") used; these exports need up to $(gib "$need") (full disk size) -> ${after}% (limit ${EXPORT_MAX_PCT}%)"
  if ((need >= avail || after >= EXPORT_MAX_PCT)); then
    die "not enough space on the export share $BASE - free space (e.g. imported/ files) or export fewer VMs at once"
  fi
  ((DRY_RUN)) && log "dry-run: showing the API calls only, nothing is changed"
  confirm "Shut down these VMs, move their disks to '$DATAMOVER_VM' and start the export?" || exit 0

  # -- shut down + move disks --
  for vm in "$@"; do
    id=${VMID_OF[$vm]}
    if printf '%s\n' "${plan[@]}" | grep -q "^$vm;[^;]*;[^;]*;[^;]*;[^;]*;src;"; then
      save_state "$vm" "$id"
      shutdown_vm "$vm" "$id" "${VMST_OF[$vm]}"
    fi
    for p in "${plan[@]}"; do
      IFS=';' read -r a _ disk slot _ where _ <<<"$p"
      [[ $a == "$vm" && ( $where == src || $where == free ) ]] || continue
      if [[ $where == src ]]; then
        log "MOVE   $vm $slot: detach from source, attach read-only to $DATAMOVER_VM"
        { deactivate "$id" "$disk" && wait_inactive "$id" "$disk" && detach "$id" "$disk"; } \
          || die "detaching disk $disk failed - check oVirt events; '$0 restore $vm' puts disks back"
      else
        log "MOVE   $vm $slot: attach unattached disk read-only to $DATAMOVER_VM"
      fi
      attach_ready "$DM_ID" "$disk" "$DM_INTERFACE" false true \
        || die "attaching disk $disk to $DATAMOVER_VM failed - check oVirt events; rerun export, or '$0 restore $vm' to roll back"
    done
  done
  ((DRY_RUN)) && { log "dry-run finished - nothing was changed"; return 0; }

  # -- check device access --
  local jf dev rc t size n
  jf=$(mktemp)
  for p in "${plan[@]}"; do
    IFS=';' read -r vm _ disk slot _ where _ <<<"$p"
    [[ $where == skip ]] && continue
    t=0
    while :; do
      dev=$(find_volume "$disk"); rc=$?
      ((rc == 0)) && break
      ((rc == 2)) && die "$vm $slot: snapshot chain on disk $disk - export aborted ('$0 restore $vm' to roll back)"
      ((t >= DEVICE_TIMEOUT)) && die "$vm $slot: disk $disk not accessible after ${DEVICE_TIMEOUT}s (datamover on this host?) - '$0 restore $vm' to roll back"
      sleep 5; t=$((t + 5))
    done
    size=$(blockdev --getsize64 "$dev")
    log "OK     $vm-$slot -> $dev ($(gib "$size") allocated)"
    rm -f "$LOGS/$vm-$slot".{start,end,fail,samples,size}
    touch "$LOGS/$vm-$slot.queued"
    echo "$size $dev $vm-$slot" >> "$jf"
  done

  # -- export in parallel, largest first --
  # Own scheduler instead of xargs: workers run in their own session (setsid), so
  # Ctrl-C reaches only this loop, which decides what happens:
  #   1st Ctrl-C: start no more disks, let running exports finish.
  #   2nd Ctrl-C: abort running exports; conv deletes their partial files.
  local -a jobs; local -A running=()
  local next=0 pid b dev wd ok=0 failed=() reason
  mapfile -t jobs < <(sort -rn "$jf"); rm -f "$jf"
  n=${#jobs[@]}
  ((n)) || { log "nothing to export"; return 0; }
  ABORT_FLAG="$LOGS/.export-abort-$$"; rm -f "$ABORT_FLAG"
  export BASE LOGS EXPORT_MAX_PCT ABORT_FLAG LC_ALL
  export LOCK_FDS
  export -f conv log warn ts gib vsize share_df export_inflight export_space_ok export_watchdog close_locks
  setsid bash -c 'close_locks; export_watchdog "$@"' _ $$ </dev/null & wd=$!
  log "START  exporting $n disk(s), $PAR in parallel, largest first - progress: $0 status --watch"
  log "       Ctrl-C: no new disks start, running ones finish. Ctrl-C twice: abort running exports."
  STOPPING=0
  trap 'echo; STOPPING=$((STOPPING + 1))
        if ((STOPPING == 1)); then
          log "STOP   no new disks will start - running exports finish (Ctrl-C again to abort them)"
        else
          [[ -e $ABORT_FLAG ]] || echo "stopped by user (Ctrl-C)" > "$ABORT_FLAG"
          log "STOP   aborting running exports"
          for pid in "${!running[@]}"; do pkill -f "qemu-img convert .*$BASE/${running[$pid]}\.qcow2\.part"; done
        fi' INT TERM
  while :; do
    for pid in "${!running[@]}"; do kill -0 "$pid" 2>/dev/null || unset 'running[$pid]'; done
    [[ -e $ABORT_FLAG ]] && ((STOPPING < 2)) && STOPPING=2          # set by the watchdog
    while ((STOPPING == 0 && ${#running[@]} < PAR && next < n)); do
      read -r _ dev b <<<"${jobs[next]}"; next=$((next + 1))
      setsid bash -c 'close_locks; conv "$@"' _ "$dev" "$b" </dev/null &
      running[$!]=$b
    done
    ((${#running[@]} == 0)) && ((next >= n || STOPPING > 0)) && break
    sleep 2
  done
  trap - INT TERM
  kill "$wd" 2>/dev/null

  # Disks that never started get a reason, so status and the import side know.
  reason="stopped by user (Ctrl-C)"; [[ -e $ABORT_FLAG ]] && reason=$(cat "$ABORT_FLAG")
  while ((next < n)); do
    read -r _ _ b <<<"${jobs[next]}"; next=$((next + 1))
    rm -f "$LOGS/$b.queued"; echo "not started: $reason" > "$LOGS/$b.reason"; date +%s > "$LOGS/$b.fail"
    log "SKIP   $b not started ($reason)"
  done

  for p in "${jobs[@]}"; do
    read -r _ _ b <<<"$p"
    if [[ -e $LOGS/$b.end && ( -e $BASE/$b.qcow2 || -e $BASE/importing/$b.qcow2 || -e $BASE/imported/$b.qcow2 ) ]]; then ok=$((ok + 1))
    else failed+=("$b"); fi
  done
  [[ -e $ABORT_FLAG ]] && warn "Exports were stopped: $(cat "$ABORT_FLAG")"
  rm -f "$ABORT_FLAG"
  log "FINISH $ok of $n disk(s) exported${failed[*]:+ - NOT EXPORTED: ${failed[*]}}"

  if ((${#failed[@]} == 0)); then
    log "       Disks stay attached read-only to $DATAMOVER_VM. After verifying the VMs on PVE: $0 release <vm>"
    return 0
  fi
  if ((RESTORE_ON_ABORT == 0)); then
    log "       Next: rerun '$0 export <vm>' (finished disks are skipped), or roll back with '$0 restore <vm> --start'"
    return 0
  fi

  # --restore-on-abort: put every VM that isn't completely exported back on oVirt.
  local -a back=()
  for vm in "$@"; do
    for p in "${plan[@]}"; do
      IFS=';' read -r a _ _ slot _ where _ <<<"$p"
      [[ $a == "$vm" && $where != skip ]] || continue
      if [[ " ${failed[*]} " == *" $vm-$slot "* ]]; then back+=("$vm"); break; fi
    done
  done
  ((${#back[@]})) || return 0
  log "RESTORE --restore-on-abort: putting back on oVirt: ${back[*]}"
  for vm in "${back[@]}"; do invalidate_exports "$vm"; done
  restore_core noask "${back[@]}"
  for vm in "${back[@]}"; do
    if [[ ${VMST_OF[$vm]} == up ]]; then
      api POST "/vms/${VMID_OF[$vm]}/start" '<action/>' >/dev/null && log "START  $vm started again (it was running before the export)"
    else
      log "       $vm restored and left stopped (it was not running before the export)"
    fi
  done
}

# After a VM was restored on oVirt it runs again and its data changes, so exports
# from this attempt are outdated. Move them to stale/ and mark them, so a rerun
# exports every disk again instead of mixing old and new disks, and import --start
# never boots a VM with outdated disks.
invalidate_exports() {
  local name slot b f stamp
  stamp=$(date +%Y%m%d-%H%M%S)
  while IFS=';' read -r name _ _ slot _; do
    b="$name-$slot"
    for f in "$BASE/$b.qcow2" "$BASE/imported/$b.qcow2"; do
      [[ -e $f ]] || continue
      mkdir -p "$BASE/stale"; mv "$f" "$BASE/stale/$b.$stamp.qcow2"
      log "STALE  $b: moved to stale/ (VM runs on oVirt again)"
    done
    [[ -e $BASE/importing/$b.qcow2 ]] && warn "STALE  $b is being imported on PVE right now - remove that disk from the PVE VM afterwards"
    [[ -e $LOGS/import-$b.end ]] && warn "STALE  $b was already imported on PVE - remove that disk from the PVE VM before the next attempt"
    touch "$LOGS/$b.stale"
    if [[ -e $LOGS/$b.end ]]; then
      rm -f "$LOGS/$b.end"; echo "invalidated: VM was restored on oVirt" > "$LOGS/$b.reason"; date +%s > "$LOGS/$b.fail"
    fi
  done < <(csv_rows "$1")
}

# ---- restore (rollback) ----------------------------------------------------------
# Rollback: put the disks back on the original VM with the saved interface and
# boot flag. Works whether a disk is on the Datamover or unattached.
cmd_restore() {
  need_host ovirt restore
  (($#)) || die "usage: $0 restore <vm> [vm...]"
  load_config "${VARS_OVIRT[@]}"
  need_ovirt_api; csv_check
  local uniq; mapfile -t uniq < <(printf '%s\n' "$@" | awk '!s[$0]++'); set -- "${uniq[@]}"
  local vm; for vm in "$@"; do lock_vm "$vm"; done
  restore_core ask "$@"
  ((DRY_RUN)) && return 0
  for vm in "$@"; do
    if ((START_VM)); then
      api POST "/vms/${RESTORE_ID[$vm]}/start" '<action/>' >/dev/null && log "START  $vm started"
    else
      log "       $vm is restored - start it in oVirt (or rerun with --start)"
    fi
  done
}

# Re-attach the disks of the given VMs to their original VM (saved interface and
# boot flag), from the Datamover or from "unattached". Used by restore and by
# export --restore-on-abort. Sets RESTORE_ID[vm] = oVirt VM id.
restore_core() {
  local ask=$1; shift
  datamover                                     # refresh DM_ID / DM_ATTS
  declare -gA RESTORE_ID=()
  local plan=() p rows ov r id st atts disk slot boot line iface bt ro pd where a vm
  for vm in "$@"; do
    export_running "$vm" && die "an export of '$vm' is still running - stop it first (Ctrl-C in the export session)"
    rows=$(csv_rows "$vm"); [[ -n $rows ]] || die "'$vm' has no lines in $CSV"
    ov=$(ovirt_name "$rows")
    r=$(ovirt_vm "$ov"); [[ -n $r ]] || die "oVirt VM '$ov' not found"
    IFS=';' read -r id st _ <<<"$r"; RESTORE_ID[$vm]=$id
    [[ $st == down ]] || die "'$ov' is '$st' - restore needs the VM to be stopped"
    atts=$(attachments "$id")
    while IFS=';' read -r _ _ disk slot boot _; do
      line=$(grep "^$disk;" "$STATE/$vm.disks" 2>/dev/null)
      if [[ -n $line ]]; then
        IFS=';' read -r _ iface bt ro pd <<<"$line"
      else
        iface=$DEFAULT_INTERFACE; ro=false; pd=false
        if [[ $boot == 1 ]]; then bt=true; else bt=false; fi
        warn "$vm $slot: no saved attachment info - using $iface, bootable=$bt from disks.csv"
      fi
      if   grep -q "^$disk;" <<<"$atts";    then where=src
      elif grep -q "^$disk;" <<<"$DM_ATTS"; then where=dm
      else where=free; fi
      plan+=("$vm;$id;$disk;$slot;$iface;$bt;$ro;$pd;$where")
    done <<<"$rows"
  done

  echo
  printf '%-14s %-7s %-38s %-12s %-5s %-10s\n' VM SLOT OVIRT-DISK INTERFACE BOOT CURRENTLY
  for p in "${plan[@]}"; do
    IFS=';' read -r vm _ disk slot iface bt _ _ where <<<"$p"
    case $where in src) a="original VM (ok)";; dm) a="datamover";; free) a="unattached";; esac
    printf '%-14s %-7s %-38s %-12s %-5s %-10s\n' "$vm" "$slot" "$disk" "$iface" "$bt" "$a"
  done
  echo
  if [[ $ask == ask ]]; then confirm "Re-attach these disks to their original VMs?" || exit 0; fi

  for p in "${plan[@]}"; do
    IFS=';' read -r vm id disk slot iface bt ro pd where <<<"$p"
    [[ $where == src ]] && { log "OK     $vm $slot already attached to the original VM"; continue; }
    if [[ $where == dm ]]; then
      { deactivate "$DM_ID" "$disk" && wait_inactive "$DM_ID" "$disk" && detach "$DM_ID" "$disk"; } \
        || die "could not detach disk $disk from the datamover"
    fi
    attach_ready "$id" "$disk" "$iface" "$bt" "$ro" "$pd" || die "could not attach disk $disk to $vm - rerun restore"
    log "ATTACH $vm $slot -> $iface, bootable=$bt"
  done
  ((DRY_RUN)) && { log "dry-run finished - nothing was changed"; return 0; }

  for vm in "$@"; do
    a=$(attachments "${RESTORE_ID[$vm]}" | awk -F';' '$3=="true"{print $1}')
    if [[ -n $a ]]; then log "CHECK  $vm boot disk: $a"; else warn "$vm has no bootable disk - set one in oVirt"; fi
  done
}

# ---- release (cleanup after a successful migration) ------------------------------
# After a successful migration: detach the disks from the Datamover. They stay
# in oVirt, so restore still works until you delete them by hand.
cmd_release() {
  need_host ovirt release
  (($#)) || die "usage: $0 release <vm> [vm...]"
  load_config "${VARS_OVIRT[@]}"
  need_ovirt_api; csv_check
  local uniq; mapfile -t uniq < <(printf '%s\n' "$@" | awk '!s[$0]++'); set -- "${uniq[@]}"
  local vm; for vm in "$@"; do lock_vm "$vm"; done
  datamover
  local plan=() p disk slot
  for vm in "$@"; do
    export_running "$vm" && die "an export of '$vm' is still running"
    while IFS=';' read -r _ _ disk slot _; do
      if grep -q "^$disk;" <<<"$DM_ATTS"; then plan+=("$vm;$disk;$slot")
      else log "SKIP   $vm $slot is not attached to the datamover"; fi
    done < <(csv_rows "$vm")
  done
  ((${#plan[@]})) || { log "nothing to release"; return 0; }
  for p in "${plan[@]}"; do IFS=';' read -r vm disk slot <<<"$p"; echo "  $vm $slot ($disk)"; done
  confirm "Detach these disks from '$DATAMOVER_VM'? (they stay in oVirt, unattached)" || exit 0
  for p in "${plan[@]}"; do
    IFS=';' read -r vm disk slot <<<"$p"
    { deactivate "$DM_ID" "$disk" && wait_inactive "$DM_ID" "$disk" && detach "$DM_ID" "$disk"; } \
      || die "could not detach disk $disk"
    log "FREE   $vm $slot detached from the datamover ('restore' can still re-attach it)"
  done
}

# ---- import (PVE) -------------------------------------------------------------
# True if the import fits and the storage stays below MAX_POOL_PCT. Always plans
# with the full disk size (worst case, also correct for thick storage). Imports
# already running from importing/ count too, plus 10 % headroom.
space_ok() {
  local need=0 x v tot used avail
  for x in "$1" "$BASE"/importing/*.qcow2; do
    [[ -e $x ]] || continue
    v=$(vsize "$x"); need=$((need + ${v:-0}))
  done
  need=$((need * 11 / 10))
  read -r tot used avail < <(pvesm status --storage "$STORAGE" 2>/dev/null \
    | awk 'NR==2{printf "%.0f %.0f %.0f\n", $4*1024, $5*1024, $6*1024}')
  [[ -n ${tot:-} && $tot -gt 0 ]] || return 0
  ((need < avail && (used + need) * 100 / tot <= MAX_POOL_PCT))
}

mac_hint() {
  local f="$STATE/$1.nics" n mac _i
  [[ -r $f ]] || return 0
  while IFS=';' read -r n mac _i; do
    [[ -n $mac ]] || continue
    qm config "$2" 2>/dev/null | grep -qi "$mac" \
      || log "NOTE   VM $2: oVirt NIC $n had MAC $mac - consider: qm set $2 --net0 virtio=$mac,bridge=<bridge>"
  done < "$f"
}

# Start the VM once every disk listed for it is imported. A disk only counts if
# its import came from its latest export (the export marker is copied at import
# time, so this works even if the clocks of both hosts differ). Leftovers from
# earlier attempts can't start a VM with missing disks.
maybe_start() {
  local vmid=$1 name slot b n=0 ie ee
  while IFS=';' read -r name _ _ slot _; do
    b="$name-$slot"; n=$((n + 1))
    ie="$LOGS/import-$b.end"; ee="$LOGS/$b.end"
    [[ -e $LOGS/$b.stale ]] && return 0                                         # export was invalidated
    [[ -e $ie ]] || return 0                                                    # not imported yet
    [[ -e $ee && $(cat "$ee") != "$(cat "$LOGS/import-$b.src" 2>/dev/null)" ]] && return 0  # newer export pending
  done < <(csv_all | awk -F';' -v v="$vmid" '$2 == v')
  ((n)) || return 0
  if qm status "$vmid" 2>/dev/null | grep -q running; then
    log "VM     $vmid is already running"
  elif qm start "$vmid" >> "$LOGS/import-start-$vmid.log" 2>&1; then
    log "START  VM $vmid: all $n disk(s) imported - VM started"
  else
    warn "START  VM $vmid: start failed - see logs/import-start-$vmid.log"
  fi
}

# Import one file and attach it to the right slot in a single step (import-from).
# On failure the file stays in importing/, so a retry is just a mv.
import_one() {
  local f=$1 vmid=$2 slot=$3 boot=$4 b=$5 name=$6 L=$LOGS log
  log="$L/import-$b.log"
  rm -f "$L/import-$b".{end,fail,samples}
  cat "$L/$b.end" > "$L/import-$b.src" 2>/dev/null || : > "$L/import-$b.src"
  vsize "$f" > "$L/import-$b.size"
  date +%s > "$L/import-$b.start"
  if qm set "$vmid" --"$slot" "$STORAGE:0,import-from=$f${DISK_OPTS:+,$DISK_OPTS}" > "$log" 2>&1; then
    [[ $boot == 1 ]] && qm set "$vmid" --boot "order=$slot" >> "$log" 2>&1
    mv "$f" "$BASE/imported/"
    date +%s > "$L/import-$b.end"
    log "DONE   $b -> VM $vmid $slot ($(hm $(( $(<"$L/import-$b.end") - $(<"$L/import-$b.start") ))))"
    [[ $boot == 1 ]] && mac_hint "$name" "$vmid"
    ((START_VM)) && maybe_start "$vmid"
  else
    date +%s > "$L/import-$b.fail"
    warn "FAIL   $b: see $log (file stays in importing/ - move it back to $BASE to retry)"
  fi
}

# Poll the share for finished exports and import them. Each file is checked
# against disks.csv, slot usage and free space first. Imports run in the
# background: one at a time per VM (flock), in parallel across VMs.
cmd_import() {
  need_host pve import
  load_config "${VARS_PVE[@]}"
  tmux_hint
  mkdir -p "$BASE"/{importing,imported,unmatched} "$LOGS"
  pvesm status --storage "$STORAGE" >/dev/null 2>&1 || die "PVE storage '$STORAGE' not found"
  csv_check

  local name vmid disk slot boot _r
  while IFS=';' read -r name vmid disk slot boot _r; do
    qm status "$vmid" >/dev/null 2>&1 || warn "disks.csv: VM $vmid ($name) does not exist on this node"
    [[ -e $LOGS/import-$name-$slot.end ]] && continue
    qm config "$vmid" 2>/dev/null | grep -q "^$slot:" && warn "disks.csv: $name: slot $slot on VM $vmid is already in use"
  done < <(csv_all)

  log "Listening for exported disks in $BASE (storage '$STORAGE', poll ${POLL}s)"
  ((START_VM)) && log "Auto-start is on: each VM starts once all its disks are imported"
  log "Ctrl-C: finish running imports, then stop. Ctrl-C twice: stop now, imports continue in the background."

  # Imports run in their own session (setsid): Ctrl-C or an SSH disconnect never
  # reaches qm. The functions and settings they need are passed via the environment.
  export BASE LOGS STATE CSV STORAGE DISK_OPTS START_VM LC_ALL
  export -f import_one maybe_start mac_hint csv_all log warn die ts hm vsize

  # Graceful stop: the first Ctrl-C/TERM only stops picking up new files; the
  # loop below then waits for running imports. A second Ctrl-C leaves right away.
  STOPPING=0
  trap 'echo; if ((STOPPING)); then log "STOP   listener left - running imports continue in the background (check: $0 status)"; exit 0; fi
        STOPPING=1; log "STOP   no new imports will be started"' INT TERM

  local -A seen=() held=() running=()
  local p f b row pid names last_wait=0
  while :; do
    for pid in "${!running[@]}"; do kill -0 "$pid" 2>/dev/null || unset 'running[$pid]'; done
    if ((STOPPING)); then
      if ((${#running[@]} == 0)); then log "STOP   no imports running - listener stopped"; exit 0; fi
      if (( $(date +%s) - ${last_wait:-0} >= 30 )); then
        names=""
        for pid in "${!running[@]}"; do
          b=${running[$pid]}
          names+=" $b ($(grep -o '([0-9.]*%)' "$LOGS/import-$b.log" 2>/dev/null | tail -1 | tr -d '()' || true))"
        done
        log "WAIT   ${#running[@]} import(s) still running:${names} - Ctrl-C again to leave them running"
        last_wait=$(date +%s)
      fi
      sleep 5; continue
    fi
    for p in "$BASE"/*.qcow2.part; do
      [[ -e $p ]] || continue
      b=$(basename "$p" .qcow2.part)
      if [[ -z ${seen[$b]:-} ]]; then
        seen[$b]=part
        log "NEW    $b: export started - waiting for export/transfer to complete"
      elif [[ ${seen[$b]} == part && -e $LOGS/$b.fail ]]; then
        seen[$b]=failed
        warn "EXPORT $b failed on the oVirt side - see logs/$b.log"
      fi
    done
    for f in "$BASE"/*.qcow2; do
      [[ -e $f ]] || continue
      b=$(basename "$f" .qcow2)
      row=$(csv_match "$b")
      if [[ -z $row ]]; then
        mv "$f" "$BASE/unmatched/"; warn "SKIP   $b: no matching line in disks.csv - moved to unmatched/"; continue
      fi
      IFS=';' read -r name vmid disk slot boot _r <<<"$row"
      if qm config "$vmid" 2>/dev/null | grep -q "^$slot:"; then
        [[ ${held[$b]:-} == slot ]] || warn "HOLD   $b: slot $slot on VM $vmid is in use - free it to continue"
        held[$b]=slot; continue
      fi
      if ! space_ok "$f"; then
        [[ ${held[$b]:-} == space ]] || warn "HOLD   $b: not enough space on '$STORAGE' (limit ${MAX_POOL_PCT}%) - waiting"
        held[$b]=space; continue
      fi
      unset 'held[$b]'
      mv "$f" "$BASE/importing/"
      log "READY  $b: transfer complete -> importing into VM $vmid as $slot"
      setsid bash -c 'flock 9; import_one "$@"' _ "$BASE/importing/$b.qcow2" "$vmid" "$slot" "$boot" "$b" "$name" \
        9>"/run/lock/migrate-import-$vmid.lock" </dev/null &
      running[$!]=$b
    done
    sleep "$POLL"
  done
}

# ---- lookup ---------------------------------------------------------------------
# lookup <oVirt VM name>...: read a VM's disks from the engine and print them plus
# ready-made disks.csv lines (with <PVE_VMID> as placeholder). Read-only - it
# changes nothing. Slots follow the original bus; the boot disk gets slot 0.
cmd_lookup() {
  need_host ovirt lookup
  (($#)) || die "usage: $0 lookup <oVirt VM name> [...]   (e.g. the FQDN as shown in oVirt)"
  load_config ENGINE_URL ENGINE_USER ENGINE_CA
  need_ovirt_api
  local vm r id st q cands info os short lines warnfile
  warnfile=$(mktemp)
  for vm in "$@"; do
    r=$(ovirt_vm "$vm")
    if [[ -z $r ]]; then
      q=$(py 'import urllib.parse,sys; print(urllib.parse.quote("name=*" + sys.argv[1] + "*"))' "$vm")
      cands=$(api GET "/vms?search=$q" | py 'import sys,json; print("  ".join(v.get("name","") for v in json.load(sys.stdin).get("vm",[])))')
      warn "VM '$vm' not found in oVirt${cands:+ - similar names: $cands}"
      continue
    fi
    IFS=';' read -r id st _ <<<"$r"
    os=$(api GET "/vms/$id" | py 'import sys,json; print((json.load(sys.stdin).get("os") or {}).get("type",""))')
    short=${vm%%.*}

    # One python pass over attachments + disk details: sorted boot disk first, then
    # by disk name; slot = original bus mapped to PVE (+ running number per bus).
    info=$(
      { api GET "/vms/$id/diskattachments"; for d in $(attachments "$id" | cut -d';' -f1); do printf '\n@@@\n'; api GET "/disks/$d"; done; } \
      | py '
import sys, json, re
docs = [json.loads(p) for p in sys.stdin.read().split("\n@@@\n") if p.strip()]   # engine JSON may be pretty-printed
atts = docs[0].get("disk_attachment", [])
# disk details were fetched in attachment order; match by id, fall back to position
disks = {(d.get("id") or (atts[i]["disk"]["id"] if i < len(atts) else None)): d for i, d in enumerate(docs[1:])}
bus = {"virtio_scsi": "scsi", "virtio": "virtio", "sata": "sata", "ide": "ide", "spapr_vscsi": "scsi"}
nat = lambda s: [int(t) if t.isdigit() else t for t in re.split(r"(\d+)", s or "")]
rows = []
for a in atts:
    d = disks.get(a["disk"]["id"], {})
    rows.append(dict(id=a["disk"]["id"], boot=str(a.get("bootable", "false")).lower() == "true",
                     iface=a.get("interface", ""), active=str(a.get("active", "true")).lower(),
                     name=d.get("name") or d.get("alias") or "?", size=int(d.get("provisioned_size") or 0),
                     alloc=int(d.get("actual_size") or 0), share=str(d.get("shareable", "false")).lower(),
                     stype=d.get("storage_type", "image")))
rows.sort(key=lambda r: (not r["boot"], nat(r["name"])))
count = {}
for r in rows:
    b = bus.get(r["iface"], "scsi"); r["slot"] = "%s%d" % (b, count.get(b, 0)); count[b] = count.get(b, 0) + 1
    print(";".join(str(r[k]) for k in ("slot", "boot", "iface", "size", "alloc", "name", "id", "active", "share", "stype")))'
    )

    echo
    printf 'VM %s   (status %s, os %s, %d disk(s), %d snapshot(s))\n\n' "$vm" "$st" "${os:-?}" \
      "$(grep -c . <<<"$info")" "$(snapshots "$id" | grep -c .)"
    printf '  %-8s %-5s %-12s %9s %9s  %-32s %s\n' SLOT BOOT "OVIRT BUS" SIZE ALLOC "DISK NAME" "DISK ID"
    lines=""; : > "$warnfile"
    while IFS=';' read -r slot boot iface size alloc dname did active share stype; do
      [[ -n $did ]] || continue
      printf '  %-8s %-5s %-12s %9s %9s  %-32s %s\n' "$slot" "$([[ $boot == True ]] && echo yes || echo -)" "$iface" \
        "$(gib "$size")" "$(gib "$alloc")" "${dname:0:32}" "$did"
      [[ $share == true ]]   && echo "  WARN  $dname is shareable (attached to several VMs) - don't migrate it with this script" >> "$warnfile"
      [[ $stype != image ]]  && echo "  WARN  $dname is a $stype disk, not an image - it can't be exported this way" >> "$warnfile"
      [[ $active != true ]]  && echo "  NOTE  $dname is deactivated on the VM - check whether it's still needed" >> "$warnfile"
      grep -q ";$did;" <(csv_all 2>/dev/null) && echo "  NOTE  $dname is already in disks.csv" >> "$warnfile"
      # shareable disks and LUNs can't be migrated this way: suggest them commented out
      [[ $share == true || $stype != image ]] && lines+="# (not exportable) "
      lines+="$short;<PVE_VMID>;$did;$slot;$([[ $boot == True ]] && echo 1 || echo 0)$([[ $short != "$vm" ]] && echo ";$vm")"$'\n'
    done <<<"$info"
    [[ -s $warnfile ]] && { echo; cat "$warnfile"; }
    if [[ $os == *[Ww]indows* ]] && grep -qE '^(scsi|virtio)' <<<"$info"; then
      echo; echo "  NOTE  Windows VM on scsi/virtio: make sure vioscsi/viostor is set to boot start before the migration, or use sataN slots (see README)"
    fi
    if [[ -n $lines ]]; then
      echo; echo "  disks.csv lines (replace <PVE_VMID> with the PVE VM ID):"; echo
      printf '%s' "$lines"
    else
      echo "  (no disks attached)"
    fi
  done
  rm -f "$warnfile"
  echo
  log "INFO   lookup only reads from oVirt - nothing was changed"
}

# ---- list -----------------------------------------------------------------------
# Disk sizes are only known on the oVirt side. list (and export) store them in
# state/disk-sizes.csv on the share, so the PVE side can show them too.
size_cache_put() {
  local f="$STATE/disk-sizes.csv"
  mkdir -p "$STATE"
  { grep -v "^$1;" "$f" 2>/dev/null; echo "$1;$2;$3"; } > "$f.new" && mv "$f.new" "$f"
}
size_cache_get() { grep -m1 "^$1;" "$STATE/disk-sizes.csv" 2>/dev/null | cut -d';' -f2,3; }

# "40G" (qm config) -> bytes
qm_bytes() {
  awk -v s="$1" 'BEGIN { n = s + 0; u = toupper(substr(s, length(s)))
    m = (u == "K") ? 1024 : (u == "M") ? 1048576 : (u == "G") ? 1073741824 : (u == "T") ? 1099511627776 : 1
    printf "%.0f", n * m }'
}

# Migration state of one disk, from the share's files/markers and (on PVE) the VM
# config. Output: "<done|busy|fail|todo|stale>|<text>".
disk_state() {
  local b=$1 slot=$2 conf=$3 pve=$4 r
  [[ -e $LOGS/$b.stale ]] && { echo "stale|stale - VM was restored on oVirt, export again"; return; }
  if ((pve)) && grep -q "^$slot:" <<<"$conf"; then
    if [[ -e $LOGS/import-$b.end ]]; then echo "done|imported"; else echo "done|on PVE (no import record)"; fi
    return
  fi
  if [[ -e $LOGS/import-$b.end ]]; then
    if ((pve)); then echo "fail|imported, but slot $slot is empty on the PVE VM"; else echo "done|imported"; fi
    return
  fi
  [[ -e $BASE/importing/$b.qcow2 ]] && { echo "busy|importing"; return; }
  [[ -e $BASE/$b.qcow2 ]]           && { echo "busy|exported, waiting for import"; return; }
  if [[ -e $BASE/$b.qcow2.part ]]; then
    # A partial file that isn't written to anymore is a leftover of an aborted run.
    r=$(( $(date +%s) - $(stat -c %Y "$BASE/$b.qcow2.part") ))
    if ((r > ${STALL_SEC:-2700})); then echo "fail|partial export file, no writes for $(hm "$r") - aborted run? rerun export"
    else echo "busy|exporting"; fi
    return
  fi
  [[ -e $LOGS/import-$b.fail ]]     && { echo "fail|import failed - see logs/import-$b.log"; return; }
  if [[ -e $LOGS/$b.fail ]]; then r=$(cat "$LOGS/$b.reason" 2>/dev/null); echo "fail|export failed${r:+: $r}"; return; fi
  [[ -e $LOGS/$b.queued ]]          && { echo "busy|queued for export"; return; }
  echo "todo|not exported yet"
}

# list: overview of all VMs in disks.csv with their full (thick) size, largest first.
# On oVirt: sizes from the engine (and cached for the PVE side).
# On PVE:   additionally which VMs and disks are already completely imported. A
# disk that isn't in the slot disks.csv names (e.g. moved from sata0 to scsi0
# after a driver fix) is matched by size against the VM's other disks.
cmd_list() {
  local mode=share
  if is_ovirt; then
    mode=ovirt; load_config "${VARS_OVIRT[@]}"; need_ovirt_api
  else
    load_config; is_pve && mode=pve
  fi
  csv_check

  local -a names=(); local -A seen=() block=() total=() vmid_of=()
  local name vmid disk slot boot info dname prov act sz al b st text conf pve=0 nd ndone busy fail vstat power r
  local line ps psz i k eff fmt where="-" sum=0 sumalloc=0 open=0 vms=0 vdone=0 missing_sizes=0 moved=0 ndisks=0
  [[ $mode == pve ]] && pve=1
  [[ $mode == ovirt ]] && where="ON OVIRT"; ((pve)) && where="ON PVE"
  fmt='%-20s %6s %-9s %9s %9s  %s'
  while IFS=';' read -r name vmid _ _ _ _; do
    [[ -n ${seen[$name]:-} ]] && continue
    seen[$name]=1; names+=("$name"); vmid_of[$name]=$vmid
  done < <(csv_all)

  for name in "${names[@]}"; do
    vmid=${vmid_of[$name]}; conf=""; power="-"
    if ((pve)); then
      conf=$(qm config "$vmid" 2>/dev/null) || conf="__missing__"
      [[ $conf == __missing__ ]] || power=$(qm status "$vmid" 2>/dev/null | awk '{print $2}')
    elif [[ $mode == ovirt ]]; then
      r=$(ovirt_vm "$(ovirt_name "$(csv_rows "$name")")"); power=${r#*;}; power=${power%%;*}; [[ -n $r ]] || power="not found"
    fi
    case $power in up) power=running;; down|stopped) power=off;; "") power="?";; esac

    # Disks of this VM from disks.csv, with sizes.
    local -a d_slot=() d_disk=() d_boot=() d_sz=() d_al=() d_name=() d_eff=() p_slot=() p_sz=()
    local -A claimed=()
    while IFS=';' read -r _ _ disk slot boot _; do
      dname=""; sz=""; al=""
      if [[ $mode == ovirt ]]; then
        info=$(disk_info "$disk"); IFS=';' read -r dname prov act <<<"$info"
        [[ -n $dname ]] || dname="(not found in oVirt!)"
        sz=$prov; al=$act; [[ $sz =~ ^[0-9]+$ ]] && size_cache_put "$disk" "$prov" "$act"
      else
        IFS=';' read -r sz al <<<"$(size_cache_get "$disk")"
        [[ $sz =~ ^[0-9]+$ ]] || sz=$(cat "$LOGS/$name-$slot.size" 2>/dev/null)
      fi
      [[ $al =~ ^[0-9]+$ ]] || al=""
      d_slot+=("$slot"); d_disk+=("$disk"); d_boot+=("$boot"); d_sz+=("$sz"); d_al+=("$al"); d_name+=("$dname"); d_eff+=("")
    done < <(csv_rows "$name")

    # PVE: disks the VM really has (slot + size), then match CSV disks to them -
    # first by slot, then by size for disks that live in another slot.
    if ((pve)) && [[ $conf != __missing__ ]]; then
      while IFS= read -r line; do
        [[ $line == *media=cdrom* ]] && continue
        ps=${line%%:*}; psz=$(grep -o 'size=[0-9.]*[KMGT]' <<<"$line" | cut -d= -f2)
        p_slot+=("$ps"); p_sz+=("$([[ -n $psz ]] && qm_bytes "$psz" || echo 0)")
      done < <(grep -E '^(scsi|sata|virtio|ide)[0-9]+:' <<<"$conf")
      for i in "${!d_slot[@]}"; do
        for k in "${!p_slot[@]}"; do
          [[ ${p_slot[k]} == "${d_slot[i]}" ]] || continue
          d_eff[i]=${p_slot[k]}; claimed[${p_slot[k]}]=1
          [[ ${d_sz[i]} =~ ^[0-9]+$ ]] || d_sz[i]=${p_sz[k]}
        done
      done
      for i in "${!d_slot[@]}"; do
        [[ -z ${d_eff[i]} && ${d_sz[i]} =~ ^[0-9]+$ ]] || continue
        for k in "${!p_slot[@]}"; do
          [[ -z ${claimed[${p_slot[k]}]:-} ]] || continue
          psz=$(( p_sz[k] - d_sz[i] )); psz=${psz#-}
          if ((psz <= 1073741824)); then d_eff[i]=${p_slot[k]}; claimed[${p_slot[k]}]=1; break; fi
        done
      done
    fi

    local -i t=0 ta=0; nd=0; ndone=0; busy=0; fail=0; block[$name]=""
    for i in "${!d_slot[@]}"; do
      nd=$((nd + 1)); slot=${d_slot[i]}; b="$name-$slot"; sz=${d_sz[i]}; al=${d_al[i]}
      [[ $sz =~ ^[0-9]+$ ]] || { sz=0; missing_sizes=1; }
      t+=sz; [[ -n $al ]] && ta+=al
      if [[ $mode == ovirt ]]; then
        text=${d_name[i]}
      else
        eff=${d_eff[i]:-$slot}
        IFS='|' read -r st text <<<"$(disk_state "$b" "$eff" "$conf" "$pve")"
        if [[ $eff != "$slot" ]]; then text="$text as $eff (matched by size; disks.csv says $slot)"; moved=1; fi
        case $st in done) ndone=$((ndone + 1));; busy) busy=$((busy + 1));; fail|stale) fail=$((fail + 1));; esac
      fi
      block[$name]+=$'\n'$(printf "$fmt" "  $slot$([[ ${d_boot[i]} == 1 ]] && echo " (boot)")" "" "" \
        "$( ((sz)) && gib "$sz" || echo "?")" "$( [[ -n $al ]] && gib "$al" || echo "-")" "$text  [${d_disk[i]:0:8}]")
    done

    if [[ $mode == ovirt ]]; then vstat="$nd disk(s)"
    elif [[ $conf == __missing__ ]]; then vstat="PVE VM $vmid missing"
    elif ((ndone == nd)); then vstat="COMPLETE"; vdone=$((vdone + 1))
    elif ((fail)); then vstat="ATTENTION ($ndone/$nd imported)"
    elif ((busy)); then vstat="in progress ($ndone/$nd imported)"
    elif ((ndone)); then vstat="partial ($ndone/$nd imported)"
    else vstat="not started"; fi
    ((ndone < nd)) && [[ $mode != ovirt ]] && open=$((open + t))
    total[$name]=$t; vms=$((vms + 1)); ndisks=$((ndisks + nd)); sum=$((sum + t)); sumalloc=$((sumalloc + ta))
    block[$name]=$(printf "$fmt" "$name" "$vmid" "$power" "$( ((t)) && gib "$t" || echo "?")" \
      "$( ((ta)) && gib "$ta" || echo "-")" "$vstat")${block[$name]}
  done

  echo
  printf "$fmt\n" "VM / DISK" PVE-ID "$where" SIZE ALLOC "$([[ $mode == ovirt ]] && echo "OVIRT DISK NAME  [DISK ID]" || echo "STATUS  [DISK ID]")"
  while read -r _ name; do printf '%s\n\n' "${block[$name]}"; done < <(for name in "${names[@]}"; do echo "${total[$name]} $name"; done | sort -k1,1nr)
  printf "$fmt\n" TOTAL "" "" "$(gib "$sum")" "$( ((sumalloc)) && gib "$sumalloc" || echo "-")" \
    "$ndisks disk(s) / $vms VM(s)"
  echo
  echo "SIZE  = full (thick) disk size; the space checks plan with it."
  echo "ALLOC = space the disk takes on the oVirt storage. On block storage this can exceed SIZE:"
  echo "        oVirt grows thin disks in steps and doesn't shrink them (e.g. after snapshots)."
  echo "        The export only contains the disk content, so it's never larger than SIZE."
  [[ $where != - ]] && echo "$where = power state of the VM on this hypervisor."

  if [[ $mode == ovirt ]]; then
    log "INFO   run '$0 list' on the PVE host to also see which VMs and disks are already imported"
  else
    echo "$vdone of $vms VMs complete on PVE; still to migrate: $(gib "$open") (full disk size)"
    ((pve)) || log "INFO   not a PVE host - import state is taken from the share only; run '$0 list' on the PVE host for the full comparison"
  fi
  ((moved)) && log "INFO   some disks sit in a different PVE slot than disks.csv says - update disks.csv to the real slots"
  ((missing_sizes)) && log "INFO   some sizes are unknown (?) - run '$0 list' on the oVirt host once to fetch them"
  return 0
}

# ---- status ---------------------------------------------------------------------
# Store a progress sample and print "STATE RATE ETA". The rate uses the last
# RATE_WINDOW seconds instead of the whole runtime, because slow phases make an
# average misleading. No progress for STALL_SEC shows STALL?.
progress() {
  local f=$1 now=$2 pct=$3 el=$4 size=$5 last
  last=$(tail -1 "$f" 2>/dev/null | awk '{print $2}')
  [[ $last == "$pct" ]] || echo "$now $pct" >> "$f"
  awk -v now="$now" -v pct="$pct" -v el="$el" -v size="$size" -v win="$RATE_WINDOW" -v stall="$STALL_SEC" '
    { t[NR] = $1; p[NR] = $2 }
    END {
      n = NR; st = "RUN"; r = 0; k = 0
      for (i = 1; i <= n; i++) if (t[i] >= now - win) { k = i; break }
      if (k && k < n && t[n] > t[k] && p[n] > p[k]) r = (p[n] - p[k]) / (t[n] - t[k])
      else if (el > 0 && pct > 0) r = pct / el
      if (n && pct < 100 && now - t[n] > stall) st = "STALL?"
      rate = (r > 0 && size > 0) ? sprintf("%.0fMB/s", r / 100 * size / 1048576) : "-"
      if (r > 0) { e = (100 - pct) / r - (now - t[n]); if (e < 0) e = 0
                   eta = sprintf("%dh%02dm", int(e / 3600), int((e % 3600) / 60)) }
      else eta = "?"
      print st, rate, eta
    }' "$f"
}

status_once() {
  local now s q b start stage disk pct st el rate eta size f v endf w=() hint=0
  now=$(date +%s)
  printf '%-7s %-26s %-6s %6s %8s %8s %8s\n' STAGE DISK STATE PCT ELAPSED RATE ETA
  for q in "$LOGS"/*.queued; do
    [[ -e $q ]] || continue
    b=$(basename "$q" .queued); [[ -e $LOGS/$b.start ]] && continue
    printf '%-7s %-26s %-6s %6s %8s %8s %8s\n' export "$b" QUEUED - - - -
  done
  for s in "$LOGS"/*.start; do
    [[ -e $s ]] || continue
    b=$(basename "$s" .start); start=$(<"$s")
    [[ $start =~ ^[0-9]+$ ]] || continue
    if [[ $b == import-* ]]; then
      stage="import"; disk=${b#import-}
      pct=$(grep -o '([0-9.]*%)' "$LOGS/$b.log" 2>/dev/null | tail -1 | tr -d '()%')
    else
      stage="export"; disk=$b
      pct=$(tr '\r' '\n' < "$LOGS/$b.log" 2>/dev/null | grep -o '[0-9.]*/100%' | tail -1 | cut -d/ -f1)
    fi
    pct=${pct:-0}; size=$(cat "$LOGS/$b.size" 2>/dev/null); size=${size:-0}
    rate=-; eta=-
    endf=""
    if   [[ -e $LOGS/$b.end  ]]; then st=DONE; pct=100; endf=$LOGS/$b.end
    elif [[ -e $LOGS/$b.fail ]]; then st=FAIL; endf=$LOGS/$b.fail; fi
    if [[ -n $endf ]]; then
      v=$(cat "$endf"); if [[ $v =~ ^[0-9]+$ ]]; then el=$((v - start)); else el=0; fi
    else
      el=$((now - start)); read -r st rate eta < <(progress "$LOGS/$b.samples" "$now" "$pct" "$el" "$size")
      # Direct signals beat the 1 % progress steps: is the process still there
      # (only visible on its own host), and is the file still being written?
      if [[ $stage == export ]]; then
        if is_ovirt && ! pgrep -f "qemu-img convert .*$BASE/$disk\.qcow2\.part" >/dev/null; then st=DEAD; rate=-; eta=-
        elif [[ ! -e $BASE/$disk.qcow2.part ]]; then st=DEAD; rate=-; eta=-
        else
          v=$(( now - $(stat -c %Y "$BASE/$disk.qcow2.part") ))
          ((v > STALL_SEC)) && { st="STALL?"; rate=-; eta=-; }
        fi
      elif is_pve && ! pgrep -f "qm set .*import-from=.*/$disk\.qcow2" >/dev/null; then
        st=DEAD; rate=-; eta=-
      fi
    fi
    printf '%-7s %-26s %-6s %5.1f%% %8s %8s %8s\n' "$stage" "$disk" "$st" "$pct" "$(hm "$el")" "$rate" "$eta"
    [[ $st == DEAD || $st == "STALL?" ]] && hint=1
  done
  echo
  if ((hint)); then
    echo "DEAD   = the process is gone without a result (killed, reboot, lost session) - rerun export/import for that disk"
    echo "STALL? = no data written for more than $(hm "$STALL_SEC") - check the process and the storage"
    echo
  fi
  for f in "$LOGS"/*.reason; do
    [[ -e $f && -e ${f%.reason}.fail ]] && echo "FAIL $(basename "$f" .reason): $(cat "$f")"
  done
  for f in "$BASE"/*.qcow2; do [[ -e $f ]] && w+=("$(basename "$f" .qcow2)"); done
  ((${#w[@]})) && echo "waiting for import: ${w[*]}"
  w=(); for f in "$BASE"/unmatched/*.qcow2; do [[ -e $f ]] && w+=("$(basename "$f" .qcow2)"); done
  ((${#w[@]})) && echo "UNMATCHED (not in disks.csv): ${w[*]}"
  share_df | awk -v lim="$EXPORT_MAX_PCT" '{printf "export share: %.0f of %.0f GiB used (%.0f%%, export limit %s%%)\n", $2/1073741824, $1/1073741824, $2*100/$1, lim}'
  if is_pve; then
    # One pvesm call only (it can take seconds); say so instead of silently dropping the line.
    v=$(pvesm status --storage "$STORAGE" 2>/dev/null | awk -v lim="$MAX_POOL_PCT" \
        'NR==2{printf "storage %s: %.0f of %.0f GiB used (%s, import limit %s%%)", $1, $5/1048576, $4/1048576, $7, lim}')
    echo "${v:-storage $STORAGE: no answer from pvesm status}"
  fi
}

cmd_status() {
  load_config "${VARS_STATUS[@]}"
  if ((WATCH)); then
    # Build the full output first, then redraw at once - slow parts don't flicker.
    local out
    while :; do out=$(date; echo; status_once); clear; printf '%s\n' "$out"; sleep "$WATCH"; done
  else
    status_once
  fi
}

usage() {
  cat <<EOF
Usage: $0 <command> [options] [vm...]

  export  <vm>...   (oVirt) shut down, move disks RO to the datamover, export to qcow2
  restore <vm>...   (oVirt) rollback: re-attach disks to the original VM incl. boot disk
  release <vm>...   (oVirt) detach disks from the datamover after a successful migration
  import            (PVE)   listen for exported disks, import + attach to the PVE VM
                            (--start: start each VM once all its disks are imported)
  status            (any)   progress, rate and ETA of exports and imports
  lookup  <name>... (oVirt) show a VM's disks and print ready-made disks.csv lines
  list              (any)   all VMs from disks.csv with their full size, largest first;
                            on PVE also which VMs/disks are already completely imported

Options:
  -y, --yes          no confirmation prompts
  -n, --dry-run      export/restore/release: show what would happen, change nothing
  -f, --force        export: re-export disks that were already exported
  -r, --restore-on-abort
                     export: if disks of a VM end up not exported (Ctrl-C, space
                     abort, error), put that VM back on oVirt and start it if it
                     was running; its exports from this attempt are moved to stale/
  -s, --start        restore: start the VM afterwards
                     import:  start each VM once all its disks from disks.csv are imported
  -w, --watch [sec]  status: refresh every <sec> seconds (default 60)

Config: $CONF (all settings required, see README; MIGRATE_CONF=/path overrides)
Files (next to this script): disks.csv, logs/, state/, importing/, imported/
EOF
}

main() {
  local cmd="" args=()
  while (($#)); do
    case $1 in
      -y|--yes)     YES=1 ;;
      -n|--dry-run) DRY_RUN=1 ;;
      -f|--force)   FORCE=1 ;;
      -s|--start)      START_VM=1 ;;
      -r|--restore-on-abort) RESTORE_ON_ABORT=1 ;;
      -w|--watch)   WATCH=60; if [[ ${2:-} =~ ^[0-9]+$ ]]; then WATCH=$2; shift; fi ;;
      -h|--help)    usage; exit 0 ;;
      -*)           die "unknown option: $1" ;;
      *)            if [[ -z $cmd ]]; then cmd=$1; else args+=("$1"); fi ;;
    esac
    shift
  done
  case $cmd in
    export)  cmd_export  "${args[@]}" ;;
    restore) cmd_restore "${args[@]}" ;;
    release) cmd_release "${args[@]}" ;;
    import)  cmd_import ;;
    status)  cmd_status ;;
    list)    cmd_list ;;
    lookup)  cmd_lookup "${args[@]}" ;;
    *)       usage; exit 1 ;;
  esac
}

main "$@"
