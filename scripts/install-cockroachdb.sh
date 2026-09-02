#!/usr/bin/env bash
# ==============================================================================
# CockroachDB Interactive Installer & Cluster Manager
# Supports:
#   - Development (Insecure) and Production (TLS / Secure) modes
#   - Bootstrapping a New Cluster or Joining an Existing Cluster
#   - Automatic creation of dedicated system user & group (cockroach:cockroach)
#   - TLS Certificate generation and verification
#   - Systemd service configuration and management
#   - Binary download & installation
# ==============================================================================

set -euo pipefail

# --- Color Formatting ---
if [[ -t 1 ]]; then
  BOLD='\033[1m'
  DIM='\033[2m'
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  MAGENTA='\033[0;35m'
  CYAN='\033[0;36m'
  NC='\033[0m' # No Color
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

# --- Default Constants ---
DEFAULT_DOWNLOAD_URL="http://192.168.129.2/downloads/cockroach-v26.2.5.linux-amd64.tgz"
DEFAULT_BIN_PATH="/usr/local/bin/cockroach"
DEFAULT_SERVICE_USER="cockroach"
DEFAULT_SERVICE_GROUP="cockroach"
DEFAULT_BASE_DIR="/var/lib/cockroach"
DEFAULT_DATA_DIR="/var/lib/cockroach/data"
DEFAULT_CERTS_DIR="/var/lib/cockroach/certs"
DEFAULT_CA_DIR="/var/lib/cockroach/ca"
DEFAULT_SQL_PORT="26257"
DEFAULT_HTTP_PORT="8080"
SERVICE_NAME="cockroachdb"

# --- Output Helpers ---
say_banner() {
  cat <<'BANNER'
  ____           _                         _     ____  ____  
 / ___|___   ___| | ___ __ ___   __ _  ___| |__ |  _ \| __ ) 
