#!/usr/bin/env bash
# Automated End-to-End CockroachDB Replication & Benchmark Runner

set -euo pipefail

# --- Root Directory Resolution ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${PROJECT_DIR}"

# --- Configuration Constants ---
INVENTORY="${PROJECT_DIR}/inventory.yml"
TF_DIR="${PROJECT_DIR}/infra/azure"
PLAYBOOK_DIR="${PROJECT_DIR}/playbook"
WORKLOAD_RESULTS_DIR="${PROJECT_DIR}/workload-result"
STATE_FILE="${PROJECT_DIR}/.pipeline_state"
NUM_ITERATIONS=5

# --- State & Checkpoint Management ---
is_step_done() {
  local step="$1"
  [[ -f "${STATE_FILE}" ]] && grep -Fxq "${step}" "${STATE_FILE}" 2>/dev/null
}

mark_step_done() {
  local step="$1"
  mkdir -p "$(dirname "${STATE_FILE}")"
  echo "${step}" >> "${STATE_FILE}"
  say_info "Checkpoint saved: ${step}"
}

clear_state() {
  rm -f "${STATE_FILE}"
  say_info "Pipeline state cleared."
}

# --- Terminal Styling ---
if [[ -t 1 ]]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  BOLD=''
  DIM=''
  RED=''
  GREEN=''
  YELLOW=''
  BLUE=''
  MAGENTA=''
  CYAN=''
  NC=''
fi

say_step() {
  printf "\n${BOLD}${MAGENTA}==>${NC} ${BOLD}%s${NC}\n" "$*"
}

