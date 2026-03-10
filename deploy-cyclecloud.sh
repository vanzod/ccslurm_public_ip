#!/usr/bin/env bash
# ============================================================================
# deploy-cyclecloud.sh
#
# Deploys Azure CycleCloud 8.x with a Slurm cluster and Azure NetApp Files
# in a dedicated resource group using Azure CLI.
#
# Prerequisites:
#   - Azure CLI >= 2.50
#   - jq
#   - SSH key pair (default: ~/.ssh/id_rsa.pub)
#   - Active Azure login (az login)
#
# Usage:
#   ./deploy-cyclecloud.sh
#   LOCATION=westus2 CC_ADMIN_PASSWORD='P@ssw0rd!' ./deploy-cyclecloud.sh
#
# All configuration variables can be overridden via environment variables.
# ============================================================================
set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────────

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-cyclecloud}"
LOCATION="${LOCATION:-centralus}"

# Networking
VNET_NAME="${VNET_NAME:-vnet-cc}"
VNET_CIDR="${VNET_CIDR:-10.0.0.0/16}"
CC_SUBNET_NAME="${CC_SUBNET_NAME:-snet-cyclecloud}"
CC_SUBNET_CIDR="${CC_SUBNET_CIDR:-10.0.1.0/24}"
COMPUTE_SUBNET_NAME="${COMPUTE_SUBNET_NAME:-snet-compute}"
COMPUTE_SUBNET_CIDR="${COMPUTE_SUBNET_CIDR:-10.0.16.0/20}"
ANF_SUBNET_NAME="${ANF_SUBNET_NAME:-snet-anf}"
ANF_SUBNET_CIDR="${ANF_SUBNET_CIDR:-10.0.3.0/24}"
NSG_NAME="${NSG_NAME:-nsg-cyclecloud}"

# CycleCloud VM
CC_VM_NAME="${CC_VM_NAME:-vm-cyclecloud}"
CC_VM_SIZE="${CC_VM_SIZE:-Standard_D4s_v5}"
CC_IMAGE="${CC_IMAGE:-azurecyclecloud:azure-cyclecloud:cyclecloud8-gen2:latest}"
CC_OS_USER="${CC_OS_USER:-cycleadmin}"

# Managed identity
IDENTITY_NAME="${IDENTITY_NAME:-id-cyclecloud}"

# Storage account
STORAGE_CONTAINER="${STORAGE_CONTAINER:-cyclecloud}"

# Azure NetApp Files
ANF_ACCOUNT_NAME="${ANF_ACCOUNT_NAME:-anf-hpc}"
ANF_POOL_NAME="${ANF_POOL_NAME:-pool-premium}"
ANF_VOLUME_NAME="${ANF_VOLUME_NAME:-vol-shared}"
ANF_SERVICE_LEVEL="${ANF_SERVICE_LEVEL:-Premium}"
ANF_POOL_SIZE_TIB="${ANF_POOL_SIZE_TIB:-12}"
ANF_VOLUME_SIZE_TIB="${ANF_VOLUME_SIZE_TIB:-12}"
ANF_MOUNT_PATH="${ANF_MOUNT_PATH:-/shared}"

# Slurm cluster
SLURM_CLUSTER_NAME="${SLURM_CLUSTER_NAME:-cc-slurm}"
SLURM_TEMPLATE_FILE="${SLURM_TEMPLATE_FILE:-slurm.txt}"
SLURM_PARAMS_FILE="${SLURM_PARAMS_FILE:-params.json}"

# CycleCloud admin credentials
CC_ADMIN_USER="${CC_ADMIN_USER:-cycleadmin}"
CC_ADMIN_PASSWORD="${CC_ADMIN_PASSWORD:-}"

# SSH
SSH_PUB_KEY_PATH="${SSH_PUB_KEY_PATH:-${HOME}/.ssh/id_rsa.pub}"

# ── Helper functions ────────────────────────────────────────────────────────

log()  { printf '\n\033[1;34m>>>\033[0m \033[1m%s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARN: %s\033[0m\n' "$*"; }
err()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

# ── Pre-flight checks ──────────────────────────────────────────────────────

