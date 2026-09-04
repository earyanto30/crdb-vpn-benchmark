#!/usr/bin/env bash
# ==============================================================================
# orchestrate.sh — Full TPC-C benchmark orchestration across 3 network modes
#
# Flow (minimal output: "<step> [ok|fail]"):
#   tofu apply infra and print inventory to ./inventory.yml
#   direct:       cockroach create+join (direct) → setup workload → bench → save to workload-result/direct/{1..5}  (×5)
#   restore snapshot
#   wireguard:    wg server+peer → cockroach create+join (wireguard) → setup → bench → wireguard/{1..5} (×5)
#   restore snapshot
#   wireguard-go: wg-go server+peer → cockroach create+join (wireguard) → setup → bench → wireguard-go/{1..5} (×5)
#   tofu destroy
#
# Usage: ./scripts/orchestrate.sh        # full flow
#        ./scripts/orchestrate.sh --dry   # show steps without executing
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
INVENTORY="./inventory.yml"
RESULT_BASE="./workload-result"
DRY="${1:-}"

# ── helpers: minimal output ───────────────────────────────────────────────────
step() {
  local label="$1"; shift
  local cmd="$*"
  printf "%-55s " "$label..."
  if [[ "$DRY" == "--dry" ]]; then echo "[dry] $cmd"; return 0; fi
  local log="/tmp/orch-$$.log"
  if bash -c "$cmd" >"$log" 2>&1; then
    echo "[ok]"
  else
    echo "[fail]"
    tail -n 50 "$log" | sed 's/^/  /' >&2
    echo "  log: $log" >&2
    exit 1
  fi
}

# allow extra vars for cockroach mode
COCKROACH_CREATE="ansible-playbook -i $INVENTORY playbook/setup-cockroachdb/create-cluster.yml"
COCKROACH_JOIN="ansible-playbook -i $INVENTORY playbook/setup-cockroachdb/join-cluster.yml"
WORKLOAD_SETUP="ansible-playbook -i $INVENTORY playbook/setup-workload-driver/setup.yml"
WORKLOAD_BENCH="ansible-playbook -i $INVENTORY playbook/setup-workload-driver/benchmark.yml"
WG_SERVER="ansible-playbook -i $INVENTORY playbook/setup-wireguard/server.yml"
WG_PEER="ansible-playbook -i $INVENTORY playbook/setup-wireguard/join-peer.yml"
WGG_SERVER="ansible-playbook -i $INVENTORY playbook/setup-wireguard-go/server.yml"
WGG_PEER="ansible-playbook -i $INVENTORY playbook/setup-wireguard-go/join-peer.yml"

# ── 1. infra ───────────────────────────────────────────────────────────────────
step "tofu apply" "tofu -chdir=infra/azure apply -auto-approve"
step "print inventory to $INVENTORY" "tofu -chdir=infra/azure output -raw ansible_inventory > $INVENTORY && test -s $INVENTORY && cp -f $INVENTORY playbook/inventory.yml 2>/dev/null || true && echo \"inventory: \$(wc -l < $INVENTORY) lines\""

# helper: save results for one iteration
save_result() {
  local phase="$1" iter="$2"
  local dest="$RESULT_BASE/$phase/$iter"
  mkdir -p "$dest"
  # from controller tmp (fetched by benchmark.yml)
  cp -f playbook/setup-workload-driver/tmp/benchmark.csv "$dest/" 2>/dev/null || true
  cp -f playbook/setup-workload-driver/tmp/benchmark-raw-*.csv "$dest/" 2>/dev/null || true
  # from driver VM (logs/hist) via scp using inventory host
  local driver_host
  driver_host="$(python3 -c "import yaml,sys; d=yaml.safe_load(open('$INVENTORY')); h=list(d['all']['children']['workload_driver']['hosts'].values())[0]; print(h.get('ansible_host',h.get('public_ip','')))" 2>/dev/null || echo "")"
  if [[ -n "$driver_host" ]]; then
    scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 "evan@${driver_host}:/home/evan/workload-results/tpcc-*.log" "$dest/" 2>/dev/null || true
    scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 "evan@${driver_host}:/home/evan/workload-results/tpcc-*.hist.json" "$dest/" 2>/dev/null || true
    scp -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 "evan@${driver_host}:/home/evan/workload-results/benchmark*.csv" "$dest/" 2>/dev/null || true
  fi
  # also copy tpcc-load log
  ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=10 "evan@${driver_host}" "cat /home/evan/workload-results/tpcc-load.log" > "$dest/tpcc-load.log" 2>/dev/null || true
  ls -1 "$dest" 2>/dev/null | wc -l | xargs echo "  saved $dest: "
}

