#!/usr/bin/env bash
# ==============================================================================
# scripts/run.sh — Automated End-to-End CockroachDB Replication & Benchmark Runner
#
# Pipeline Workflow:
#   1. OpenTofu init & apply Azure infrastructure
#   2. Export dynamic inventory to ./inventory.yml and playbook/inventory.yml
#   3. Scenario 1: Direct replication
#      - Ansible: setup-cockroachdb (create-cluster & join-cluster in direct mode)
#      - Ansible: setup-workload-driver/setup.yml
#      - 5 iterations: benchmark.yml -> save & transfer to ./workload-result/direct/{iteration}
#   4. Restore OS disk snapshots using Azure CLI (`az`) dynamically from OpenTofu state
#   5. Scenario 2: Kernel WireGuard
#      - Ansible: setup-wireguard (server & join-peer)
#      - Ansible: setup-cockroachdb (create-cluster & join-cluster in wireguard mode)
#      - Ansible: setup-workload-driver/setup.yml
#      - 5 iterations: benchmark.yml -> save & transfer to ./workload-result/wireguard/{iteration}
#   6. Restore OS disk snapshots using Azure CLI (`az`) dynamically from OpenTofu state
#   7. Scenario 3: Userspace WireGuard-Go
#      - Ansible: setup-wireguard-go (server & join-peer)
#      - Ansible: setup-cockroachdb (create-cluster & join-cluster in wireguard mode)
#      - Ansible: setup-workload-driver/setup.yml
#      - 5 iterations: benchmark.yml -> save & transfer to ./workload-result/wireguard-go/{iteration}
#   8. OpenTofu destroy Azure infrastructure
# ==============================================================================

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

say_banner() {
  cat <<'EOF'
================================================================================
   CockroachDB Multi-Region Replication & VPN Benchmark Pipeline Runner
================================================================================
EOF
}

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
    say_error "================================================================================"
    say_error "CHECKPOINT REALITY MISMATCH DETECTED:"
    say_error "  Checkpoint file (${STATE_FILE}) claims 'tofu_apply' is completed,"
    say_error "  but no active Virtual Machines exist in Azure resource group '${rg}'."
    say_error ""
    say_error "  Resources were destroyed out-of-band while the local checkpoint was preserved."
    say_error "  To prevent executing playbooks against non-existent hosts, please re-run with --reset:"
    say_error ""
    say_error "      $0 --reset"
    say_error "================================================================================"
    die "Stale checkpoint detected. Manual confirmation required: re-run with --reset to start fresh."
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
  ls -lh "${dest_dir}" | tail -n +2 | sed 's/^/    /' || true
}