log "Pre-flight checks"

for cmd in az jq curl; do
    command -v "$cmd" &>/dev/null || err "'$cmd' is required but not found in PATH."
done

ACCOUNT_JSON=$(az account show -o json 2>/dev/null) \
    || err "Not logged in to Azure. Run 'az login' first."

SUBSCRIPTION_ID=$(jq -r '.id'       <<< "$ACCOUNT_JSON")
TENANT_ID=$(jq -r '.tenantId'       <<< "$ACCOUNT_JSON")

# Derive a globally unique storage account name (deterministic per RG + subscription)
if [[ -z "${STORAGE_ACCOUNT_NAME:-}" ]]; then
    _SA_HASH=$(echo -n "${RESOURCE_GROUP}-${SUBSCRIPTION_ID}" | md5sum | cut -c1-8)
    _SA_BASE=$(echo "${RESOURCE_GROUP}" | tr -cd 'a-z0-9')
    STORAGE_ACCOUNT_NAME="st${_SA_BASE:0:12}${_SA_HASH}"
fi

info "Subscription : $SUBSCRIPTION_ID"
info "Tenant       : $TENANT_ID"
info "Location     : $LOCATION"

[[ -f "$SSH_PUB_KEY_PATH" ]] || err "SSH public key not found at $SSH_PUB_KEY_PATH"
SSH_PUB_KEY=$(<"$SSH_PUB_KEY_PATH")

if [[ -z "$CC_ADMIN_PASSWORD" ]]; then
    read -rsp "CycleCloud admin password (>=8 chars, mixed case + digit): " CC_ADMIN_PASSWORD
    echo