# helper: restore snapshots (all 3 VMs) via tofu
restore_snapshot() {
  local label="restore snapshot"
  printf "%-55s " "$label..."
  if [[ "$DRY" == "--dry" ]]; then echo "[dry] tofu restore all vms"; return 0; fi
  local log="/tmp/orch-restore-$$.log"
  {
    for vm in vm-crdb-lease-sea-01 vm-crdb-replica-ea-01 vm-crdb-driver-sea-01; do
      tofu -chdir=infra/azure apply -auto-approve -var="restore_enabled=true" -var="restore_vm_name=$vm"
    done
    # wait for VMs to be back (port 22)
    sleep 15
    for h in $(python3 -c "import yaml; d=yaml.safe_load(open('$INVENTORY')); 
for g in ['cockroachdb','workload_driver']:
 for host,vars in d['all']['children'][g]['hosts'].items():
  print(vars.get('ansible_host',''))" 2>/dev/null | sort -u); do
      for i in $(seq 1 30); do nc -z -w 2 "${h%%:*}" 22 2>/dev/null && break; sleep 2; done
    done
  } >"$log" 2>&1
  if [[ $? -eq 0 ]]; then echo "[ok]"; else echo "[fail]"; tail -n 50 "$log" | sed 's/^/  /' >&2; exit 1; fi
}

run_bench_iterations() {
  local phase="$1" # direct|wireguard|wireguard-go — 5 iterations just for benchmark, print output
  for iter in $(seq 1 5); do
    printf "%-55s " "benchmark $phase $iter/5..."
    if [[ "$DRY" == "--dry" ]]; then echo "[dry] $WORKLOAD_BENCH"; step "save $phase/$iter" "save_result $phase $iter" > /dev/null; continue; fi
    local log="/tmp/orch-bench-${phase}-${iter}-$$.log"
    if $WORKLOAD_BENCH >"$log" 2>&1; then
      echo "[ok]"
      # print benchmark output (tpmC + CSV row) — as requested
      echo "  --- benchmark $phase $iter tpmC ---"
      grep -E 'tpmC|_elapsed.*tpmC' "$log" 2>/dev/null | tail -n 3 | sed 's/^/  /' || tail -n 20 "$log" | sed 's/^/  /'
      # show CSV row that was appended
      local csv="/home/evan/workload-results/benchmark.csv"
      # try driver via ssh, fallback to controller tmp
      if ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o ConnectTimeout=5 "evan@$(python3 -c "import yaml; d=yaml.safe_load(open('$INVENTORY')); h=list(d['all']['children']['workload_driver']['hosts'].values())[0]; print(h.get('ansible_host',''))" 2>/dev/null)" "tail -n 1 $csv 2>/dev/null" 2>/dev/null | sed 's/^/  csv: /'; then true
      else tail -n 1 playbook/setup-workload-driver/tmp/benchmark.csv 2>/dev/null | sed 's/^/  csv: /' || true
      fi
      # also show last 1 line of ansible output for tpmC
      grep -E 'tpmC' "$log" 2>/dev/null | tail -n 1 | sed 's/^/  /' || true
    else
      echo "[fail]"
      tail -n 80 "$log" | sed 's/^/  /' >&2
      exit 1
    fi
    step "save $phase/$iter" "save_result $phase $iter"
  done
}

# ── 2. DIRECT (5×) ───────────────────────────────────────────────────────────
step "cockroach create cluster (direct)" "$COCKROACH_CREATE -e crdb_advertise_mode=direct"
step "cockroach join cluster (direct)" "$COCKROACH_JOIN -e crdb_advertise_mode=direct"
step "setup workload" "$WORKLOAD_SETUP"
run_bench_iterations "direct" 5

restore_snapshot

# ── 3. WIREGUARD (kernel) (5×) ───────────────────────────────────────────────
step "wireguard server" "$WG_SERVER"
step "wireguard peer" "$WG_PEER"
step "cockroach create cluster (wireguard)" "$COCKROACH_CREATE -e crdb_advertise_mode=wireguard"
step "cockroach join cluster (wireguard)" "$COCKROACH_JOIN -e crdb_advertise_mode=wireguard"
step "setup workload" "$WORKLOAD_SETUP"
run_bench_iterations "wireguard" 5

restore_snapshot

# ── 4. WIREGUARD-GO (userspace) (5×) ─────────────────────────────────────────
step "wireguard-go server" "$WGG_SERVER"
step "wireguard-go peer" "$WGG_PEER"
# wireguard-go still uses wg0 interface, so same wireguard mode for cockroach
step "cockroach create cluster (wireguard-go)" "$COCKROACH_CREATE -e crdb_advertise_mode=wireguard"
step "cockroach join cluster (wireguard-go)" "$COCKROACH_JOIN -e crdb_advertise_mode=wireguard"
step "setup workload" "$WORKLOAD_SETUP"
run_bench_iterations "wireguard-go" 5

# ── 5. destroy ─────────────────────────────────────────────────────────────────
step "tofu destroy" "tofu -chdir=infra/azure destroy -auto-approve"

echo ""
echo "All done — results in $RESULT_BASE/direct/, $RESULT_BASE/wireguard/, $RESULT_BASE/wireguard-go/"
ls -R "$RESULT_BASE" 2>/dev/null | head -n 50