# --- Snapshot Restore via Azure CLI (No hardcoding, reading from OpenTofu state) ---
restore_snapshots_from_tfstate() {
  say_step "Restoring VM OS disk snapshots via Azure CLI (discovered from OpenTofu state)"

  # Dynamically extract all VM name, resource group, location, and snapshot ID pairs from OpenTofu state
  local targets
  targets=$(python3 - <<EOF
import json, sys, os, subprocess

targets = []

# Method 1: Read via 'tofu show -json'
try:
    proc = subprocess.run(
        ["tofu", "-chdir=${TF_DIR}", "show", "-json"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=True
    )
    if proc.stdout.strip():
        data = json.loads(proc.stdout)
        def walk_module(mod):
            resources = mod.get("resources", [])
            vms = [r for r in resources if r.get("type") == "azurerm_linux_virtual_machine"]
            snaps = [r for r in resources if r.get("type") == "azurerm_snapshot"]
            if vms and snaps:
                vm_val = vms[0].get("values", {})
                snap_val = snaps[0].get("values", {})
                targets.append({
                    "vm_name": vm_val.get("name"),
                    "resource_group": vm_val.get("resource_group_name") or snap_val.get("resource_group_name"),
                    "location": vm_val.get("location") or snap_val.get("location"),
                    "snapshot_id": snap_val.get("id")
                })
            for child in mod.get("child_modules", []):
                walk_module(child)

        root = data.get("values", {}).get("root_module", {})
        walk_module(root)
except Exception:
    pass

# Method 2: Fallback to reading terraform.tfstate directly
tfstate_path = os.path.join("${TF_DIR}", "terraform.tfstate")
if not targets and os.path.isfile(tfstate_path):
    try:
        with open(tfstate_path) as f:
            data = json.load(f)
        vms_by_mod = {}
        snaps_by_mod = {}
        vms_by_name = {}
        snaps_by_name = {}
        for r in data.get("resources", []):
            rtype = r.get("type")
            mod = r.get("module", "")
            for inst in r.get("instances", []):
                attrs = inst.get("attributes", {})
                if rtype == "azurerm_linux_virtual_machine":
                    vm_data = {
                        "vm_name": attrs.get("name"),
                        "resource_group": attrs.get("resource_group_name"),
                        "location": attrs.get("location"),
                        "id": attrs.get("id")
                    }
                    vms_by_mod[mod] = vm_data
                    vms_by_name[attrs.get("name")] = vm_data
                elif rtype == "azurerm_snapshot":
                    snap_data = {
                        "snapshot_id": attrs.get("id"),
                        "snapshot_name": attrs.get("name"),
                        "resource_group": attrs.get("resource_group_name"),
                        "location": attrs.get("location")
                    }
                    snaps_by_mod[mod] = snap_data
                    snaps_by_name[attrs.get("name")] = snap_data

        for mod, vm in vms_by_mod.items():
            snap = snaps_by_mod.get(mod) or snaps_by_name.get(f"snap-{vm['vm_name']}")
            if snap and snap.get("snapshot_id"):
                targets.append({
                    "vm_name": vm["vm_name"],
                    "resource_group": vm["resource_group"] or snap["resource_group"],
                    "location": vm["location"] or snap["location"],
                    "snapshot_id": snap["snapshot_id"]
                })
    except Exception:
        pass

for t in targets:
    if t.get("vm_name") and t.get("snapshot_id"):
        print(f"{t['vm_name']}\t{t['resource_group']}\t{t['location']}\t{t['snapshot_id']}")
EOF
)

  if [[ -z "${targets}" ]]; then
    die "Could not find any VM snapshot pairs in OpenTofu state. Ensure infrastructure is provisioned."
  fi

  say_info "Discovered restore targets from OpenTofu state:"
  echo "${targets}" | while IFS=$'\t' read -r vm rg loc snap; do
    say_info "  - VM: ${vm} (RG: ${rg}, Region: ${loc})"
    say_info "    Source Snapshot: ${snap}"
  done

  local ts
  ts=$(date +%s)
  declare -A new_disk_names
  declare -A old_disk_ids

  # Phase 1: Parallel disk creation from snapshot & parallel VM deallocation
  say_info "Initiating parallel disk creation and VM deallocation..."
  while IFS=$'\t' read -r vm rg loc snap; do
    [[ -z "${vm}" ]] && continue
    local disk_name="restored-${vm}-${ts}"
    new_disk_names["${vm}"]="${disk_name}"

    # Query current OS disk ID to clean up after swap
    local old_disk
    old_disk=$(az vm show -g "${rg}" -n "${vm}" --query "storageProfile.osDisk.managedDisk.id" -o tsv 2>/dev/null || true)
    old_disk_ids["${vm}"]="${old_disk}"

    say_info "[${vm}] Creating managed disk '${disk_name}' from snapshot..."
    az disk create \
      --resource-group "${rg}" \
      --name "${disk_name}" \
      --source "${snap}" \
      --location "${loc}" \
      --sku "Premium_LRS" \
      --no-wait &

    say_info "[${vm}] Deallocating VM..."
    az vm deallocate --resource-group "${rg}" --name "${vm}" --no-wait &
  done <<< "${targets}"

  # Wait for all background CLI operations to finish
  wait

  # Phase 2: Await disk readiness and VM deallocation completion
  say_info "Waiting for disks to be created and VMs to reach deallocated state..."
  while IFS=$'\t' read -r vm rg loc snap; do
    [[ -z "${vm}" ]] && continue
    local disk_name="${new_disk_names[${vm}]}"
    
    say_info "[${vm}] Waiting for managed disk '${disk_name}'..."
    az disk wait --resource-group "${rg}" --name "${disk_name}" --created

    say_info "[${vm}] Waiting for VM deallocation..."
    az vm wait --resource-group "${rg}" --name "${vm}" --custom "instanceView.statuses[?code=='PowerState/deallocated']"
  done <<< "${targets}"

  # Phase 3: Swap OS disks to restored managed disk
  say_info "Swapping OS disks for all VMs..."
  while IFS=$'\t' read -r vm rg loc snap; do
    [[ -z "${vm}" ]] && continue
    local disk_name="${new_disk_names[${vm}]}"
    local new_disk_id
    new_disk_id=$(az disk show --resource-group "${rg}" --name "${disk_name}" --query id -o tsv)

    say_info "[${vm}] Swapping OS disk to ${new_disk_id}..."
    az vm update --resource-group "${rg}" --name "${vm}" --os-disk "${new_disk_id}" --only-show-errors

    # Clean up previous detached disk to free storage quota
    local old_id="${old_disk_ids[${vm}]:-}"
    if [[ -n "${old_id}" && "${old_id}" != "${new_disk_id}" ]]; then
      say_info "[${vm}] Cleaning up previous detached disk: ${old_id}"
      az disk delete --ids "${old_id}" --yes --no-wait 2>/dev/null || true
    fi
  done <<< "${targets}"

  # Phase 4: Start all VMs in parallel
  say_info "Starting all VMs in parallel..."
  while IFS=$'\t' read -r vm rg loc snap; do
    [[ -z "${vm}" ]] && continue
    say_info "[${vm}] Powering on..."
    az vm start --resource-group "${rg}" --name "${vm}" --no-wait &
  done <<< "${targets}"

  wait

  # Phase 5: Wait for all VMs to reach PowerState/running
  say_info "Awaiting running power state on all VMs..."
  while IFS=$'\t' read -r vm rg loc snap; do
    [[ -z "${vm}" ]] && continue
    say_info "[${vm}] Waiting for power state 'running'..."
    az vm wait --resource-group "${rg}" --name "${vm}" --custom "instanceView.statuses[?code=='PowerState/running']"
  done <<< "${targets}"

  # Phase 6: Clean up controller-side temporary staging artifacts from previous run
  say_info "Purging local controller staging keys and certificates (playbook/tmp)..."
  rm -rf "${PLAYBOOK_DIR}/tmp"/* 2>/dev/null || true

  # Phase 7: Wait for SSH to be fully ready across all inventory hosts
  say_step "Verifying SSH connectivity on all hosts..."
  local max_attempts=40
  local attempt=1
  local ready=false

  while [[ ${attempt} -le ${max_attempts} ]]; do
    local total_hosts
    total_hosts=$(ansible -i "${INVENTORY}" all --list-hosts 2>/dev/null | tail -n +2 | wc -l)
    local success_hosts
    success_hosts=$(ansible -i "${INVENTORY}" all -m ping -o 2>/dev/null | grep -c "SUCCESS" || true)

    if [[ ${total_hosts} -gt 0 && ${success_hosts} -ge ${total_hosts} ]]; then
      say_success "All ${total_hosts} hosts are online and responding to SSH!"
      ready=true
      break
    fi

    say_info "SSH verification attempt ${attempt}/${max_attempts} (${success_hosts}/${total_hosts} hosts online) — waiting 6s..."
    sleep 6
    attempt=$((attempt + 1))
  done

  if [[ "${ready}" != "true" ]]; then
    die "Timed out waiting for SSH connectivity on all hosts after snapshot restore."
  fi

  say_success "Snapshot restoration complete. All nodes are clean and ready."
}

# ==============================================================================
# Pipeline Execution
# ==============================================================================
main() {
  say_banner

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
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/benchmark.yml"
      save_and_transfer_benchmark "direct" "${iter}"
      mark_step_done "direct_benchmark_iter_${iter}"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 4: Restore Snapshot before Scenario 2
  # ----------------------------------------------------------------------------
  if is_step_done "restore_snapshot_before_wireguard"; then
    say_info "Snapshot restore before WireGuard scenario already completed. Skipping."
  else
    restore_snapshots_from_tfstate
    mark_step_done "restore_snapshot_before_wireguard"
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
      ansible-playbook -i "${INVENTORY}" "${PLAYBOOK_DIR}/setup-workload-driver/benchmark.yml"
      save_and_transfer_benchmark "wireguard" "${iter}"
      mark_step_done "wireguard_benchmark_iter_${iter}"
    fi
  done

  # ----------------------------------------------------------------------------
  # Step 6: Restore Snapshot before Scenario 3
  # ----------------------------------------------------------------------------
  if is_step_done "restore_snapshot_before_wireguard_go"; then
    say_info "Snapshot restore before WireGuard-Go scenario already completed. Skipping."
  else
    restore_snapshots_from_tfstate
    mark_step_done "restore_snapshot_before_wireguard_go"
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
  say_info "Results summary:"
  ls -lh "${WORKLOAD_RESULTS_DIR}" 2>/dev/null || true
}

main "$@"
