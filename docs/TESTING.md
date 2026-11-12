# Testing

Last updated: 2026-11-09. The results below come from real runs. Anything not run says so.

> **Installer form.** The installer is now a single file, `Install-SalesAgent.ps1`, with `.cmd`/`.command` launchers.
> It was re-tested on macOS arm64 in maintainer mode (`-UseLocalImages`). The images used were built **with** the
> reference changes from `docs/SOURCE-CHANGES.md`. Images built from the unchanged application source cannot be tested:
> the backend build stops on the out-of-sync `poetry.lock` (A1, verified), and the frontend builds but has no
> same-origin backend URL (A2, verified).

## Platform matrix

| Platform | Status | What was run |
|---|---|---|
| **macOS 26 / Apple Silicon (arm64)**, Docker Desktop 29.9, pwsh 7.6 | **Tested** (infrastructure); **functional E2E pending** | Image builds + verification, unit tests, install / re-run / resume, stop / start / status / logs, backup, uninstall (keep data) + reinstall with data intact, seed bundle, gateway routes, failure diagnostics |
| Linux amd64 (Ubuntu 22.04, pwsh 7.4 in a container under emulation) | **Partial** | Unit tests (77 pass) and OS / RAM / disk / config-dir detection only. No Docker daemon inside, so no deployment. |
| Linux amd64 / arm64 host | Awaiting testing | – |
| Windows 11 (Docker Desktop + WSL 2) | Awaiting testing | Code paths exist: winget install, ACLs, `%LOCALAPPDATA%`. None has been executed. |
| macOS Intel | Awaiting testing | – |
| NVIDIA GPU (CUDA variant) | Awaiting testing | The CUDA image **built** under QEMU before patch 0006 and reported `torch 2.13.0+cu126, CUDA 12.6`. The rebuild with all patches crashed Docker Desktop (7.7 GB VM, emulated build). **The local `-cuda` image is stale and must be rebuilt**, preferably on an x86_64 host or CI, or with Docker Desktop memory raised to 10+ GB. It has not run on a GPU. |

## Automated tests

| Suite | Command | Result |
|---|---|---|
| Unit (Pester), macOS, single-file installer | `Invoke-Pester ./tests/unit` | 33 passed, 0 failed (includes a real `docker compose config` validation of the embedded stack) |
| Unit (Pester), Linux container | same | Run against the previous multi-file installer (77 passed); not yet re-run for the single file |
| Image verification | `image-build/verify-images.ps1` | frontend, backend-cpu, db: all checks pass (arm64, images built with the reference changes) |
| Functional E2E | `tests/e2e/Invoke-E2E.ps1` | **Not yet run.** Needs a reachable LLM endpoint and Gemini key (test config pending) |

The unit tests cover:

- type validation for every config type
- schema / defaults consistency
- dotenv quoting (verified against `docker compose config`)
- generated secrets
- preserve-on-rerun
- prompting only for new keys
- answers-file conflicts
- cookie rules
- derived URLs and URL-encoding
- owner-only file modes
- secret redaction in console and log files
- LOCAL / REGISTRY image resolution (placeholder registry and missing digests refused, never pulls in LOCAL)
- auth-error detection
- third-party digest pins matching compose
- version comparison, port checks
- prerequisite evaluation
- GPU variant selection

## Single-file installer (macOS arm64, `-UseLocalImages`, deliberately unreachable LLM)

