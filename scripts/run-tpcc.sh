#!/usr/bin/env bash
# ==============================================================================
# run-tpcc.sh — Portable TPC-C benchmark runner for CockroachDB & PostgreSQL
#
# Runs anywhere (local, driver VM, CI) against any cockroach/postgres wire
# compatible DB. Uses native workload for each DB:
#   cockroachdb → cockroach workload init/run tpcc (INSERT loader, no GCS)
#   postgres    → go-tpcc tpcc prepare/run (falls back to cockroach workload if go-tpcc missing)
#
# Features:
#   - Auto-install cockroach / go-tpcc if missing
#   - TLS support (cockroach: --certs-dir + CA, postgres: sslmode)
#   - Idempotent init with --drop (scale 10→100)
#   - Tunable warehouses / concurrency / duration / tolerates
#   - Histograms + log + tpmC printed to terminal and saved
#
# Usage:
#   ./scripts/run-tpcc.sh --db-type cockroach --host 127.0.0.1 --port 26257 --user dbadmin --password dbadmin --warehouses 10 --concurrency 10 --duration 10m
#   ./scripts/run-tpcc.sh --db-type postgres  --host pg.example.com --port 5432 --user tpcc --password secret --warehouses 10 --concurrency 10 --duration 10m --database tpcc
#   ./scripts/run-tpcc.sh --help
#
# Env overrides: DB_TYPE, DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME,
#                WAREHOUSES, CONCURRENCY, DURATION, CERTS_DIR, RESULTS_DIR
# ==============================================================================
set -euo pipefail

# --- colors ---
if [[ -t 1 ]]; then
  BOLD='\033[1m'; DIM='\033[2m'; RED='\033[0;31m'; GREEN='\033[0;32m'
  YELLOW='\033[1;33m'; BLUE='\033[0;34m'; MAGENTA='\033[0;35m'; CYAN='\033[0;36m'; NC='\033[0m'
else BOLD=''; DIM=''; RED=''; GREEN=''; YELLOW=''; BLUE=''; MAGENTA=''; CYAN=''; NC=''; fi

say_step()    { printf "\n${BOLD}${MAGENTA}==>${NC} ${BOLD}%s${NC}\n" "$*"; }
say_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
say_success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
say_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2; }
say_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }
die() { say_error "$*"; exit 1; }

# --- defaults (env overrideable, then CLI) ---
DB_TYPE="${DB_TYPE:-cockroach}"          # cockroach|postgres|auto
DB_HOST="${DB_HOST:-127.0.0.1}"
DB_PORT="${DB_PORT:-}"                   # auto: 26257 for cockroach, 5432 for postgres
DB_USER="${DB_USER:-dbadmin}"
DB_PASSWORD="${DB_PASSWORD:-dbadmin}"
DB_NAME="${DB_NAME:-tpcc}"
WAREHOUSES="${WAREHOUSES:-10}"
CONCURRENCY="${CONCURRENCY:-10}"
DURATION="${DURATION:-10m}"
CERTS_DIR="${CERTS_DIR:-}"
RESULTS_DIR="${RESULTS_DIR:-./workload-results}"
TOLERATE_ERRORS="${TOLERATE_ERRORS:-true}"
DROP_EXISTING="${DROP_EXISTING:-true}"   # --drop for workload init to allow 10→100
DO_INIT="${DO_INIT:-true}"               # run init/prepare if warehouse count != expected
DO_RUN="${DO_RUN:-true}"
# Load tuning — maximize throughput (was 10% with default 16 conns)
WORKERS="${WORKERS:-0}"                  # 0=auto (warehouses*10), else explicit (e.g. 100, 1000)
INIT_CONNS="${INIT_CONNS:-64}"           # INSERT init connections, default 16 → 64 is 4x faster
DATA_LOADER="${DATA_LOADER:-INSERT}"     # INSERT (offline, no GCS) | IMPORT (GCS, ~3x faster) | AUTO
MAX_RATE="${MAX_RATE:-0}"                # 0=unlimited (maximize), else ops/sec
COCKROACH_BIN="${COCKROACH_BIN:-/usr/local/bin/cockroach}"
COCKROACH_URL="${COCKROACH_URL:-https://binaries.cockroachdb.com/cockroach-v26.2.5.linux-amd64.tgz}"
GOTPCC_BIN="${GOTPCC_BIN:-$HOME/go/bin/go-tpcc}"
GOTPCC_REPO="${GOTPCC_REPO:-github.com/pingcap/go-tpcc/cmd/go-tpcc@latest}"

