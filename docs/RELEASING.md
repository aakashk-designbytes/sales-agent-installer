# Releasing (maintainers)

All release information sits in **one block at the top of `Install-SalesAgent.ps1`**: `RELEASE INFORMATION`
(`$script:Release`). Nothing else changes between releases unless the settings catalogue or the stack changes.

| Field | Value |
|---|---|
| `AppVersion` | Application version, e.g. `1.0.1` |
| `InstallerVersion` | Version of this installer file |
| `RegistryHost` | e.g. `salesagentreg.azurecr.io` (the placeholder `registry.example.com` blocks installation) |
| `RegistryNamespace` | e.g. `sales-agent` (the placeholder `my-organization` blocks installation) |
| `Images.<key>.Tag` | `1.0.1`, `1.0.1-cpu`, `1.0.1-cuda` |
| `Images.<key>.Digest` | `sha256:…` of the **multi-platform index** (`docker buildx imagetools inspect`) |
| `ThirdParty.*` | Only when bumping nginx/mongo/redis/qdrant/rustfs. Always `tag@sha256:`. |
| `ConfigVersion` | Increase when settings are added to the catalogue |

Image keys: `frontend`, `backend-cpu`, `backend-cuda`, `db`. The installer resolves images as
`<RegistryHost>/<RegistryNamespace>/<Repository>@<Digest>`. It refuses to install without digests and never
falls back to local images. `-UseLocalImages` is a maintainer switch for testing only.

New application environment variable? Add a `New-SASetting` line to the settings catalogue (it appears in the
generated `sales-agent.env` template automatically), then regenerate `sales-agent.env.example`:

```powershell
pwsh -c '. ./Install-SalesAgent.ps1; New-SAEnvTemplate ./sales-agent.env.example'
```

## Checklist

1. Images built from the tagged application commit, verified, pushed, digests recorded
   (`../docs/PUBLISHING.md`, sections C–E).
2. `RELEASE INFORMATION` updated; `Invoke-Pester ./tests/unit` green.
3. On a clean machine: install, then update from the previous release, then `rollback`.
4. Package: `Install-SalesAgent.ps1`, `Install-SalesAgent.cmd`, `Install-SalesAgent.command`,
   `sales-agent.env.example`, `README.md`, `docs/`. Do not include `tests/` or any filled-in `sales-agent.env`.
