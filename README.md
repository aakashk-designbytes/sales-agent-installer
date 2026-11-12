# Sales Agent installer

**One file sets everything up.** It works on Windows, macOS and Linux, uses Docker, and contains no application source code.

| File | What it is |
|---|---|
| `Install-SalesAgent.ps1` | The installer and manager. All logic is in this one PowerShell 7 file. |
| `Install-SalesAgent.cmd` | **Windows:** double-click. Installs PowerShell 7 if it is missing (asks first), then runs the `.ps1`. |
| `Install-SalesAgent.command` | **macOS:** double-click. On Linux run `./Install-SalesAgent.command`. |
| `sales-agent.env.example` | All settings, with comments. Copy it to `sales-agent.env` and fill it in. |

> **Platform status.** End-to-end runs so far have been on **macOS (Apple Silicon)** only. Windows, Linux and
> NVIDIA GPU are implemented but not yet tested on real machines. See [docs/TESTING.md](docs/TESTING.md).

## Install

1. Copy `sales-agent.env.example` to **`sales-agent.env`** (same folder) and fill in the required values:

   | Setting | Example |
   |---|---|
   | `LITELLM_PROVIDER_MODEL_NAME` | `openai/Qwen/Qwen3-Coder-30B-A3B-Instruct` |
   | `OPENAI_API_BASE` | `http://llm-server:8000/v1` (use `http://host.docker.internal:8000/v1` for an LLM on this computer) |
   | `OPENAI_API_KEY` | `EMPTY` if the endpoint needs no key |
   | `GEMINI_API_KEY` | your Google Gemini key |
   | `SYSTEM_ADMIN_EMAIL` | `admin@example.com` |
   | `SYSTEM_ADMIN_PASSWORD` | 12+ characters. It is hashed during installation and then **removed from the file**. |

   Optional settings:
   - `APP_PORT` (default 8080)
   - LDAP, SMTP, Ollama, translation / vision LLMs, Oracle, MSSQL. **Each integration is switched on by filling in its first key**, e.g. `LDAP_HOST`.

   Anything you leave out is asked for on screen. If `sales-agent.env` is missing, the installer creates it for you.

2. Keep the **read-only download key** you received (for Amazon ECR: an AWS access key ID and secret). The installer
   asks for it when it downloads the images, turns it into a 12-hour Docker login, and **never stores it**.
   For unattended installs, set `SALES_AGENT_AWS_ACCESS_KEY_ID` and `SALES_AGENT_AWS_SECRET_ACCESS_KEY` beforehand.

3. **Double-click** `Install-SalesAgent.cmd` (Windows) or `Install-SalesAgent.command` (macOS), or run:
   ```powershell
   pwsh ./Install-SalesAgent.ps1
   ```

The installer then:
- checks the computer (RAM, disk, ports, GPU)
- installs or starts Docker if needed, **always asking first**
- generates the internal passwords
- downloads the digest-pinned images
- starts everything, waits until all services are healthy, and opens the browser

The **first start takes 5–15 minutes**: the AI agent evaluates its guidelines against your LLM, so the LLM must be reachable.

> macOS may block a downloaded `.command` file. Right-click it → **Open** once.

## Managing Sales Agent

```powershell
pwsh ./Install-SalesAgent.ps1 status          # version, health of every service, URL
pwsh ./Install-SalesAgent.ps1 logs -Service backend -Follow
pwsh ./Install-SalesAgent.ps1 stop            # data is kept
pwsh ./Install-SalesAgent.ps1 start
pwsh ./Install-SalesAgent.ps1 restart
pwsh ./Install-SalesAgent.ps1 backup          # PostgreSQL + MongoDB + configuration
pwsh ./Install-SalesAgent.ps1 uninstall       # removes containers, keeps data
pwsh ./Install-SalesAgent.ps1 uninstall -RemoveVolumes -RemoveConfig   # deletes everything (asks you to type DELETE ALL DATA)
```

The launchers accept the same arguments, for example `Install-SalesAgent.cmd status`.

- **Changing a setting:** edit `sales-agent.env` and run the installer again. It shows the changes and asks before applying them (`-Yes` applies them without asking).
- **Updating:** run the installer from the newer package. It detects the installed version, makes a backup, switches, health-checks, and rolls back automatically if anything fails. `Install-SalesAgent.ps1 rollback` returns to the previous version afterwards.
- **Unattended use:** `-NonInteractive -Yes`. Set the admin password with `SALES_AGENT_ADMIN_PASSWORD`, and the registry login with `SALES_AGENT_REGISTRY_USERNAME` / `SALES_AGENT_REGISTRY_TOKEN`.

## Where things are stored

| What | Where |
|---|---|
| Your input | `sales-agent.env` next to the installer (keep it private; the admin password is removed after hashing) |
| Configuration actually used: `config.json`, `.env`, `backend.env`, `frontend.env`. Internal passwords are generated here. | Windows `%LOCALAPPDATA%\SalesAgent`, macOS `~/Library/Application Support/SalesAgent`, Linux `~/.config/sales-agent`. Readable by your user only. |
| Logs (secrets masked) / backups | `<config>/logs`, `<config>/backups` |
| Application data | Docker volumes `sales-agent_*` |

Only the web gateway is reachable from your computer (`http://localhost:8080` by default). Databases, the file store
and the backend are on a private Docker network.

More: [docs/OPERATIONS.md](docs/OPERATIONS.md) (backup/restore, knowledge base, seed bundle, HTTPS, troubleshooting) ·
[docs/RELEASING.md](docs/RELEASING.md) (maintainers).