usage() {
  cat <<EOF
${BOLD}run-tpcc.sh — Portable TPC-C for CockroachDB / PostgreSQL${NC}

${BOLD}USAGE:${NC}
  $0 [OPTIONS]

${BOLD}OPTIONS:${NC}
  --db-type TYPE        cockroach|postgres|auto  (default: $DB_TYPE)
  --host HOST           DB host (default: $DB_HOST)
  --port PORT           DB port (default: 26257 cockroach, 5432 postgres)
  --user USER           DB user (default: $DB_USER)
  --password PASS       DB password (default: dbadmin, env DB_PASSWORD)
  --database DB         TPCC database (default: $DB_NAME)
  --certs-dir DIR       TLS certs dir (cockroach: ca.crt + client certs). Enables sslmode=require
  --warehouses N        Number of warehouses (default: $WAREHOUSES, scale 10→100 needs --drop)
  --concurrency N       Workers/concurrency (default: $CONCURRENCY, best-practice = warehouses)
  --duration D          Benchmark duration, e.g. 10m, 5m, 60s (default: $DURATION)
  --results-dir DIR     Save logs/histograms (default: $RESULTS_DIR)
  --workers N           Load workers (default: $WORKERS, 0=auto warehouses*10) — increase to 100-1000 for faster load
  --init-conns N        Load init connections (default: $INIT_CONNS, 16→64 is 4x faster)
  --data-loader TYPE    INSERT|IMPORT|AUTO (default: $DATA_LOADER, INSERT=offline, IMPORT=GCS fastest)
  --max-rate N          Max rate ops/sec, 0=unlimited (default: $MAX_RATE)
  --[no-]init           Run init/prepare if needed (default: $DO_INIT)
  --[no-]run            Run benchmark (default: $DO_RUN)
  --[no-]tolerate-errors Pass --tolerate-errors to cockroach workload (default: $TOLERATE_ERRORS)
  --[no-]drop           Pass --drop to workload init to allow scaling (default: $DROP_EXISTING)
  --cockroach-bin PATH  Path to cockroach binary (default: $COCKROACH_BIN)
  --go-tpcc-bin PATH    Path to go-tpcc binary (default: $GOTPCC_BIN)
  -h, --help            Show this help

${BOLD}EXAMPLES:${NC}
  # CockroachDB (TLS, dbadmin) — same as Ansible driver (10 wh, 10 conc, 10m)
  $0 --db-type cockroach --host 4.193.214.79 --port 26257 --user dbadmin --warehouses 10 --concurrency 10 --duration 10m --certs-dir /home/evan/cockroach-certs

  # PostgreSQL (go-tpcc, no TLS)
  $0 --db-type postgres --host pg.example.com --port 5432 --user tpcc --password secret --warehouses 10 --concurrency 10 --duration 10m --database tpcc

  # Local cockroach insecure (dev)
  $0 --db-type cockroach --host 127.0.0.1 --port 26257 --user root --warehouses 10 --certs-dir ""

  # Scale 10 → 100 (drops and reloads)
  $0 --warehouses 100 --concurrency 10 --duration 10m

Env overrides: DB_TYPE DB_HOST DB_PORT DB_USER DB_PASSWORD DB_NAME WAREHOUSES CONCURRENCY DURATION CERTS_DIR
EOF
}

