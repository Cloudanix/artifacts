# Cloudanix JIT Setup Scripts

One-command setup for Cloudanix Just-In-Time access infrastructure across AWS, Azure, and GCP.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash
```

Or specify the setup type directly:

```bash
# AWS JIT Database
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- aws-jit-db

# AWS JIT VM (SSH Proxy)
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- aws-jit-vm

# AWS JIT EKS (Kubernetes)
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- aws-jit-eks

# Azure JIT Database
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- azure-jit-db

# Azure JIT Kubernetes (AKS)
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- azure-jit-k8s

# GCP JIT Database
curl -fsSL https://raw.githubusercontent.com/Cloudanix/artifacts/main/install.sh | bash -s -- gcp-jit-db
```

## What Happens

1. The installer checks prerequisites (cloud CLI, jq, docker)
2. Downloads only the files needed for your setup type to `~/.cdx-jit/`
3. You run `./setup.sh` — it guides you through everything

## Features

- **Single entry point** — one `setup.sh` per product, presents all options
- **Idempotent** — every script safe to re-run (check-before-create)
- **Resumable** — state tracked in `.state.json`, resume after interruption
- **Multi-account guidance** — colored banners tell you exactly when to switch accounts
- **All config up front** — enter everything at the start, no mid-flow surprises
- **Cleanup support** — `./setup.sh --cleanup` tears down all created resources

## Setup Types

| Type | Cloud | What It Does |
|------|-------|-------------|
| `aws-jit-db` | AWS | ECS-based proxy for JIT database access (MySQL/PostgreSQL) |
| `aws-jit-vm` | AWS | ECS-based SSH proxy for JIT VM access |
| `aws-jit-eks` | AWS | Bastion hub for JIT Kubernetes (EKS) access |
| `azure-jit-db` | Azure | ACI-based proxy for JIT database access |
| `azure-jit-k8s` | Azure | VM hub for JIT Kubernetes (AKS) access |
| `gcp-jit-db` | GCP | GCE bastion for JIT Cloud SQL access |

## Prerequisites

| Setup Type | Required Tools |
|-----------|---------------|
| AWS (all) | `aws` CLI, `jq`, `docker` |
| Azure (all) | `az` CLI, `jq`, `docker` |
| GCP | `gcloud` CLI, `jq`, `docker` |

## Directory Structure

```
artifacts/
├── install.sh                 # One-liner installer (curl this)
├── lib/common.sh              # Shared library (logging, state, validation)
├── aws-jit-db/
│   ├── setup.sh               # Master orchestrator
│   ├── config.sh              # Configuration schema
│   └── steps/                 # Individual step scripts
├── aws-jit-vm/
├── aws-jit-eks/
├── azure-jit-db/
├── azure-jit-k8s/
├── gcp-jit-db/
└── tests/                     # bats-core test suite
```

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                  install.sh (curl)                    │
│  • Checks prerequisites                             │
│  • Downloads setup type files                        │
│  • Points user to setup.sh                           │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│                    setup.sh                           │
│  • Sources lib/common.sh + config.sh                 │
│  • Presents scope mode menu                          │
│  • Collects all config up front                      │
│  • Executes steps in sequence                        │
│  • Handles account switches                          │
│  • Tracks state in .state.json                       │
└───────────────────────┬─────────────────────────────┘
                        │
┌───────────────────────▼─────────────────────────────┐
│              steps/01-xxx.sh, 02-xxx.sh, ...         │
│  • Non-interactive (config via env vars)             │
│  • Idempotent (check-before-create)                  │
│  • Emit OUTPUT:KEY=VALUE for downstream steps        │
│  • Exit 0 on success, non-zero on failure            │
└─────────────────────────────────────────────────────┘
```

## Tech Stack

- **Pure Bash 4+** — no additional runtimes required
- **jq** — JSON manipulation for state files and API responses
- **Cloud CLIs** — `aws`, `az`, `gcloud` (native, no wrappers)
- **Docker** — for pulling/pushing container images
- **bats-core** — unit and integration testing

## Development

```bash
# Run all checks (lint + tests)
make check

# Run only unit tests
make test-unit

# Run only integration tests
make test-integration

# Syntax check all scripts
make lint
```

## License

Proprietary — Cloudanix, Inc.