say_info() {
  printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

say_success() {
  printf "${GREEN}[SUCCESS]${NC} %s\n" "$*"
}

say_warn() {
  printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2
}

say_error() {
  printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

die() {
  say_error "$*"
  exit 1
}

# --- Check Prerequisites ---
check_prerequisites() {
  say_step "Checking local environment dependencies"

  for cmd in tofu ansible-playbook az python3 ssh scp; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      die "Missing required command: '$cmd'. Please ensure it is installed and in PATH."
    fi
  done

  # Verify Python PyYAML is available
  if ! python3 -c "import yaml" >/dev/null 2>&1; then
    die "Python PyYAML module is required. Install with: pip install pyyaml"
  fi

  # Verify Azure CLI authentication
  if ! az account show >/dev/null 2>&1; then
    die "Azure CLI is not authenticated. Please run 'az login' before executing this pipeline."
  fi

  local account_name
  account_name=$(az account show --query name -o tsv 2>/dev/null || echo "unknown")
  say_success "Azure account verified: ${account_name}"

  # Ensure all playbook vars files exist (auto-initialize from -example if absent)
  local var_files=(
    "setup-cockroachdb/vars/cockroach"
    "setup-wireguard/vars/wireguard"
    "setup-wireguard-go/vars/wireguard"
    "setup-workload-driver/vars/driver"
  )
  for item in "${var_files[@]}"; do
    local target_yml="${PLAYBOOK_DIR}/${item}.yml"
    local example_yml="${PLAYBOOK_DIR}/${item}.yml-example"
    if [[ ! -f "${target_yml}" && -f "${example_yml}" ]]; then
      cp "${example_yml}" "${target_yml}"
      say_info "Auto-initialized ${item}.yml from example template"
    fi
  done
}

# --- Infrastructure Reality Check ---
# Distrust local checkpoint file if cloud infrastructure was destroyed out-of-band
check_pipeline_state_reality() {
  if ! is_step_done "tofu_apply"; then
    return 0
  fi

  say_step "Validating pipeline checkpoint against actual infrastructure state"

  local rg="rg-crdbvpnbench-dev"
  if [[ -f "${TF_DIR}/terraform.tfvars" ]]; then
    local tfvars_rg
    tfvars_rg=$(grep -E '^[[:space:]]*resource_group_name[[:space:]]*=' "${TF_DIR}/terraform.tfvars" | sed -E 's/.*=[[:space:]]*"([^"]+)".*/\1/' || true)
    if [[ -n "${tfvars_rg}" ]]; then
      rg="${tfvars_rg}"
    fi
  fi

  say_info "Verifying VM resources exist in Azure resource group '${rg}'..."

  local group_exists="false"
  group_exists=$(az group exists -n "${rg}" 2>/dev/null | tr -d '[:space:]' || true)

  local vm_count=0
  if [[ "${group_exists}" == "true" ]]; then
    vm_count=$(az vm list -g "${rg}" --query "length(@)" -o tsv 2>/dev/null || echo "0")
  fi

  if [[ "${group_exists}" != "true" || "${vm_count}" -eq 0 ]]; then
    die "Stale checkpoint detected: '${STATE_FILE}' claims tofu_apply is done, but no active VMs exist in '${rg}'. Re-run with --reset."
  fi

  say_success "Infrastructure reality check passed (${vm_count} VM(s) active in '${rg}')."
}

# --- Inventory Management ---
export_inventory() {
  say_step "Exporting Ansible inventory from OpenTofu"

  tofu -chdir="${TF_DIR}" output -raw ansible_inventory > "${INVENTORY}"
  
  if [[ ! -s "${INVENTORY}" ]]; then
    die "Failed to export inventory from OpenTofu or inventory file is empty."
  fi

  # Mirror inventory to playbook/inventory.yml for playbooks referencing local inventory
  mkdir -p "${PLAYBOOK_DIR}"
  cp -f "${INVENTORY}" "${PLAYBOOK_DIR}/inventory.yml"

  local line_count
  line_count=$(wc -l < "${INVENTORY}")
  say_success "Generated inventory at ${INVENTORY} (${line_count} lines)"
}

# --- Workload Driver Connection Details ---
get_driver_details() {
  python3 - <<EOF
import yaml, os, sys

inventory_path = "${INVENTORY}"
if not os.path.isfile(inventory_path):
    sys.exit(1)

with open(inventory_path) as f:
    inv = yaml.safe_load(f) or {}

hosts = inv.get('all', {}).get('children', {}).get('workload_driver', {}).get('hosts', {})
if not hosts:
    hosts = inv.get('all', {}).get('children', {}).get('driver', {}).get('hosts', {})

if not hosts:
    sys.exit(1)

name = list(hosts.keys())[0]
info = hosts[name] or {}

host = info.get('ansible_host') or info.get('public_ip') or info.get('fqdn')
user = info.get('ansible_user') or inv.get('all', {}).get('children', {}).get('workload_driver', {}).get('vars', {}).get('ansible_user', 'evan')
key = info.get('ansible_ssh_private_key_file') or inv.get('all', {}).get('children', {}).get('workload_driver', {}).get('vars', {}).get('ansible_ssh_private_key_file', '~/.ssh/id_ed25519')
key = os.path.expanduser(key)

print(f"{host}\t{user}\t{key}")
EOF
}

# --- Benchmark Results Collection ---
save_and_transfer_benchmark() {
  local scenario="$1"
  local iteration="$2"
  local dest_dir="${WORKLOAD_RESULTS_DIR}/${scenario}/${iteration}"

  say_step "Saving and transferring benchmark results -> ${dest_dir}"
  mkdir -p "${dest_dir}"

  local driver_info
  driver_info=$(get_driver_details || true)

  if [[ -z "${driver_info}" ]]; then
    say_warn "Could not resolve driver connection details from inventory. Attempting local artifacts copy only."
  else
    IFS=$'\t' read -r driver_host driver_user driver_key <<< "${driver_info}"
    say_info "Transferring results from driver VM (${driver_host}) via scp..."
    
    # Copy all remote files from driver VM
    scp -i "${driver_key}" -o StrictHostKeyChecking=no -o BatchMode=yes -r \
      "${driver_user}@${driver_host}:/home/${driver_user}/workload-results/*" "${dest_dir}/" 2>/dev/null || true

    # Archive previous run logs/histograms on driver VM so next iteration creates cleanly identified files
    ssh -i "${driver_key}" -o StrictHostKeyChecking=no -o BatchMode=yes "${driver_user}@${driver_host}" \
      "mkdir -p /home/${driver_user}/workload-results/archive && mv /home/${driver_user}/workload-results/tpcc-* /home/${driver_user}/workload-results/benchmark-raw-* /home/${driver_user}/workload-results/archive/ 2>/dev/null || true" 2>/dev/null || true
  fi

  # Copy any controller-side benchmark CSVs fetched by Ansible
  if ls "${PLAYBOOK_DIR}/tmp"/benchmark*.csv >/dev/null 2>&1; then
    cp -f "${PLAYBOOK_DIR}/tmp"/benchmark*.csv "${dest_dir}/" 2>/dev/null || true
  fi

  # Update scenario-level summary CSV if available
  if [[ -f "${dest_dir}/benchmark.csv" ]]; then
    mkdir -p "${WORKLOAD_RESULTS_DIR}/${scenario}"
    cp -f "${dest_dir}/benchmark.csv" "${WORKLOAD_RESULTS_DIR}/${scenario}/benchmark.csv" 2>/dev/null || true
  fi

  say_success "Benchmark results successfully saved to ${dest_dir}"
}

## --- Cluster Baseline Reset via Ansible (In-Place Reset) ---
reset_cluster_baseline() {
  local target_scenario="${1:-next scenario}"
  say_step "Resetting all cluster and driver nodes to clean baseline (before ${target_scenario})"

  # Ensure inventory exists
  if [[ ! -s "${INVENTORY}" ]]; then
    export_inventory
  fi

  # Purge local controller temp staging directories
  say_info "Purging local controller staging certificates and temp files..."
  rm -rf "${PLAYBOOK_DIR}/setup-cockroachdb/tmp"
  rm -rf "${PLAYBOOK_DIR}/setup-wireguard/tmp"
  rm -rf "${PLAYBOOK_DIR}/setup-wireguard-go/tmp"
  rm -rf "${PLAYBOOK_DIR}/setup-workload-driver/tmp"
  rm -rf "${PLAYBOOK_DIR}/tmp"
  mkdir -p "${PLAYBOOK_DIR}/tmp"

  # Run the in-place reset playbook across all nodes
  say_info "Executing in-place teardown playbook (reset-baseline.yml)..."
  ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/reset-baseline.yml"

  # Quick connectivity verification
  say_info "Verifying SSH connectivity across all nodes..."
  if ! ansible -i "${INVENTORY}" all -m ping -o >/dev/null 2>&1; then
    die "Failed to reach all hosts via SSH after baseline reset."
  fi

  say_success "Baseline reset complete. All nodes are clean and ready."
}

# --- Pipeline Execution ---
main() {
  # Handle reset flag to start over from scratch
  if [[ "${1:-}" == "--reset" || "${1:-}" == "--fresh" || "${RESET:-0}" == "1" ]]; then
    say_warn "Reset flag detected. Clearing previous pipeline state..."
    clear_state
  elif [[ -f "${STATE_FILE}" ]]; then
    local completed_count
    completed_count=$(wc -l < "${STATE_FILE}" | tr -d ' ')
    say_info "Found existing pipeline state with ${completed_count} completed checkpoints."
    say_info "Resuming pipeline from the last incomplete step (pass --reset to start over)."
  fi

  check_prerequisites
  check_pipeline_state_reality

  # ----------------------------------------------------------------------------
  # Step 1: Initialize OpenTofu
  # ----------------------------------------------------------------------------
  if is_step_done "tofu_init"; then
    say_info "Step 1: OpenTofu init already completed. Skipping."
  else
    say_step "Step 1: Initializing OpenTofu in infra/azure"
    tofu -chdir="${TF_DIR}" init
    mark_step_done "tofu_init"
  fi

  # ----------------------------------------------------------------------------
  # Step 2: Apply Infrastructure and Generate Inventory
  # ----------------------------------------------------------------------------
  if is_step_done "tofu_apply"; then
    say_info "Step 2: Infrastructure apply already completed. Skipping."
    # Ensure inventory file exists and is populated even when skipping apply
    if [[ ! -s "${INVENTORY}" ]]; then
      export_inventory
    fi
  else
    say_step "Step 2: Applying OpenTofu infrastructure in infra/azure"
    tofu -chdir="${TF_DIR}" apply -auto-approve
    export_inventory
    mark_step_done "tofu_apply"
  fi

  # ----------------------------------------------------------------------------
  # Step 3: Direct Scenario
  # ----------------------------------------------------------------------------
  say_step "=== SCENARIO 1: DIRECT REPLICATION ==="
  
  if is_step_done "direct_crdb_bootstrap"; then
    say_info "CockroachDB cluster bootstrap (direct mode) already completed. Skipping."
  else
    say_info "Bootstrapping CockroachDB cluster (direct mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/create-cluster.yml" \
      -e crdb_advertise_mode=direct
    mark_step_done "direct_crdb_bootstrap"
  fi

  if is_step_done "direct_crdb_join"; then
    say_info "CockroachDB cluster join (direct mode) already completed. Skipping."
  else
    say_info "Joining CockroachDB nodes to cluster (direct mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/join-cluster.yml" \
      -e crdb_advertise_mode=direct
    mark_step_done "direct_crdb_join"
  fi

  if is_step_done "direct_workload_setup"; then
    say_info "Workload driver setup (direct mode) already completed. Skipping."
  else
    say_info "Setting up workload driver..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/setup.yml"
    mark_step_done "direct_workload_setup"
  fi

  for iter in $(seq 1 "${NUM_ITERATIONS}"); do
    if is_step_done "direct_benchmark_iter_${iter}"; then
      say_info "Scenario 1 (Direct) — Benchmark Iteration ${iter}/${NUM_ITERATIONS} already completed. Skipping."
    else
      say_step "Scenario 1 (Direct) — Benchmark Iteration ${iter}/${NUM_ITERATIONS}"
      say_info "Resetting TPC-C data before this iteration..."
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/reset-data.yml"
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/benchmark.yml"
      save_and_transfer_benchmark "direct" "${iter}"
      mark_step_done "direct_benchmark_iter_${iter}"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 4: Reset Nodes to Clean Baseline before Scenario 2
  # ----------------------------------------------------------------------------
  if is_step_done "reset_before_wireguard"; then
    say_info "Baseline reset before WireGuard scenario already completed. Skipping."
  else
    reset_cluster_baseline "Scenario 2 (WireGuard)"
    mark_step_done "reset_before_wireguard"
  fi

  # ----------------------------------------------------------------------------
  # Step 5: WireGuard Scenario
  # ----------------------------------------------------------------------------
  say_step "=== SCENARIO 2: WIREGUARD REPLICATION ==="

  if is_step_done "wireguard_server"; then
    say_info "WireGuard server setup already completed. Skipping."
  else
    say_info "Setting up WireGuard server..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-wireguard/server.yml"
    mark_step_done "wireguard_server"
  fi

  if is_step_done "wireguard_peer"; then
    say_info "WireGuard peer join already completed. Skipping."
  else
    say_info "Setting up WireGuard peers..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-wireguard/join-peer.yml"
    mark_step_done "wireguard_peer"
  fi

  if is_step_done "wireguard_crdb_bootstrap"; then
    say_info "CockroachDB cluster bootstrap (wireguard mode) already completed. Skipping."
  else
    say_info "Bootstrapping CockroachDB cluster (wireguard mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/create-cluster.yml" \
      -e crdb_advertise_mode=wireguard
    mark_step_done "wireguard_crdb_bootstrap"
  fi

  if is_step_done "wireguard_crdb_join"; then
    say_info "CockroachDB cluster join (wireguard mode) already completed. Skipping."
  else
    say_info "Joining CockroachDB nodes to cluster (wireguard mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/join-cluster.yml" \
      -e crdb_advertise_mode=wireguard
    mark_step_done "wireguard_crdb_join"
  fi

  if is_step_done "wireguard_workload_setup"; then
    say_info "Workload driver setup (wireguard mode) already completed. Skipping."
  else
    say_info "Setting up workload driver..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/setup.yml"
    mark_step_done "wireguard_workload_setup"
  fi

  for iter in $(seq 1 "${NUM_ITERATIONS}"); do
    if is_step_done "wireguard_benchmark_iter_${iter}"; then
      say_info "Scenario 2 (WireGuard) — Benchmark Iteration ${iter}/${NUM_ITERATIONS} already completed. Skipping."
    else
      say_step "Scenario 2 (WireGuard) — Benchmark Iteration ${iter}/${NUM_ITERATIONS}"
      say_info "Resetting TPC-C data before this iteration..."
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/reset-data.yml"
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/benchmark.yml"
      save_and_transfer_benchmark "wireguard" "${iter}"
      mark_step_done "wireguard_benchmark_iter_${iter}"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 6: Reset Nodes to Clean Baseline before Scenario 3
  # ----------------------------------------------------------------------------
  if is_step_done "reset_before_wireguard_go"; then
    say_info "Baseline reset before WireGuard-Go scenario already completed. Skipping."
  else
    reset_cluster_baseline "Scenario 3 (WireGuard-Go)"
    mark_step_done "reset_before_wireguard_go"
  fi

  # ----------------------------------------------------------------------------
  # Step 7: WireGuard-Go Scenario
  # ----------------------------------------------------------------------------
  say_step "=== SCENARIO 3: WIREGUARD-GO REPLICATION ==="

  if is_step_done "wireguard_go_server"; then
    say_info "WireGuard-Go server setup already completed. Skipping."
  else
    say_info "Setting up WireGuard-Go server..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-wireguard-go/server.yml"
    mark_step_done "wireguard_go_server"
  fi

  if is_step_done "wireguard_go_peer"; then
    say_info "WireGuard-Go peer join already completed. Skipping."
  else
    say_info "Setting up WireGuard-Go peers..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-wireguard-go/join-peer.yml"
    mark_step_done "wireguard_go_peer"
  fi

  if is_step_done "wireguard_go_crdb_bootstrap"; then
    say_info "CockroachDB cluster bootstrap (wireguard-go mode) already completed. Skipping."
  else
    say_info "Bootstrapping CockroachDB cluster (wireguard mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/create-cluster.yml" \
      -e crdb_advertise_mode=wireguard
    mark_step_done "wireguard_go_crdb_bootstrap"
  fi

  if is_step_done "wireguard_go_crdb_join"; then
    say_info "CockroachDB cluster join (wireguard-go mode) already completed. Skipping."
  else
    say_info "Joining CockroachDB nodes to cluster (wireguard mode)..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-cockroachdb/join-cluster.yml" \
      -e crdb_advertise_mode=wireguard
    mark_step_done "wireguard_go_crdb_join"
  fi

  if is_step_done "wireguard_go_workload_setup"; then
    say_info "Workload driver setup (wireguard-go mode) already completed. Skipping."
  else
    say_info "Setting up workload driver..."
    ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/setup.yml"
    mark_step_done "wireguard_go_workload_setup"
  fi

  for iter in $(seq 1 "${NUM_ITERATIONS}"); do
    if is_step_done "wireguard_go_benchmark_iter_${iter}"; then
      say_info "Scenario 3 (WireGuard-Go) — Benchmark Iteration ${iter}/${NUM_ITERATIONS} already completed. Skipping."
    else
      say_step "Scenario 3 (WireGuard-Go) — Benchmark Iteration ${iter}/${NUM_ITERATIONS}"
      say_info "Resetting TPC-C data before this iteration..."
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/reset-data.yml"
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/benchmark.yml"
      save_and_transfer_benchmark "wireguard-go" "${iter}"
      mark_step_done "wireguard_go_benchmark_iter_${iter}"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 8: Destroy Infrastructure
  # ----------------------------------------------------------------------------
  if is_step_done "tofu_destroy"; then
    say_info "OpenTofu destroy already completed. Skipping."
  else
    say_step "Destroying OpenTofu infrastructure in infra/azure"
    tofu -chdir="${TF_DIR}" destroy -auto-approve
    mark_step_done "tofu_destroy"
  fi

  # Clear state file upon successful complete run
  clear_state

  say_step "Pipeline completed successfully!"
  say_success "All benchmarks completed and infrastructure destroyed."
}

main "$@"