# --- arg parse ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-type) DB_TYPE="$2"; shift 2;;
    --host) DB_HOST="$2"; shift 2;;
    --port) DB_PORT="$2"; shift 2;;
    --user) DB_USER="$2"; shift 2;;
    --password) DB_PASSWORD="$2"; shift 2;;
    --database) DB_NAME="$2"; shift 2;;
    --certs-dir) CERTS_DIR="$2"; shift 2;;
    --warehouses) WAREHOUSES="$2"; shift 2;;
    --concurrency) CONCURRENCY="$2"; shift 2;;
    --duration) DURATION="$2"; shift 2;;
    --results-dir) RESULTS_DIR="$2"; shift 2;;
    --workers) WORKERS="$2"; shift 2;;
    --init-conns) INIT_CONNS="$2"; shift 2;;
    --data-loader) DATA_LOADER="$2"; shift 2;;
    --max-rate) MAX_RATE="$2"; shift 2;;
    --cockroach-bin) COCKROACH_BIN="$2"; shift 2;;
    --go-tpcc-bin) GOTPCC_BIN="$2"; shift 2;;
    --init) DO_INIT=true; shift;;
    --no-init) DO_INIT=false; shift;;
    --run) DO_RUN=true; shift;;
    --no-run) DO_RUN=false; shift;;
    --tolerate-errors) TOLERATE_ERRORS=true; shift;;
    --no-tolerate-errors) TOLERATE_ERRORS=false; shift;;
    --drop) DROP_EXISTING=true; shift;;
    --no-drop) DROP_EXISTING=false; shift;;
    -h|--help) usage; exit 0;;
    --) shift; break;;
    -*) die "unknown flag $1 (see --help)";;
    *) break;;
  esac
done

# --- normalize ---
DB_TYPE="$(echo "$DB_TYPE" | tr '[:upper:]' '[:lower:]')"
if [[ "$DB_TYPE" == "auto" ]]; then
  if command -v cockroach >/dev/null 2>&1 || [[ -x "$COCKROACH_BIN" ]]; then DB_TYPE="cockroach"; else DB_TYPE="postgres"; fi
fi
if [[ -z "$DB_PORT" ]]; then
  if [[ "$DB_TYPE" == "postgres" ]]; then DB_PORT="5432"; else DB_PORT="26257"; fi
