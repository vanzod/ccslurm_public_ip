# CycleCloud Slurm Cluster with Public IPs

Single-script deployment of Azure CycleCloud 8.x with a Slurm cluster and ANF shared storage. 

The CycleCloud server, login node, and all compute nodes are assigned public IPs.

## Security warning

**This configuration exposes all cluster nodes to the public internet. It is intended for testing and development only and should not be used in production.**

## What it deploys

```
                        ┌─────────────────────────────────────────────┐
                        │         Resource Group (rg-cyclecloud)      │
                        │                                             │
                        │  ┌───────────── VNet (10.0.0.0/16) ───────┐ │
                        │  │                                        │ │
                        │  │  snet-cyclecloud    snet-compute       │ │
                        │  │  10.0.1.0/24        10.0.16.0/20       │ │
                        │  │  ┌──────────┐       ┌──────────────┐   │ │
                        │  │  │CycleCloud│       │  Scheduler   │   │ │
                        │  │  │  Server  │─────▶│  Login Node  │   │ │
                        │  │  │ (D4s_v5) │       │  Compute x N │   │ │
                        │  │  └──────────┘       └──────┬───────┘   │ │
                        │  │                            │           │ │
                        │  │  snet-anf                  │ NFS 4.1   │ │
                        │  │  10.0.3.0/24               │           │ │
                        │  │  ┌─────────────────────────▼────────┐  │ │
                        │  │  │  Azure NetApp Files (Premium)    │  │ │
                        │  │  │  vol-shared → /shared  (12 TiB)  │  │ │
                        │  │  └──────────────────────────────────┘  │ │
                        │  └────────────────────────────────────────┘ │
                        │                                             │
                        │  ┌──────────────┐  ┌───────────────────┐    │
                        │  │ Storage Acct │  │ Managed Identity  │    │
                        │  │ (CycleCloud  │  │ (Contributor +    │    │
                        │  │  locker)     │  │  Blob Data Contr.)│    │
                        │  └──────────────┘  └───────────────────┘    │
                        └─────────────────────────────────────────────┘
```

## Prerequisites

- Azure CLI ≥ 2.50, `jq`, `curl`
- SSH key pair (`~/.ssh/id_rsa.pub`)
- Active Azure login (`az login`)

## Quick start

```bash
CC_ADMIN_PASSWORD='YourP@ssw0rd!' ./deploy-cyclecloud.sh
```

## Configuration

All defaults can be overridden via environment variables:

| Variable | Default | Description |
|---|---|---|
| `LOCATION` | `centralus` | Azure region |
| `RESOURCE_GROUP` | `rg-cyclecloud` | Resource group name |
| `CC_VM_SIZE` | `Standard_D4s_v5` | CycleCloud VM SKU |
| `ANF_SERVICE_LEVEL` | `Premium` | ANF tier (Standard/Premium/Ultra) |
| `ANF_VOLUME_SIZE_TIB` | `12` | ANF volume size in TiB |
| `SLURM_CLUSTER_NAME` | `cc-slurm` | Slurm cluster name |
| `SSH_PUB_KEY_PATH` | `~/.ssh/id_rsa.pub` | SSH public key |

See the top of `deploy-cyclecloud.sh` for the full list.

## Files

| File | Purpose |
|---|---|
| `deploy-cyclecloud.sh` | Main deployment script |
| `slurm.txt` | CycleCloud Slurm cluster template |
| `params.json` | Cluster parameters (patched at runtime) |

## Cleanup

```bash
az group delete -n rg-cyclecloud --yes --no-wait
```