| |   / _ \ / __| |/ / '__/ _ \ / _` |/ __| '_ \| | | |  _ \ 
| |__| (_) | (__|   <| | | (_) | (_| | (__| | | | |_| | |_) |
 \____\___/ \___|_|\_\_|  \___/ \__,_|\___|_| |_|____/|____/ 
BANNER
  printf "${CYAN}%s${NC}\n\n" "    Interactive Installer & Cluster Configuration Tool"
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
  printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

say_error() {
  printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

die() {
  say_error "$*"
  exit 1
}

# --- Privilege & System Checks ---
check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    if command -v sudo >/dev/null 2>&1; then
      SUDO="sudo"
    else
      die "This installer requires superuser privileges. Please install sudo or run as root."
    fi
  else
    SUDO=""
  fi
}

check_dependencies() {
  local missing=()
  for cmd in tar grep awk sed; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      missing+=("$cmd")
    fi
  done

  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    missing+=("curl or wget")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    die "Missing required system utilities: ${missing[*]}"
  fi
}

detect_primary_ip() {
  local detected=""
  if command -v hostname >/dev/null 2>&1; then
    detected="$(hostname -I 2>/dev/null | awk '{print $1}')"
  fi
  if [[ -z "$detected" ]] && command -v ip >/dev/null 2>&1; then
    detected="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7}')"
  fi
  printf '%s' "${detected:-127.0.0.1}"
}

# --- Prompt Helpers ---
ask() {
  local prompt="$1" default="$2" answer
  read -r -p "$(printf "${BOLD}%s${NC} [${CYAN}%s${NC}]: " "$prompt" "$default")" answer
  printf '%s' "${answer:-$default}"
}

ask_required() {
  local prompt="$1" answer=""
  while [[ -z "$answer" ]]; do
    read -r -p "$(printf "${BOLD}%s${NC}: " "$prompt")" answer
    if [[ -z "$answer" ]]; then
      say_warn "This field is required. Please provide a value."
    fi
  done
  printf '%s' "$answer"
}

confirm() {
  local prompt="$1" default="${2:-Y}" answer
  local prompt_display="[Y/n]"
  if [[ "$default" =~ ^[Nn]$ ]]; then
    prompt_display="[y/N]"
  fi
  read -r -p "$(printf "${BOLD}%s${NC} ${CYAN}%s${NC}: " "$prompt" "$prompt_display")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

# --- User and Group Management ---
create_user_and_group() {
  local user="$1"
  local group="$2"
  local home_dir="$3"

  say_step "Setting up system user and group ($user:$group)"

  # Create group if not existing
  if ! getent group "$group" >/dev/null 2>&1; then
    say_info "Creating system group: $group"
    $SUDO groupadd --system "$group"
  else
    say_info "System group '$group' already exists."
  fi

  # Create user if not existing
  if ! getent passwd "$user" >/dev/null 2>&1; then
    say_info "Creating system user: $user"
    $SUDO useradd --system       --gid "$group"       --home-dir "$home_dir"       --no-create-home       --shell /usr/sbin/nologin       --comment "CockroachDB Service Account"       "$user"
  else
    say_info "System user '$user' already exists."
    $SUDO usermod -g "$group" "$user" 2>/dev/null || true
  fi
}

# --- Directory & Permission Setup ---
setup_directories() {
  local data_dir="$1"
  local certs_dir="$2"
  local ca_dir="$3"
  local user="$4"
  local group="$5"
  local security_mode="$6"
  local is_ca_node="$7"

  say_step "Creating directory structure and applying permissions"

  say_info "Configuring data directory: $data_dir"
  $SUDO mkdir -p "$data_dir"
  $SUDO chown -R "$user:$group" "$data_dir"
  $SUDO chmod 0750 "$data_dir"

  if [[ "$security_mode" == "prod" ]]; then
    say_info "Configuring certificates directory: $certs_dir"
    $SUDO mkdir -p "$certs_dir"
    $SUDO chown -R "$user:$group" "$certs_dir"
    $SUDO chmod 0700 "$certs_dir"

    if [[ "$is_ca_node" == "yes" ]]; then
      say_info "Configuring CA secure directory: $ca_dir"
      $SUDO mkdir -p "$ca_dir"
      $SUDO chown -R root:root "$ca_dir"
      $SUDO chmod 0700 "$ca_dir"
    fi
  fi
}

# --- Binary Download and Install ---
download_and_install_binary() {
  local download_url="$1"
  local target_bin="$2"
  local temp_dir

  if [[ -x "$target_bin" ]]; then
    say_info "CockroachDB binary already exists at: $target_bin"
    local existing_ver
    existing_ver="$("$target_bin" version 2>/dev/null | head -n 1 || echo "unknown")"
    say_info "Existing version: $existing_ver"
    if ! confirm "Do you want to re-download and overwrite the binary?" "N"; then
      return 0
    fi
  fi

  say_step "Downloading CockroachDB binary archive"
  say_info "URL: $download_url"

  temp_dir="$(mktemp -d /tmp/cockroach-install-XXXXXX)"
  trap 'rm -rf "'"$temp_dir"'"' EXIT

  local archive="$temp_dir/cockroach.tgz"

  if command -v curl >/dev/null 2>&1; then
    curl --fail --location --retry 3 --progress-bar --output "$archive" "$download_url" || die "Failed to download CockroachDB archive from $download_url"
  elif command -v wget >/dev/null 2>&1; then
    wget --progress=bar:force --tries=3 --output-document="$archive" "$download_url" || die "Failed to download CockroachDB archive from $download_url"
  fi

  say_step "Extracting and installing binary to $target_bin"
  $SUDO mkdir -p "$(dirname "$target_bin")"
  tar -xzf "$archive" -C "$temp_dir"

  # Find the extracted cockroach binary
  local extracted_bin
  extracted_bin="$(find "$temp_dir" -type f -name "cockroach" -perm -111 2>/dev/null | head -n 1)"
  if [[ -z "$extracted_bin" ]]; then
    extracted_bin="$(find "$temp_dir" -type f -name "cockroach" 2>/dev/null | head -n 1)"
  fi

  [[ -n "$extracted_bin" && -f "$extracted_bin" ]] || die "CockroachDB binary not found inside downloaded archive."

  $SUDO install -o root -g root -m 0755 "$extracted_bin" "$target_bin"

  # Also copy lib directory if present (e.g. GEOS libraries for spatial data)
  local lib_dir
  lib_dir="$(find "$temp_dir" -type d -name "lib" 2>/dev/null | head -n 1)"
  if [[ -n "$lib_dir" && -d "$lib_dir" ]]; then
    say_info "Installing spatial/GEOS shared libraries to /usr/local/lib/cockroach"
    $SUDO mkdir -p /usr/local/lib/cockroach
    $SUDO cp -r "$lib_dir"/* /usr/local/lib/cockroach/ 2>/dev/null || true
    $SUDO ldconfig 2>/dev/null || true
  fi

  say_success "CockroachDB installed successfully: $("$target_bin" version | head -n 1)"
}

# --- TLS Certificate Management (Production Mode) ---
generate_ca_and_bootstrap_certs() {
  local binary="$1"
  local certs_dir="$2"
  local ca_dir="$3"
  local advertise_host="$4"
  local user="$5"
  local group="$6"

  say_step "Generating Production TLS Certificates"

  local ca_key="$ca_dir/ca.key"
  local ca_crt="$certs_dir/ca.crt"

  # CRITICAL: Always ensure folders exist before generating CA or certificates
  say_info "Preparing CA and certificate folders..."
  $SUDO mkdir -p "$certs_dir"
  $SUDO mkdir -p "$ca_dir"
  $SUDO chmod 0700 "$certs_dir" "$ca_dir"

  # Step 1: CA generation
  if [[ -f "$ca_crt" && -f "$ca_key" ]]; then
    say_info "Existing CA certificate and key found. Reusing existing CA."
  elif [[ -f "$ca_dir/ca.crt" && -f "$ca_key" ]]; then
    say_info "Found existing CA in $ca_dir. Copying ca.crt to $certs_dir..."
    $SUDO cp "$ca_dir/ca.crt" "$certs_dir/ca.crt"
  else
    say_info "Creating Certificate Authority (CA)..."
    $SUDO "$binary" cert create-ca       --certs-dir="$certs_dir"       --ca-key="$ca_key"       --overwrite
    say_success "CA certificate created: $ca_crt"
    say_success "CA private key created: $ca_key"

    # Also keep a copy of ca.crt in ca_dir if different
    if [[ "$ca_dir" != "$certs_dir" ]]; then
      $SUDO cp "$certs_dir/ca.crt" "$ca_dir/ca.crt" 2>/dev/null || true
    fi
  fi

  # Step 2: Node certificate generation
  local hostname_val
  hostname_val="$(hostname)"

  say_info "Creating Node certificate with SANs: $advertise_host, $hostname_val, localhost, 127.0.0.1"
  $SUDO "$binary" cert create-node     "$advertise_host"     "$hostname_val"     localhost     127.0.0.1     --certs-dir="$certs_dir"     --ca-key="$ca_key"     --overwrite
  say_success "Node certificate and key created."

  # Step 3: Client root certificate generation (for administration)
  say_info "Creating Client root certificate (for SQL administration)..."
  $SUDO "$binary" cert create-client     root     --certs-dir="$certs_dir"     --ca-key="$ca_key"     --overwrite
  say_success "Client root certificate and key created."

  # Set appropriate ownership and secure permissions
  say_info "Securing certificate file permissions..."
  $SUDO chown -R "$user:$group" "$certs_dir"
  $SUDO chmod 0700 "$certs_dir"
  $SUDO chmod 0644 "$certs_dir"/*.crt
  $SUDO chmod 0600 "$certs_dir"/*.key

  # Keep CA key locked down
  $SUDO chmod 0600 "$ca_key"
  $SUDO chown root:root "$ca_key"
}

verify_joining_certificates() {
  local certs_dir="$1"
  local user="$2"
  local group="$3"

  say_step "Verifying TLS Certificates for Joining Node"

  local missing=()
  for file in ca.crt node.crt node.key; do
    if [[ ! -f "$certs_dir/$file" ]]; then
      missing+=("$certs_dir/$file")
    fi
  done

  if [[ ${#missing[@]} -gt 0 ]]; then
    say_error "Missing required TLS certificate files in $certs_dir:"
    for m in "${missing[@]}"; do
      printf "  - %s\n" "$m"
    done
    cat <<EOF

${YELLOW}To prepare certificates for this joining node:${NC}
1. On the node running the Certificate Authority (CA), issue certificates for this node:
   Run this script and choose Option 3 (CA Utility: Issue Certificates).
2. Transfer the resulting ca.crt, node.crt, and node.key to:
   ${BOLD}$certs_dir/${NC}
3. Then re-run this installer.

EOF
    die "Cannot proceed without required TLS certificates in Production mode."
  fi

  say_info "Certificates found. Applying secure ownership and permissions..."
  $SUDO chown -R "$user:$group" "$certs_dir"
  $SUDO chmod 0700 "$certs_dir"
  $SUDO chmod 0644 "$certs_dir"/ca.crt "$certs_dir"/node.crt
  $SUDO chmod 0600 "$certs_dir"/node.key
  if [[ -f "$certs_dir/client.root.key" ]]; then
    $SUDO chmod 0600 "$certs_dir/client.root.key"
  fi
  say_success "TLS certificates verified and secured."
}

issue_joining_node_cert_tool() {
  local binary="$1"
  say_step "Certificate Authority Tool: Issue Node Certificates"

  cat <<EOF
This utility generates a TLS certificate bundle for a NEW joining node
using your existing CockroachDB Certificate Authority (CA).

EOF

  local ca_dir certs_dir joining_host additional_sans output_dir
  ca_dir="$(ask 'Path to CA directory containing ca.key' "$DEFAULT_CA_DIR")"
  certs_dir="$(ask 'Path to directory containing ca.crt' "$DEFAULT_CERTS_DIR")"
  
  local ca_key="$ca_dir/ca.key"
  local ca_crt="$certs_dir/ca.crt"

  # Smart search for existing CA files
  if [[ ! -f "$ca_key" && -f "$certs_dir/ca.key" ]]; then
    ca_key="$certs_dir/ca.key"
  fi
  if [[ ! -f "$ca_crt" && -f "$ca_dir/ca.crt" ]]; then
    ca_crt="$ca_dir/ca.crt"
  fi

  [[ -f "$ca_key" ]] || die "CA private key not found at: $ca_key (ensure you are running this on the CA host)"
  [[ -f "$ca_crt" ]] || die "CA certificate not found at: $ca_crt (ensure you are running this on the CA host)"

  say_info "Using CA certificate: $ca_crt"
  say_info "Using CA private key:  $ca_key"

  joining_host="$(ask_required 'Joining Node IP address or primary DNS name')"
  additional_sans="$(ask 'Additional Hostnames/SANs (space-separated, e.g. db2.local db-node-2)' '')"
  output_dir="$(ask 'Output bundle directory' "$PWD/issued-certs/$joining_host")"

  # Step 1: Create the folder BEFORE generating any certs
  say_info "Creating destination folder: $output_dir"
  $SUDO mkdir -p "$output_dir"
  $SUDO chmod 0700 "$output_dir"

  # Step 2: Copy CA certificate into output directory first (required by CockroachDB cert create-node)
  say_info "Copying CA certificate into bundle directory..."
  $SUDO cp "$ca_crt" "$output_dir/ca.crt"

  # Step 3: Generate node certificates
  say_info "Generating node certificate bundle in: $output_dir"
  local san_args=("$joining_host" localhost 127.0.0.1)
  if [[ -n "$additional_sans" ]]; then
    read -r -a extra_arr <<< "$additional_sans"
    san_args+=("${extra_arr[@]}")
  fi

  $SUDO "$binary" cert create-node     "${san_args[@]}"     --certs-dir="$output_dir"     --ca-key="$ca_key"     --overwrite

  # Step 4: Optional client root cert
  if confirm "Also generate a client root certificate in this bundle for SQL administration?" "Y"; then
    $SUDO "$binary" cert create-client root       --certs-dir="$output_dir"       --ca-key="$ca_key"       --overwrite
  fi

  $SUDO chmod 0644 "$output_dir"/*.crt
  $SUDO chmod 0600 "$output_dir"/*.key

  local real_user="${SUDO_USER:-$USER}"
  local real_group="$(id -gn "$real_user" 2>/dev/null || echo "$real_user")"
  $SUDO chown -R "$real_user:$real_group" "$output_dir" 2>/dev/null || true

  say_success "Certificates generated successfully in: $output_dir"
  cat <<EOF

${BOLD}${GREEN}=== Transfer Instructions ===${NC}
Copy the generated certificates to the joining node's certs directory:

  ${CYAN}scp $output_dir/* <user>@${joining_host}:${DEFAULT_CERTS_DIR}/${NC}

${YELLOW}IMPORTANT Security Note:${NC}
Never copy ${BOLD}ca.key${NC} to database nodes! Keep ca.key strictly on the CA host.
EOF
}

# --- Systemd Service Management ---
install_systemd_service() {
  local binary="$1"
  local store_dir="$2"
  local advertise_addr="$3"
  local http_addr="$4"
  local join_addr="$5"
  local security_mode="$6"
  local certs_dir="$7"
  local user="$8"
  local group="$9"

  say_step "Installing and Configuring Systemd Service"

  if ! command -v systemctl >/dev/null 2>&1; then
    die "systemd (systemctl) is not available on this system."
  fi

  local security_arg
  if [[ "$security_mode" == "prod" ]]; then
    security_arg="--certs-dir=${certs_dir}"
  else
    security_arg="--insecure"
  fi

  local unit_file="/etc/systemd/system/${SERVICE_NAME}.service"
  local tmp_unit="/tmp/${SERVICE_NAME}.service.$$"

  cat >"$tmp_unit" <<EOF
[Unit]
Description=CockroachDB Distributed SQL Database
Documentation=https://www.cockroachlabs.com/docs/
After=network.target network-online.target local-fs.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=notify
User=${user}
Group=${group}
WorkingDirectory=${store_dir}
ExecStart=${binary} start \
    --store=${store_dir} \
    --listen-addr=0.0.0.0:${DEFAULT_SQL_PORT} \
    --advertise-addr=${advertise_addr} \
    --http-addr=${http_addr} \
    --join=${join_addr} \
    ${security_arg}
ExecStop=${binary} quit ${security_arg} --host=${advertise_addr}
Restart=always
RestartSec=10
TimeoutStopSec=60
LimitNOFILE=35000
LimitNPROC=infinity
TasksMax=infinity
StandardOutput=journal
StandardError=journal
PrivateTmp=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  say_info "Installing unit file to $unit_file"
  $SUDO install -o root -g root -m 0644 "$tmp_unit" "$unit_file"
  rm -f "$tmp_unit"

  say_info "Reloading systemd daemon"
  $SUDO systemctl daemon-reload

  say_info "Enabling and starting $SERVICE_NAME service"
  $SUDO systemctl enable "$SERVICE_NAME"
  $SUDO systemctl restart "$SERVICE_NAME"

  say_success "Systemd service $SERVICE_NAME is now active."
}

# --- Cluster Initialization ---
initialize_cluster() {
  local binary="$1"
  local advertise_addr="$2"
  local security_mode="$3"
  local certs_dir="$4"

  say_step "Initializing the CockroachDB Cluster"

  local sec_args=()
  if [[ "$security_mode" == "prod" ]]; then
    sec_args=(--certs-dir="$certs_dir")
  else
    sec_args=(--insecure)
  fi

  say_info "Waiting for CockroachDB service to respond on $advertise_addr..."
  local attempts=0
  local max_attempts=20
  local ready=0

  while [[ $attempts -lt $max_attempts ]]; do
    if "$binary" init "${sec_args[@]}" --host="$advertise_addr" 2>&1 | grep -q -E "Cluster successfully initialized|cluster has already been initialized"; then
      ready=1
      break
    fi
    sleep 2
    attempts=$((attempts + 1))
  done

  if [[ $ready -eq 1 ]]; then
    say_success "CockroachDB cluster initialization completed!"
  else
    say_warn "Attempting direct cluster init..."
    "$binary" init "${sec_args[@]}" --host="$advertise_addr" || say_warn "Init command finished (check cluster status below)."
  fi
}

show_help() {
  say_banner
  cat <<EOF
Usage: sudo ./install-cockroachdb.sh [OPTIONS]

Interactive installer and cluster manager for CockroachDB.

Features:
  - Development (Insecure) and Production (TLS / Secure) modes
  - Bootstrap a New Cluster or Join an Existing Cluster
  - Create dedicated system user & group (default: cockroach:cockroach)
  - Configure data and certificates directories with secure permissions
  - TLS CA and Node certificate generation for Production
  - CA Utility to issue certificates for joining nodes
  - Systemd service installation with production resource limits

Usage:
  sudo ./install-cockroachdb.sh         Run interactive wizard
  ./install-cockroachdb.sh --help       Show this help message

EOF
}

# --- Main Interactive Workflow ---
main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    show_help
    exit 0
  fi

  say_banner
  check_privileges
  check_dependencies

  # Step 1: Environment Selection
  printf "${BOLD}%s${NC}\n" "Step 1: Select Deployment Environment"
  printf "  1) %s (TLS certificates, systemd service, hardened security)\n" "${BOLD}Production${NC}"
  printf "  2) %s (Insecure mode, no TLS, fast setup for testing)\n" "${BOLD}Development${NC}"
  local env_choice
  env_choice="$(ask 'Select environment mode' '1')"
  local security_mode="prod"
  if [[ "$env_choice" == "2" ]]; then
    security_mode="dev"
  fi

  # Step 2: Role Selection
  printf "\n${BOLD}%s${NC}\n" "Step 2: Select Node Role"
  printf "  1) %s (Bootstrap / First node of a cluster)\n" "${BOLD}Create a NEW Cluster${NC}"
  printf "  2) %s (Connect this node to existing cluster)\n" "${BOLD}Join an EXISTING Cluster${NC}"
  printf "  3) %s (Generate TLS node cert bundle for a joining machine)\n" "${BOLD}CA Utility: Issue Certificates${NC}"
  local role_choice
  role_choice="$(ask 'Select node role' '1')"

  # Step 3: Binary and URL Configuration
  printf "\n${BOLD}%s${NC}\n" "Step 3: Binary Download & Installation"
  local download_url bin_path
  download_url="$(ask 'CockroachDB Archive Download URL' "$DEFAULT_DOWNLOAD_URL")"
  bin_path="$(ask 'Binary install location' "$DEFAULT_BIN_PATH")"

  # Install binary first so tools are ready
  download_and_install_binary "$download_url" "$bin_path"

  # Handle Role 3 (Certificate Authority Tool)
  if [[ "$role_choice" == "3" ]]; then
    issue_joining_node_cert_tool "$bin_path"
    exit 0
  fi

  # Step 4: User, Group, and Directories Configuration
  printf "\n${BOLD}%s${NC}\n" "Step 4: System User & Directory Layout"
  local service_user service_group data_dir certs_dir ca_dir
  service_user="$(ask 'Dedicated service user' "$DEFAULT_SERVICE_USER")"
  service_group="$(ask 'Dedicated service group' "$DEFAULT_SERVICE_GROUP")"
  data_dir="$(ask 'Data storage directory (store)' "$DEFAULT_DATA_DIR")"
  
  if [[ "$security_mode" == "prod" ]]; then
    certs_dir="$(ask 'Certificates directory (certs)' "$DEFAULT_CERTS_DIR")"
    ca_dir="$(ask 'CA safe directory (for CA private key)' "$DEFAULT_CA_DIR")"
  else
    certs_dir=""
    ca_dir=""
  fi

  # Step 5: Network Configuration
  printf "\n${BOLD}%s${NC}\n" "Step 5: Network & Cluster Configuration"
  local detected_ip advertise_host sql_port http_port http_bind join_address
  detected_ip="$(detect_primary_ip)"
  advertise_host="$(ask "Reachable IP address or hostname for this node" "$detected_ip")"
  sql_port="$(ask "SQL listen port" "$DEFAULT_SQL_PORT")"
  http_port="$(ask "Admin Web UI HTTP port" "$DEFAULT_HTTP_PORT")"
  http_bind="$(ask "Admin Web UI bind address (0.0.0.0 for remote access)" "0.0.0.0")"

  local advertise_addr="${advertise_host}:${sql_port}"
  local http_addr="${http_bind}:${http_port}"

  if [[ "$role_choice" == "1" ]]; then
    # Bootstrapping: In CockroachDB v26, first node joins itself, then init creates the cluster
    join_address="$advertise_addr"
  else
    # Joining an existing cluster
    join_address="$(ask_required 'Existing cluster node address(es) to join (e.g. 192.168.129.10:26257)')"
  fi

  # Summary & Confirmation
  printf "\n${BOLD}${CYAN}================ Configuration Summary ================${NC}\n"
  printf "  ${BOLD}Environment Mode:${NC}    %s\n" "$([[ "$security_mode" == "prod" ]] && echo "Production (TLS Enabled)" || echo "Development (Insecure)")"
  printf "  ${BOLD}Cluster Action:${NC}      %s\n" "$([[ "$role_choice" == "1" ]] && echo "Initialize NEW Cluster" || echo "Join Existing Cluster")"
  printf "  ${BOLD}Binary Path:${NC}         %s\n" "$bin_path"
  printf "  ${BOLD}Service User/Group:${NC}  %s:%s\n" "$service_user" "$service_group"
  printf "  ${BOLD}Data Directory:${NC}      %s\n" "$data_dir"
  if [[ "$security_mode" == "prod" ]]; then
    printf "  ${BOLD}Certs Directory:${NC}     %s\n" "$certs_dir"
  fi
  printf "  ${BOLD}Advertise Address:${NC}   %s\n" "$advertise_addr"
  printf "  ${BOLD}Admin Web UI:${NC}        %s\n" "$http_addr"
  printf "  ${BOLD}Join Target:${NC}         %s\n" "$join_address"
  printf "${BOLD}${CYAN}=======================================================${NC}\n\n"

  if ! confirm "Do you wish to apply this configuration and start CockroachDB?" "Y"; then
    say_warn "Installation canceled by user."
    exit 0
  fi

  # Execute Setup
  create_user_and_group "$service_user" "$service_group" "$(dirname "$data_dir")"
  
  local is_ca="no"
  if [[ "$security_mode" == "prod" && "$role_choice" == "1" ]]; then
    is_ca="yes"
  fi

  setup_directories "$data_dir" "$certs_dir" "$ca_dir" "$service_user" "$service_group" "$security_mode" "$is_ca"

  # Certificate Handling for Production
  if [[ "$security_mode" == "prod" ]]; then
    if [[ "$role_choice" == "1" ]]; then
      generate_ca_and_bootstrap_certs "$bin_path" "$certs_dir" "$ca_dir" "$advertise_host" "$service_user" "$service_group"
    else
      verify_joining_certificates "$certs_dir" "$service_user" "$service_group"
    fi
  fi

  # Systemd Service Installation & Start
  install_systemd_service     "$bin_path"     "$data_dir"     "$advertise_addr"     "$http_addr"     "$join_address"     "$security_mode"     "$certs_dir"     "$service_user"     "$service_group"

  # Initialize cluster if this is the first node
  if [[ "$role_choice" == "1" ]]; then
    initialize_cluster "$bin_path" "$advertise_addr" "$security_mode" "$certs_dir"
  fi

  # Final Information Display
  local ui_proto="http"
  local sql_sec_flag="--insecure"
  if [[ "$security_mode" == "prod" ]]; then
    ui_proto="https"
    sql_sec_flag="--certs-dir=${certs_dir}"
  fi

  printf "\n${BOLD}${GREEN}=======================================================${NC}\n"
  printf "${BOLD}${GREEN}  CockroachDB Node Successfully Installed & Started!  ${NC}\n"
  printf "${BOLD}${GREEN}=======================================================${NC}\n\n"

  printf "${BOLD}Service Status:${NC}    systemctl status %s\n" "$SERVICE_NAME"
  printf "${BOLD}Service Logs:${NC}      journalctl -u %s -f\n" "$SERVICE_NAME"
  printf "${BOLD}Admin Web Console:${NC} %s://%s:%s\n" "$ui_proto" "$advertise_host" "$http_port"
  printf "${BOLD}SQL Shell Access:${NC}  %s sql %s --host=%s\n\n" "$bin_path" "$sql_sec_flag" "$advertise_addr"

  if [[ "$role_choice" == "1" ]]; then
    printf "${BOLD}${CYAN}How to add more nodes to this cluster:${NC}\n"
    if [[ "$security_mode" == "prod" ]]; then
      printf "  1. Run this installer script on this machine with Option 3 (CA Utility) to create certs for each joining node.\n"
      printf "  2. Copy the generated bundle to the joining node's %s\n" "$DEFAULT_CERTS_DIR"
      printf "  3. Run this installer on the joining node, select Production, Option 2 (Join Existing), and enter:\n"
      printf "     ${BOLD}%s${NC}\n\n" "$advertise_addr"
    else
      printf "  1. Run this installer on the joining machine.\n"
      printf "  2. Choose Development mode, Option 2 (Join Existing Cluster).\n"
      printf "  3. Enter this node's address: ${BOLD}%s${NC}\n\n" "$advertise_addr"
    fi
  else
    printf "${BOLD}${CYAN}Cluster Node Status:${NC}\n"
    printf "  Check cluster health from this node:\n"
    printf "  %s node status %s --host=%s\n\n" "$bin_path" "$sql_sec_flag" "$advertise_addr"
  fi
}

main "$@"