fi
if ! [[ "$WAREHOUSES" =~ ^[0-9]+$ ]] || (( WAREHOUSES < 1 )); then die "--warehouses must be integer >=1"; fi
if ! [[ "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then die "--concurrency must be integer >=1"; fi
if ! [[ "$WORKERS" =~ ^[0-9]+$ ]]; then die "--workers must be integer >=0 (0=auto)"; fi
if ! [[ "$INIT_CONNS" =~ ^[0-9]+$ ]] || (( INIT_CONNS < 1 )); then die "--init-conns must be integer >=1"; fi
if ! [[ "$MAX_RATE" =~ ^[0-9]+$ ]]; then die "--max-rate must be integer >=0"; fi
if ! [[ "$DURATION" =~ ^[0-9]+[smh]$ ]]; then say_warn "--duration '$DURATION' should be like 10m, 60s, 1h (best-practice 10m)"; fi

# --- helpers ---
ensure_cockroach() {
  if [[ -x "$COCKROACH_BIN" ]]; then
    say_info "cockroach: $("$COCKROACH_BIN" version 2>&1 | head -n1)"
    return 0
  fi
  if command -v cockroach >/dev/null 2>&1; then
    COCKROACH_BIN="$(command -v cockroach)"
    say_info "cockroach: $($COCKROACH_BIN version 2>&1 | head -n1)"
    return 0
  fi
  say_step "Installing cockroach binary to $COCKROACH_BIN"
  local tmp
  tmp="$(mktemp -d /tmp/cockroach-install-XXXXXX)"
  trap 'rm -rf "$tmp"' RETURN
  local tgz="$tmp/cockroach.tgz"
  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --progress-bar --output "$tgz" "$COCKROACH_URL" || die "download failed $COCKROACH_URL"
  elif command -v wget >/dev/null 2>&1; then
    wget --progress=bar:force --tries=3 --output-document="$tgz" "$COCKROACH_URL" || die "download failed $COCKROACH_URL"
  else die "need curl or wget to install cockroach"; fi
  tar -xzf "$tgz" -C "$tmp"
  local bin
  bin="$(find "$tmp" -type f -name "cockroach" -perm -111 2>/dev/null | head -n1)"
  [[ -z "$bin" ]] && bin="$(find "$tmp" -type f -name "cockroach" 2>/dev/null | head -n1)"
  [[ -f "$bin" ]] || die "cockroach binary not found in archive"
  # Install binary — try without sudo first (handles COCKROACH_BIN=/tmp/*), fall back to sudo -n
  if [[ -w "$(dirname "$COCKROACH_BIN")" ]] 2>/dev/null; then
    install -m 0755 "$bin" "$COCKROACH_BIN" || die "install failed to $COCKROACH_BIN"
  elif command -v sudo >/dev/null 2>&1; then
    sudo -n install -m 0755 "$bin" "$COCKROACH_BIN" 2>/dev/null || sudo install -m 0755 "$bin" "$COCKROACH_BIN" || install -m 0755 "$bin" "$COCKROACH_BIN" || die "install failed to $COCKROACH_BIN (try COCKROACH_BIN=/tmp/cockroach)"
  else
    install -m 0755 "$bin" "$COCKROACH_BIN" || die "install failed to $COCKROACH_BIN"
  fi
  local lib
  lib="$(find "$tmp" -type d -name "lib" 2>/dev/null | head -n1)"
  if [[ -n "$lib" && -d "$lib" ]]; then
    # GEOS lib is optional — never fail benchmark if it needs sudo and sudo is unavailable
    mkdir -p /usr/local/lib/cockroach 2>/dev/null || sudo -n mkdir -p /usr/local/lib/cockroach 2>/dev/null || true
    cp -r "$lib"/* /usr/local/lib/cockroach/ 2>/dev/null || sudo -n cp -r "$lib"/* /usr/local/lib/cockroach/ 2>/dev/null || true
    ldconfig 2>/dev/null || sudo -n ldconfig 2>/dev/null || true
  fi
  say_success "cockroach installed: $($COCKROACH_BIN version 2>&1 | head -n1)"
}

ensure_gotpcc() {
  if [[ -x "$GOTPCC_BIN" ]]; then say_info "go-tpcc: $GOTPCC_BIN"; return 0; fi
  if command -v go-tpcc >/dev/null 2>&1; then GOTPCC_BIN="$(command -v go-tpcc)"; say_info "go-tpcc: $GOTPCC_BIN"; return 0; fi
  say_step "Installing go-tpcc to $GOTPCC_BIN (requires Go)"
  if ! command -v go >/dev/null 2>&1; then
    die "Go not found (needed for go-tpcc). Install golang-go or use --db-type cockroach to use 'cockroach workload' instead"
  fi
  mkdir -p "$(dirname "$GOTPCC_BIN")"
  GOBIN="$(dirname "$GOTPCC_BIN")" go install "$GOTPCC_REPO" || die "go install $GOTPCC_REPO failed"
  # go install creates binary named 'go-tpcc' (from cmd/go-tpcc) as 'go-tpcc' or 'go-tpcc'?
  if [[ ! -x "$GOTPCC_BIN" && -x "$(dirname "$GOTPCC_BIN")/go-tpcc" ]]; then GOTPCC_BIN="$(dirname "$GOTPCC_BIN")/go-tpcc"; fi
  # fallback: binary may be named 'tpcc'
  if [[ ! -x "$GOTPCC_BIN" ]]; then GOTPCC_BIN="$(find "$(dirname "$GOTPCC_BIN")" -maxdepth 1 -type f -name "*tpcc*" | head -n1)"; fi
  [[ -x "$GOTPCC_BIN" ]] || die "go-tpcc not found after install"
  say_success "go-tpcc installed: $GOTPCC_BIN"
}

build_pgurl_cockroach() {
  # postgres://user:pass@host:port/db?sslmode=...&sslrootcert=...
  local url="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"
  if [[ -n "$CERTS_DIR" && -f "$CERTS_DIR/ca.crt" ]]; then
    url="${url}&sslrootcert=${CERTS_DIR}/ca.crt"
  elif [[ -n "$CERTS_DIR" ]]; then
    say_warn "--certs-dir $CERTS_DIR has no ca.crt, using sslmode=require without rootcert"
  else
    # no certs -> insecure? keep require without cert for now, user can override via DB_PASSWORD env
    url="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
    # if password is empty and user root, cockroach insecure often uses sslmode=disable
    if [[ "$DB_USER" == "root" && -z "$DB_PASSWORD" ]]; then url="postgres://${DB_USER}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"; fi
  fi
  printf '%s' "$url"
}

check_sql() {
  local expect="$1"  # expected warehouse count or empty to just test connectivity
  local cnt
  cnt="$(COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT count(*) FROM ${DB_NAME}.warehouse;" 2>&1 | tr -d ' \r' | grep -E '^[0-9]+$' | tail -n1 || true)"
  if [[ -z "$expect" ]]; then
    COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT 1;" >/dev/null 2>&1
    return $?
  fi
  [[ "$cnt" == "$expect" ]]
}

# --- main ---
say_step "TPC-C benchmark — $DB_TYPE @ $DB_HOST:$DB_PORT (warehouses=$WAREHOUSES, concurrency=$CONCURRENCY, duration=$DURATION)"
say_info "User=$DB_USER DB=$DB_NAME TLS=${CERTS_DIR:-none} results=$RESULTS_DIR"
mkdir -p "$RESULTS_DIR"

if [[ "$DB_TYPE" == "cockroach" ]]; then
  ensure_cockroach
  # connectivity
  say_step "Checking SQL connectivity (TLS, $DB_USER)"
  if ! COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT 1;" 2>&1 | tail -n 20; then
    say_warn "sql check failed, trying without --certs-dir (insecure fallback log)"
    COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT 1;" 2>&1 | tail -n 20 || true
  fi
  # check warehouse count
  say_step "Checking existing warehouses (expect $WAREHOUSES)"
  CURRENT="$(COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT count(*) FROM ${DB_NAME}.warehouse;" 2>&1 | tr -d ' \r' | grep -E '^[0-9]+$' | tail -n1 || echo "0")"
  [[ -z "$CURRENT" ]] && CURRENT=0
  say_info "warehouse count: $CURRENT (expected $WAREHOUSES)"
  PGURL="$(build_pgurl_cockroach)"
  say_info "PGURL: postgres://${DB_USER}:****@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require"

  if [[ "$DO_INIT" == "true" && "$CURRENT" != "$WAREHOUSES" ]]; then
    say_step "Loading TPCC fixtures (warehouses=$WAREHOUSES, data-loader=$DATA_LOADER, workers=${WORKERS:-auto}, init-conns=$INIT_CONNS, --drop=${DROP_EXISTING}) — tuned for max throughput (was 10% with default 16 conns)"
    # Tune cluster for bulk ingest (reverted after load) — speeds INSERT by 2-4x on 2-node
    say_info "Tuning cluster bulk I/O for fast ingest..."
    COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SET CLUSTER SETTING bulkio.backup.proxy_file_writes.enabled = off; SET CLUSTER SETTING kv.bulk_io_write.max_rate = '2GiB'; SET CLUSTER SETTING kv.bulk_io_write.concurrent_addsstable_requests = 64;" 2>&1 | tail -n 5 || true
    drop_flag=""; [[ "$DROP_EXISTING" == "true" ]] && drop_flag="--drop"
    workers_flag=""; [[ "$WORKERS" != "0" ]] && workers_flag="--workers=$WORKERS"
    max_rate_flag=""; [[ "$MAX_RATE" != "0" ]] && max_rate_flag="--max-rate=$MAX_RATE"
    say_info "Command: $COCKROACH_BIN workload init tpcc --data-loader $DATA_LOADER --warehouses=$WAREHOUSES --init-conns=$INIT_CONNS $workers_flag $max_rate_flag $drop_flag \"$PGURL\""
    # shellcheck disable=SC2086
    if ! COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" workload init tpcc --data-loader "$DATA_LOADER" --warehouses="$WAREHOUSES" --init-conns="$INIT_CONNS" $workers_flag $max_rate_flag $drop_flag "$PGURL" 2>&1 | tee "$RESULTS_DIR/tpcc-load.log"; then
      say_error "workload init failed — see $RESULTS_DIR/tpcc-load.log"
      tail -n 100 "$RESULTS_DIR/tpcc-load.log" | sed 's/^/  /'
      die "init failed"
    fi
    tail -n 50 "$RESULTS_DIR/tpcc-load.log" | sed 's/^/  /'
    # restore bulk tuning (best-effort)
    say_info "Restoring cluster bulk settings..."
    COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SET CLUSTER SETTING bulkio.backup.proxy_file_writes.enabled = default; SET CLUSTER SETTING kv.bulk_io_write.max_rate = default; SET CLUSTER SETTING kv.bulk_io_write.concurrent_addsstable_requests = default;" 2>&1 | tail -n 5 || true
    # verify
    verify="$(COCKROACH_PASSWORD="$DB_PASSWORD" timeout 15 "$COCKROACH_BIN" sql --certs-dir="${CERTS_DIR:-/var/lib/cockroach/certs}" --host="${DB_HOST}:${DB_PORT}" --user="$DB_USER" --execute="SELECT count(*) FROM ${DB_NAME}.warehouse;" 2>&1 | tr -d ' \r' | grep -E '^[0-9]+$' | tail -n1 || echo "0")"
    if [[ "$verify" != "$WAREHOUSES" ]]; then
      say_error "after init, warehouse count $verify != $WAREHOUSES — check $RESULTS_DIR/tpcc-load.log"
      die "warehouse verify failed"
    fi
    say_success "TPCC loaded: $verify warehouses"
  else
    say_info "TPCC init skipped (already $CURRENT warehouses, --no-init or count matches)"
  fi

  if [[ "$DO_RUN" == "true" ]]; then
    say_step "Running TPCC workload (warehouses=$WAREHOUSES, concurrency=$CONCURRENCY, duration=$DURATION)"
    ts=""; hist=""; log=""; tolerate=""
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    hist="$RESULTS_DIR/tpcc-${ts}.hist.json"
    log="$RESULTS_DIR/tpcc-${ts}.log"
    [[ "$TOLERATE_ERRORS" == "true" ]] && tolerate="--tolerate-errors"
    say_info "histograms: $hist  log: $log"
    dur_secs=""
    dur_secs="$(echo "$DURATION" | sed -E 's/([0-9]+)m/\1*60/; s/([0-9]+)s/\1/; s/([0-9]+)h/\1*3600/' | bc 2>/dev/null || echo 600)"
    # shellcheck disable=SC2086
    COCKROACH_PASSWORD="$DB_PASSWORD" timeout $((dur_secs + 300)) "$COCKROACH_BIN" workload run tpcc \
      --warehouses="$WAREHOUSES" --concurrency="$CONCURRENCY" --duration="$DURATION" $tolerate \
      --histograms="$hist" "$PGURL" 2>&1 | tee "$log"
    rc=${PIPESTATUS[0]}
    echo "--- tpmC summary ---"
    grep -E 'tpmC|warehouses|_elapsed' "$log" | tail -n 30 | sed 's/^/  /' || true
    echo "--- histograms $hist ($(wc -l < "$hist" 2>/dev/null || echo 0) lines) ---"
    ls -lh "$hist" "$log" 2>&1 | sed 's/^/  /'
    if (( rc != 0 )); then say_warn "workload run exited rc=$rc (tolerate-errors may be expected)"; fi
    say_success "Benchmark done — log: $log hist: $hist"
  fi

elif [[ "$DB_TYPE" == "postgres" ]]; then
  # --- postgres path: prefer go-tpcc, fallback to cockroach workload with postgres URI ---
  if command -v "$GOTPCC_BIN" >/dev/null 2>&1 || [[ -x "$GOTPCC_BIN" ]] || command -v go >/dev/null 2>&1; then
    ensure_gotpcc
    say_step "Checking postgres connectivity (go-tpcc via psql check)"
    if command -v psql >/dev/null 2>&1; then
      PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -c "SELECT 1;" 2>&1 | tail -n 20 || say_warn "psql check failed (maybe DB not yet created, will be created by prepare)"
    else
      say_warn "psql not found — skipping connectivity check"
    fi
    # prepare if needed (go-tpcc prepare checks warehouse count internally, use --drop if scaled)
    if [[ "$DO_INIT" == "true" ]]; then
      say_step "Preparing TPCC data (go-tpcc, warehouses=$WAREHOUSES)"
      goresults="$RESULTS_DIR/go-tpcc-prepare.log"
      # go-tpcc prepare: ./go-tpcc tpcc --warehouses 10 --threads 10 prepare --host ... --port ... --user ... --password ... --db tpcc
      # Use threads = warehouses for prepare as well
      if ! "$GOTPCC_BIN" tpcc --warehouses "$WAREHOUSES" --threads "$CONCURRENCY" prepare \
           --host "$DB_HOST" --port "$DB_PORT" --user "$DB_USER" --password "$DB_PASSWORD" --db "$DB_NAME" 2>&1 | tee "$goresults"; then
        say_error "go-tpcc prepare failed — see $goresults"
        tail -n 100 "$goresults" | sed 's/^/  /'
        # fallback: try cockroach workload init against postgres wire (cockroach is postgres-compatible)
        say_warn "falling back to 'cockroach workload init' against postgres"
        ensure_cockroach
        PGURL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
        [[ -n "$CERTS_DIR" ]] && PGURL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require&sslrootcert=${CERTS_DIR}/ca.crt"
        workers_flag=""; [[ "$WORKERS" != "0" ]] && workers_flag="--workers=$WORKERS"
        max_rate_flag=""; [[ "$MAX_RATE" != "0" ]] && max_rate_flag="--max-rate=$MAX_RATE"
        COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" workload init tpcc --data-loader "$DATA_LOADER" --warehouses="$WAREHOUSES" --init-conns="$INIT_CONNS" $workers_flag $max_rate_flag --drop "$PGURL" 2>&1 | tee -a "$goresults" || true
      fi
      tail -n 50 "$goresults" | sed 's/^/  /'
    fi
    if [[ "$DO_RUN" == "true" ]]; then
      say_step "Running TPCC via go-tpcc (warehouses=$WAREHOUSES, threads=$CONCURRENCY, time=$DURATION)"
      ts=""; log=""
      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      log="$RESULTS_DIR/go-tpcc-${ts}.log"
      # go-tpcc run: --time 10m --warehouses 10 --threads 10
      "$GOTPCC_BIN" tpcc --warehouses "$WAREHOUSES" --threads "$CONCURRENCY" run \
        --host "$DB_HOST" --port "$DB_PORT" --user "$DB_USER" --password "$DB_PASSWORD" --db "$DB_NAME" --time "$DURATION" 2>&1 | tee "$log"
      rc=${PIPESTATUS[0]}
      echo "--- go-tpcc summary ---"
      grep -E 'tpmC|took|threads|warehouses' "$log" | tail -n 30 | sed 's/^/  /' || tail -n 30 "$log" | sed 's/^/  /'
      ls -lh "$log" | sed 's/^/  /'
      (( rc != 0 )) && say_warn "go-tpcc exited rc=$rc"
      say_success "Benchmark done — log: $log"
    fi
  else
    # no go, use cockroach workload against postgres wire protocol
    ensure_cockroach
    PGURL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=disable"
    if [[ -n "$CERTS_DIR" && -f "$CERTS_DIR/ca.crt" ]]; then PGURL="postgres://${DB_USER}:${DB_PASSWORD}@${DB_HOST}:${DB_PORT}/${DB_NAME}?sslmode=require&sslrootcert=${CERTS_DIR}/ca.crt"; fi
    say_warn "go-tpcc not found, using cockroach workload against postgres wire at $PGURL"
    # reuse cockroach path above (same as cockroach DB) but without certs-dir sql checks
    if [[ "$DO_INIT" == "true" ]]; then
      say_step "Loading TPCC via cockroach workload init (postgres wire, INSERT)"
      workers_flag=""; [[ "$WORKERS" != "0" ]] && workers_flag="--workers=$WORKERS"
      max_rate_flag=""; [[ "$MAX_RATE" != "0" ]] && max_rate_flag="--max-rate=$MAX_RATE"
      COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" workload init tpcc --data-loader "$DATA_LOADER" --warehouses="$WAREHOUSES" --init-conns="$INIT_CONNS" $workers_flag $max_rate_flag --drop "$PGURL" 2>&1 | tee "$RESULTS_DIR/tpcc-load.log" || true
    fi
    if [[ "$DO_RUN" == "true" ]]; then
      ts="$(date -u +%Y%m%dT%H%M%SZ)"; hist="$RESULTS_DIR/tpcc-${ts}.hist.json"; log="$RESULTS_DIR/tpcc-${ts}.log"
      COCKROACH_PASSWORD="$DB_PASSWORD" "$COCKROACH_BIN" workload run tpcc --warehouses="$WAREHOUSES" --concurrency="$CONCURRENCY" --duration="$DURATION" --histograms="$hist" "$PGURL" 2>&1 | tee "$log" || true
      grep -E 'tpmC' "$log" | tail -n 5 | sed 's/^/  /' || true
    fi
  fi
else
  die "unknown --db-type $DB_TYPE (expected cockroach|postgres)"
fi

say_success "All done — results in $RESULTS_DIR"
ls -lh "$RESULTS_DIR" | tail -n 20 | sed 's/^/  /'