| Check | Result |
|---|---|
| Requirements, local images, pinned third-party images | Passed |
| `sales-agent.env` read; missing values listed; admin password bcrypt-hashed and **removed from the file** | Passed |
| Owner-only config files; endpoint warnings | Passed |
| 8 services healthy except the backend; backend crash loop detected with *Likely cause: LLM not reachable* | Passed |
| Re-run: no prompts, configuration kept; crash-looping backend recreated before waiting | Passed |
| A changed value in `sales-agent.env` is shown and **not** applied without confirmation / `-Yes` | Passed |
| `status`, `logs -Service a,b`, `backup`, `stop` | Passed |
| `uninstall` keeps 10 data volumes; `-RemoveVolumes` refused without the typed phrase | Passed |
| **Full start with images built from `uat-eb-sync-poetry` (no patches)**, main model `gemini/gemini-3.5-flash` via LiteLLM | **Passed**: all services healthy after 317 s; gateway, frontend, backend `/healthz` 200, files route OK (2026-11-10) |
| Main model `qwen2.5-coder:1.5b` / `qwen2.5:7b` (local Ollama) | **Not usable**: Parlant's startup evaluation rejects their JSON (`does not match expected schema`) |
| Company LLM over VPN (`192.168.63.12`) | Not reachable from the test Mac; the installer's container-side check now stops early with a clear message |
| Browser login, chat/SSE, upload, PDF | **Blocked by A2** (frontend URL change not yet in the source); backend APIs can be tested directly |
| Update / rollback | Pending |

## Test cases from the earlier multi-file installer (macOS arm64, LOCAL mode)

| # | Case | Result | Notes |
|---|---|---|---|
| 1 | Fresh installation | **Partly passed** | Stack deployed. db, mongo, redis, qdrant, rustfs, storage-init, frontend and gateway are healthy. The backend stops at guideline evaluation because the test used an unreachable LLM on purpose. Repeat with a real LLM. |
| 2 | Docker already installed | Passed | Detected engine 29.9.2, Compose 5.6.1 |
| 3 | Docker missing | Unit-tested only | `Assert-SADockerOperational` / `Install-SADocker`; not executed on a machine without Docker |
| 4 | Docker daemon stopped | Partly | Daemon start + wait logic exercised at the start of the session (Docker Desktop was stopped); `stop.ps1` handles a stopped daemon |
| 5 | CPU installation | Passed (infra) | `auto` → CPU on macOS |
| 6 | GPU installation | Awaiting hardware | – |
| 7 | Environment configuration | Passed | Answers file, generated secrets, bcrypt admin hash, protected files (600/700) |
| 8 | Invalid credentials | Partly | Wrong admin password rejection is part of E2E (pending). Invalid answers rejected (unit). Registry auth errors are detected by unit test only. |
| 9 | Port conflicts | Passed (unit) | Port held by another process / other container → FAIL; own stack → OK |
| 10 | Missing external services | **Passed** | Unreachable LLM: warned before deploy; backend crash-loop detected; *Likely cause: The LLM endpoint is not reachable* shown |
| 11 | Interrupted installation | Passed | Failed install re-run resumed with the saved configuration and no prompts |
| 12 | Re-running installer | Passed | Idempotent; port held by own stack accepted |
| 13 | Starting and stopping | Passed | `stop.ps1` keeps containers + data; `start.ps1` restores |
| 14 | Application updates | **Not yet run** | Needs a healthy backend (update waits for health); planned with the E2E run |
| 15 | Persistent data preservation | Passed (infra) | PostgreSQL + MongoDB marker rows survived uninstall + reinstall. RustFS objects persisted (seed import skipped existing objects). |
| 16 | Uninstallation | Passed | Containers removed, 10 volumes kept. `-RemoveConfig` without `-RemoveVolumes` refused. `-RemoveVolumes` refused without the typed phrase. Docker untouched. |

## Gateway checks (macOS)

- `/viewer/` serves seeded objects, including keys with spaces (raw URI forwarding).
- Bucket listing and PUT through `/viewer/` are denied (403).
- `/` → frontend 200; `/gateway-health` 200.
- SSE through `/eb-backend` is configured (`proxy_buffering off`, 1800 s timeouts) and is verified by the E2E script once the backend is healthy.

## Functional workflow (pending a real LLM)

`tests/e2e/Invoke-E2E.ps1` covers:

- admin login through the BFF (cookies over HTTP), with a wrong password rejected
- profile and agent list
- chat message plus AI reply over **SSE**
- file upload to RustFS plus download via `/viewer`
- optional proposal PDF (`-ProposalPrompt`)
- stop / start, then persistence of the session and the uploaded file

Proposal PDFs with drawings also need a seed bundle and current reference data (see `OPERATIONS.md`).