fi
[[ ${#CC_ADMIN_PASSWORD} -ge 8 ]] || err "Password must be at least 8 characters."

# ── Register resource providers ─────────────────────────────────────────────

log "Registering resource providers"
for P in Microsoft.NetApp Microsoft.Compute Microsoft.Storage \
         Microsoft.Network Microsoft.ManagedIdentity; do
    STATE=$(az provider show -n "$P" --query registrationState -o tsv 2>/dev/null || true)
    if [[ "$STATE" != "Registered" ]]; then
        az provider register -n "$P" --only-show-errors
        info "$P — registration initiated"
    else
        info "$P — registered"
    fi
done

# ════════════════════════════════════════════════════════════════════════════
#  Phase 1 · Foundation
# ════════════════════════════════════════════════════════════════════════════

log "Phase 1 · Resource group"
az group create -n "$RESOURCE_GROUP" -l "$LOCATION" -o none

# ── Virtual network ─────────────────────────────────────────────────────────

log "Phase 1 · Virtual network & subnets"
if ! az network vnet show -g "$RESOURCE_GROUP" -n "$VNET_NAME" &>/dev/null; then
    az network vnet create \
        -g "$RESOURCE_GROUP" -n "$VNET_NAME" \
        --address-prefix "$VNET_CIDR" \
        --subnet-name "$CC_SUBNET_NAME" --subnet-prefix "$CC_SUBNET_CIDR" \
        -o none
else
    info "VNet $VNET_NAME — already exists"
fi

if ! az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
      -n "$COMPUTE_SUBNET_NAME" &>/dev/null; then
    az network vnet subnet create \
        -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        -n "$COMPUTE_SUBNET_NAME" --address-prefix "$COMPUTE_SUBNET_CIDR" \
        -o none
else
    info "Subnet $COMPUTE_SUBNET_NAME — already exists"
fi

if ! az network vnet subnet show -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
      -n "$ANF_SUBNET_NAME" &>/dev/null; then
    az network vnet subnet create \
        -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        -n "$ANF_SUBNET_NAME" --address-prefix "$ANF_SUBNET_CIDR" \
        --delegations "Microsoft.NetApp/volumes" \
        -o none
else
    info "Subnet $ANF_SUBNET_NAME — already exists"
fi

# ── NSG ─────────────────────────────────────────────────────────────────────

log "Phase 1 · Network security group"
az network nsg create -g "$RESOURCE_GROUP" -n "$NSG_NAME" -o none

# Restrict inbound access to deployer's public IP.
# NOTE: For production, replace the public IP with VPN/Bastion access
#       and remove the public IP from the CycleCloud VM entirely.
DEPLOYER_IP=$(curl -sf --max-time 10 https://ifconfig.me 2>/dev/null || echo "")
if [[ -n "$DEPLOYER_IP" ]]; then
    DEPLOYER_IP="${DEPLOYER_IP}/32"
    info "Deployer IP  : $DEPLOYER_IP"
else
    warn "Could not detect public IP — NSG rules will use 0.0.0.0/0. Restrict manually."
    DEPLOYER_IP="*"
fi

az network nsg rule create \
    -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n AllowSSH --priority 1000 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 22 \
    --source-address-prefixes "$DEPLOYER_IP" \
    -o none

az network nsg rule create \
    -g "$RESOURCE_GROUP" --nsg-name "$NSG_NAME" \
    -n AllowHTTPS --priority 1010 --direction Inbound --access Allow \
    --protocol Tcp --destination-port-ranges 443 \
    --source-address-prefixes "$DEPLOYER_IP" \
    -o none

az network vnet subnet update \
    -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$CC_SUBNET_NAME" \
    --network-security-group "$NSG_NAME" -o none

# ── Managed identity & roles ────────────────────────────────────────────────

log "Phase 1 · Managed identity & role assignments"
az identity create -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" -o none 2>/dev/null || true

IDENTITY_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" \
    --query id -o tsv)
IDENTITY_CLIENT_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" \
    --query clientId -o tsv)
IDENTITY_PRINCIPAL_ID=$(az identity show -g "$RESOURCE_GROUP" -n "$IDENTITY_NAME" \
    --query principalId -o tsv)

RG_SCOPE=$(az group show -n "$RESOURCE_GROUP" --query id -o tsv)

for ROLE in "Contributor" "Storage Blob Data Contributor"; do
    az role assignment create \
        --assignee-object-id "$IDENTITY_PRINCIPAL_ID" \
        --assignee-principal-type ServicePrincipal \
        --role "$ROLE" --scope "$RG_SCOPE" \
        -o none 2>/dev/null \
    && info "$ROLE — assigned" \
    || info "$ROLE — already assigned"
done

# ════════════════════════════════════════════════════════════════════════════
#  Phase 2 · Storage
# ════════════════════════════════════════════════════════════════════════════

log "Phase 2 · Storage account ($STORAGE_ACCOUNT_NAME)"
az storage account create \
    -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" -l "$LOCATION" \
    --sku Standard_LRS --kind StorageV2 \
    --https-only true --min-tls-version TLS1_2 \
    --allow-blob-public-access false \
    -o none

STORAGE_KEY=$(az storage account keys list \
    -g "$RESOURCE_GROUP" -n "$STORAGE_ACCOUNT_NAME" \
    --query '[0].value' -o tsv)

az storage container create \
    --account-name "$STORAGE_ACCOUNT_NAME" --account-key "$STORAGE_KEY" \
    -n "$STORAGE_CONTAINER" -o none 2>/dev/null || true

# ── Azure NetApp Files ──────────────────────────────────────────────────────

log "Phase 2 · Azure NetApp Files account"
az netappfiles account create \
    -g "$RESOURCE_GROUP" -l "$LOCATION" -n "$ANF_ACCOUNT_NAME" -o none

log "Phase 2 · ANF capacity pool (${ANF_SERVICE_LEVEL}, ${ANF_POOL_SIZE_TIB} TiB)"
if ! az netappfiles pool show -g "$RESOURCE_GROUP" \
      --account-name "$ANF_ACCOUNT_NAME" -n "$ANF_POOL_NAME" &>/dev/null; then
    az netappfiles pool create \
        -g "$RESOURCE_GROUP" --account-name "$ANF_ACCOUNT_NAME" \
        -n "$ANF_POOL_NAME" -l "$LOCATION" \
        --service-level "$ANF_SERVICE_LEVEL" --size "$ANF_POOL_SIZE_TIB" \
        -o none
else
    info "Pool $ANF_POOL_NAME — already exists"
fi

ANF_SUBNET_ID=$(az network vnet subnet show \
    -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$ANF_SUBNET_NAME" \
    --query id -o tsv)

log "Phase 2 · ANF volume (NFSv4.1, ${ANF_VOLUME_SIZE_TIB} TiB)"
ANF_VOL_GIB=$(( ANF_VOLUME_SIZE_TIB * 1024 ))
if ! az netappfiles volume show -g "$RESOURCE_GROUP" \
      --account-name "$ANF_ACCOUNT_NAME" --pool-name "$ANF_POOL_NAME" \
      -n "$ANF_VOLUME_NAME" &>/dev/null; then

    # Build export-policy rule JSON safely with jq
    EXPORT_RULE=$(jq -nc '[{
        ruleIndex: 1,
        allowedClients: $cidr,
        unixReadWrite: true,
        hasRootAccess: true,
        nfsv3: false,
        nfsv41: true
    }]' --arg cidr "$VNET_CIDR")

    az netappfiles volume create \
        -g "$RESOURCE_GROUP" --account-name "$ANF_ACCOUNT_NAME" \
        --pool-name "$ANF_POOL_NAME" -n "$ANF_VOLUME_NAME" -l "$LOCATION" \
        --service-level "$ANF_SERVICE_LEVEL" \
        --usage-threshold "$ANF_VOL_GIB" \
        --file-path "$ANF_VOLUME_NAME" \
        --vnet "$VNET_NAME" --subnet "$ANF_SUBNET_ID" \
        --protocol-types NFSv4.1 \
        --unix-permissions 0777 \
        --export-policy-rules "$EXPORT_RULE" \
        -o none
else
    info "Volume $ANF_VOLUME_NAME — already exists"
fi

ANF_IP=$(az netappfiles volume show \
    -g "$RESOURCE_GROUP" --account-name "$ANF_ACCOUNT_NAME" \
    --pool-name "$ANF_POOL_NAME" -n "$ANF_VOLUME_NAME" \
    --query 'mountTargets[0].ipAddress' -o tsv)

info "ANF mount target : ${ANF_IP}:/${ANF_VOLUME_NAME}"

# ════════════════════════════════════════════════════════════════════════════
#  Phase 3 · CycleCloud Server
# ════════════════════════════════════════════════════════════════════════════

log "Phase 3 · Accept marketplace terms"
az vm image terms accept \
    --publisher azurecyclecloud --offer azure-cyclecloud \
    --plan cyclecloud8-gen2 -o none 2>/dev/null || true

CC_SUBNET_ID=$(az network vnet subnet show \
    -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" -n "$CC_SUBNET_NAME" \
    --query id -o tsv)

log "Phase 3 · Creating CycleCloud VM ($CC_VM_SIZE)"
if ! az vm show -g "$RESOURCE_GROUP" -n "$CC_VM_NAME" &>/dev/null; then
    az vm create \
        -g "$RESOURCE_GROUP" -n "$CC_VM_NAME" -l "$LOCATION" \
        --image "$CC_IMAGE" --size "$CC_VM_SIZE" \
        --admin-username "$CC_OS_USER" \
        --ssh-key-values "$SSH_PUB_KEY_PATH" \
        --subnet "$CC_SUBNET_ID" \
        --nsg "" \
        --public-ip-address "${CC_VM_NAME}-pip" --public-ip-sku Standard \
        --assign-identity "$IDENTITY_ID" \
        --os-disk-size-gb 128 --storage-sku Premium_LRS \
        --plan-name cyclecloud8-gen2 \
        --plan-publisher azurecyclecloud \
        --plan-product azure-cyclecloud \
        --only-show-errors -o none
else
    info "VM $CC_VM_NAME — already exists"
fi

CC_PUBLIC_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$CC_VM_NAME" \
    -d --query publicIps -o tsv)
CC_PRIVATE_IP=$(az vm show -g "$RESOURCE_GROUP" -n "$CC_VM_NAME" \
    -d --query privateIps -o tsv)
info "Public  IP : $CC_PUBLIC_IP"
info "Private IP : $CC_PRIVATE_IP"

# ════════════════════════════════════════════════════════════════════════════
#  Phase 3b · Configure CycleCloud
# ════════════════════════════════════════════════════════════════════════════

log "Phase 3b · Configuring CycleCloud"
info "Running configuration on the CycleCloud VM (may take 5–10 min)..."

# Build JSON config payloads locally with jq for safe escaping
USER_JSON=$(jq -nc '[{
    AdType: "AuthenticatedUser",
    Name: $u,
    RawPassword: $p,
    Superuser: true
}]' --arg u "$CC_ADMIN_USER" --arg p "$CC_ADMIN_PASSWORD")

EULA_JSON='[{"AdType":"Application.Setting","Name":"cycleserver.installation.complete","Value":true}]'

# Build CycleCloud account config (JSON format) for subscription registration
SUBSCRIPTION_NAME=$(jq -r '.name' <<< "$ACCOUNT_JSON")
ACCOUNT_CFG=$(jq -nc '{
    AcceptMarketplaceTerms: true,
    AuthType: "ManagedIdentity",
    AzureRMClientId: $cid,
    AzureRMSubscriptionId: $sub,
    AzureResourceGroup: $rg,
    DefaultAccount: true,
    Environment: "public",
    Location: $loc,
    LockerAuthMode: "ManagedIdentity",
    LockerIdentity: $identity_id,
    Name: $name,
    ProviderId: $sub,
    RMStorageAccount: $sa,
    RMStorageContainer: $sc
}' --arg sub "$SUBSCRIPTION_ID" \
   --arg cid "$IDENTITY_CLIENT_ID" --arg rg "$RESOURCE_GROUP" \
   --arg loc "$LOCATION" --arg name "$SUBSCRIPTION_NAME" \
   --arg sa "$STORAGE_ACCOUNT_NAME" --arg sc "$STORAGE_CONTAINER" \
   --arg identity_id "$IDENTITY_ID")

# Base64-encode payloads for safe transport to the VM
USER_B64=$(printf '%s' "$USER_JSON"        | base64 -w0)
EULA_B64=$(printf '%s' "$EULA_JSON"        | base64 -w0)
ACCT_B64=$(printf '%s' "$ACCOUNT_CFG"     | base64 -w0)
CCUSER_B64=$(printf '%s' "$CC_ADMIN_USER"     | base64 -w0)
CCPASS_B64=$(printf '%s' "$CC_ADMIN_PASSWORD" | base64 -w0)

# Write remote setup script to a temp file (expanded by the local shell,
# so all $VARs become concrete values; \$ produces literal $ for the remote shell)
REMOTE_SCRIPT=$(mktemp /tmp/cc_setup_XXXXXX.sh)
trap 'rm -f "$REMOTE_SCRIPT"' EXIT

cat > "$REMOTE_SCRIPT" <<ENDOFSCRIPT
#!/bin/bash
set -e

echo "==> [1/5] Waiting for CycleCloud service to start..."
# The CycleCloud service may not be running yet (e.g. still booting or installing).
# "cycle_server await_startup" exits non-zero with "CycleServer is not running"
# if the service hasn't started at all. We retry in a loop:
#   1. Try await_startup (succeeds if the service is starting or already up)
#   2. If it fails, the service isn't running yet — start it and retry
#   3. Give up after MAX_WAIT seconds total
MAX_WAIT=300
WAIT_INTERVAL=15
WAITED=0
while [ \$WAITED -lt \$MAX_WAIT ]; do
    if /opt/cycle_server/cycle_server await_startup 2>&1; then
        echo "CycleCloud service is running."
        break
    fi
    echo "  CycleCloud not ready yet (\${WAITED}s/\${MAX_WAIT}s) — attempting to start..."
    /opt/cycle_server/cycle_server start 2>&1 || true
    sleep \$WAIT_INTERVAL
    WAITED=\$(( WAITED + WAIT_INTERVAL ))
done
if [ \$WAITED -ge \$MAX_WAIT ]; then
    echo "ERROR: CycleCloud did not start within \${MAX_WAIT}s." >&2
    exit 1
fi

echo "==> [2/5] Writing data-directory configuration files..."
echo '${USER_B64}' | base64 -d > /opt/cycle_server/config/data/cc_user.json
echo '${EULA_B64}' | base64 -d > /opt/cycle_server/config/data/cc_eula.json

echo "==> [3/5] Restarting CycleCloud to ingest configuration..."
/opt/cycle_server/cycle_server restart
# Wait for the service to come back after restart using the same retry pattern
WAITED=0
while [ \$WAITED -lt \$MAX_WAIT ]; do
    if /opt/cycle_server/cycle_server await_startup 2>&1; then
        echo "CycleCloud restarted successfully."
        break
    fi
    echo "  Waiting for CycleCloud to restart (\${WAITED}s/\${MAX_WAIT}s)..."
    sleep \$WAIT_INTERVAL
    WAITED=\$(( WAITED + WAIT_INTERVAL ))
done
if [ \$WAITED -ge \$MAX_WAIT ]; then
    echo "ERROR: CycleCloud did not restart within \${MAX_WAIT}s." >&2
    exit 1
fi

echo "==> [4/5] Initializing CycleCloud CLI as ${CC_OS_USER}..."
CC_U=\$(echo '${CCUSER_B64}' | base64 -d)
CC_P=\$(echo '${CCPASS_B64}' | base64 -d)

for ATTEMPT in 1 2 3 4 5 6 7 8 9 10; do
    if sudo -u ${CC_OS_USER} /usr/local/bin/cyclecloud initialize --batch \\
        --url=https://localhost \\
        --username="\${CC_U}" \\
        --password="\${CC_P}" \\
        --verify-ssl=false 2>&1; then
        echo "CLI initialized."
        break
    fi
    echo "  Attempt \${ATTEMPT}/10 failed — waiting 30s for config to propagate..."
    sleep 30
done

echo "==> [5/5] Registering Azure subscription in CycleCloud..."
echo '${ACCT_B64}' | base64 -d > /tmp/cc_account.json
sudo -u ${CC_OS_USER} /usr/local/bin/cyclecloud account create -f /tmp/cc_account.json 2>&1 \
  && echo "Azure subscription registered." \
  || echo "Subscription may already be registered (or failed — check CycleCloud UI)."
#rm -f /tmp/cc_account.json

echo "==> DONE — CycleCloud is configured."
ENDOFSCRIPT

chmod +x "$REMOTE_SCRIPT"

# Execute the setup script on the CycleCloud VM
az vm run-command invoke \
    -g "$RESOURCE_GROUP" --name "$CC_VM_NAME" \
    --command-id RunShellScript \
    --scripts @"$REMOTE_SCRIPT" \
    -o json | jq -r '.value[0].message'

# ════════════════════════════════════════════════════════════════════════════
#  Phase 4 · Slurm Cluster
# ════════════════════════════════════════════════════════════════════════════

log "Phase 4 · Creating Slurm cluster ($SLURM_CLUSTER_NAME)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f "$SCRIPT_DIR/$SLURM_TEMPLATE_FILE" ]] || err "Slurm template file not found: $SCRIPT_DIR/$SLURM_TEMPLATE_FILE"
[[ -f "$SCRIPT_DIR/$SLURM_PARAMS_FILE" ]]  || err "Slurm params file not found: $SCRIPT_DIR/$SLURM_PARAMS_FILE"

# Patch params.json with dynamic values from this deployment
PATCHED_PARAMS=$(jq \
    --arg cred "$SUBSCRIPTION_NAME" \
    --arg subnet "${RESOURCE_GROUP}/${VNET_NAME}/${COMPUTE_SUBNET_NAME}" \
    --arg region "$LOCATION" \
    --arg nfs_ip "$ANF_IP" \
    --arg nfs_export "/${ANF_VOLUME_NAME}" \
    --arg identity "$IDENTITY_ID" \
    '.
     | .Credentials = $cred
     | .SubnetId = $subnet
     | .Region = $region
     | .NFSAddress = $nfs_ip
     | .NFSSharedExportPath = $nfs_export
     | .ManagedIdentity = $identity
    ' "$SCRIPT_DIR/$SLURM_PARAMS_FILE")

TMPL_B64=$(base64 -w0 < "$SCRIPT_DIR/$SLURM_TEMPLATE_FILE")
PARAMS_B64=$(printf '%s' "$PATCHED_PARAMS" | base64 -w0)

SLURM_SCRIPT=$(mktemp /tmp/cc_slurm_XXXXXX.sh)
trap 'rm -f "$REMOTE_SCRIPT" "$SLURM_SCRIPT"' EXIT

cat > "$SLURM_SCRIPT" <<ENDSLURM
#!/bin/bash
set -e

CLUSTER="${SLURM_CLUSTER_NAME}"
CC_USER="${CC_OS_USER}"

echo "==> [1/4] Writing cluster template and parameters..."
HOMEDIR=\$(eval echo ~\${CC_USER})
echo '${TMPL_B64}' | base64 -d > \${HOMEDIR}/slurm_template.txt
echo '${PARAMS_B64}' | base64 -d > \${HOMEDIR}/slurm_params.json
chown \${CC_USER}:\${CC_USER} \${HOMEDIR}/slurm_template.txt \${HOMEDIR}/slurm_params.json

echo "==> [2/4] Importing cluster template..."
sudo -u \${CC_USER} /usr/local/bin/cyclecloud import_cluster "\${CLUSTER}" \\
    -c Slurm -f \${HOMEDIR}/slurm_template.txt -p \${HOMEDIR}/slurm_params.json --force 2>&1
echo "Cluster '\${CLUSTER}' imported."

echo "==> [3/4] Starting cluster..."
sudo -u \${CC_USER} /usr/local/bin/cyclecloud start_cluster "\${CLUSTER}" 2>&1
echo "Cluster '\${CLUSTER}' start initiated."

# ── [4/4] Wait for the scheduler to leave the "Validation" state ──
# On first start, the scheduler node often gets stuck in "Validation"
# (shown as "Validation -- --" in show_cluster output with no IP assigned).
# If it hasn't progressed to "Allocation" (or beyond) within STUCK_TIMEOUT
# seconds, we stop the cluster, wait for it to fully stop, then restart it.
# This retry is usually enough to get past the transient issue.

echo "==> [4/4] Waiting for scheduler to progress past Validation..."

STUCK_TIMEOUT=120   # seconds to wait before considering the scheduler stuck
POLL_INTERVAL=10    # seconds between status checks
MAX_RETRIES=1       # number of stop/restart cycles to attempt

ATTEMPT=0
while true; do
    ELAPSED=0
    STUCK=false

    # Poll until the scheduler moves out of Validation or we hit the timeout
    while [ \$ELAPSED -lt \$STUCK_TIMEOUT ]; do
        STATUS=\$(sudo -u \${CC_USER} /usr/local/bin/cyclecloud show_cluster "\${CLUSTER}" 2>&1)

        # Check if the scheduler has an IP address assigned (indicates Allocation or later).
        # A stuck node shows: "scheduler: Validation -- --" (no IP)
        # A progressing node shows: "scheduler: Allocation -- 10.x.x.x"
        if echo "\${STATUS}" | grep -qP 'scheduler:.*Allocation|scheduler:.*Ready'; then
            echo "Scheduler is progressing (Allocation/Ready). Cluster is healthy."
            echo "\${STATUS}"
            echo "==> DONE — Slurm cluster created and started."
            exit 0
        fi

        # If the scheduler is not even in Validation, it may still be starting up
        if ! echo "\${STATUS}" | grep -q 'scheduler:'; then
            echo "  Scheduler node not yet visible, waiting..."
        else
            echo "  Scheduler still in Validation (\${ELAPSED}s / \${STUCK_TIMEOUT}s)..."
        fi

        sleep \$POLL_INTERVAL
        ELAPSED=\$(( ELAPSED + POLL_INTERVAL ))
    done

    # Timeout reached — scheduler appears stuck
    ATTEMPT=\$(( ATTEMPT + 1 ))
    if [ \$ATTEMPT -gt \$MAX_RETRIES ]; then
        echo "WARNING: Scheduler still stuck after \${MAX_RETRIES} restart attempt(s)."
        echo "Check the CycleCloud UI for details."
        sudo -u \${CC_USER} /usr/local/bin/cyclecloud show_cluster "\${CLUSTER}" 2>&1
        break
    fi

    echo "Scheduler stuck in Validation for \${STUCK_TIMEOUT}s — stopping cluster (attempt \${ATTEMPT}/\${MAX_RETRIES})..."
    sudo -u \${CC_USER} /usr/local/bin/cyclecloud terminate_cluster "\${CLUSTER}" 2>&1 || true

    # Wait for the cluster to fully stop before restarting
    echo "Waiting for cluster to terminate..."
    for i in \$(seq 1 30); do
        CSTATE=\$(sudo -u \${CC_USER} /usr/local/bin/cyclecloud show_cluster "\${CLUSTER}" 2>&1 \
                  | head -3 | grep -oP ':\s+\K\S+' || echo "unknown")
        if echo "\${CSTATE}" | grep -qiE 'off|terminated'; then
            echo "Cluster terminated."
            break
        fi
        echo "  Cluster state: \${CSTATE} — waiting 10s..."
        sleep 10
    done

    echo "Restarting cluster..."
    sudo -u \${CC_USER} /usr/local/bin/cyclecloud start_cluster "\${CLUSTER}" 2>&1
    echo "Cluster restarted — monitoring scheduler again..."
done

echo "==> DONE — Slurm cluster created and started."
ENDSLURM

chmod +x "$SLURM_SCRIPT"

az vm run-command invoke \
    -g "$RESOURCE_GROUP" --name "$CC_VM_NAME" \
    --command-id RunShellScript \
    --scripts @"$SLURM_SCRIPT" \
    -o json | jq -r '.value[0].message'

# ════════════════════════════════════════════════════════════════════════════
#  Phase 5 · Verification
# ════════════════════════════════════════════════════════════════════════════

log "Phase 5 · Verification"

# Verify ANF volume exists and is available
ANF_STATE=$(az netappfiles volume show \
    -g "$RESOURCE_GROUP" --account-name "$ANF_ACCOUNT_NAME" \
    --pool-name "$ANF_POOL_NAME" -n "$ANF_VOLUME_NAME" \
    --query provisioningState -o tsv 2>/dev/null || echo "Unknown")
info "ANF volume state : $ANF_STATE"

# ── Deployment summary ──────────────────────────────────────────────────────

log "Deployment complete"
cat <<SUMMARY
    ┌──────────────────────────────────────────────────────────────┐
    │  Azure CycleCloud + ANF                                     │
    ├──────────────────────────────────────────────────────────────┤
    │  Resource Group     : ${RESOURCE_GROUP}
    │  CycleCloud URL     : https://${CC_PUBLIC_IP}
    │  CycleCloud User    : ${CC_ADMIN_USER}
    │  CycleCloud VM SSH  : ssh ${CC_OS_USER}@${CC_PUBLIC_IP}
    │                                                              │
    │  ANF Mount          : ${ANF_IP}:/${ANF_VOLUME_NAME} → ${ANF_MOUNT_PATH}
    │  ANF Service Lvl    : ${ANF_SERVICE_LEVEL} (${ANF_VOLUME_SIZE_TIB} TiB)
    │                                                              │
    │  Slurm Cluster      : ${SLURM_CLUSTER_NAME}
    └──────────────────────────────────────────────────────────────┘

    Next steps:
      1. Open https://${CC_PUBLIC_IP} and log in as '${CC_ADMIN_USER}'
      2. Add the cluster users by clicking on the gear icon → Users → Create
      3. Select the login node and click "Connect" to get SSH instructions for the login node

SUMMARY

printf '\033[1;31m
    ☠                                                              ☠
    ☠                                                              ☠
    ☠   ⚠  PRODUCTION NOTE                                         ☠
    ☠                                                              ☠
    ☠   This deployment uses a PUBLIC IP for both login            ☠
    ☠   and compute nodes.                                         ☠
    ☠   Please do not use this configuration in production.        ☠
    ☠                                                              ☠
    ☠                                                              ☠
\033[0m\n'
