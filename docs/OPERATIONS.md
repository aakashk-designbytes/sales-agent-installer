# Operations guide

## Lifecycle commands

All actions use one file: `pwsh ./Install-SalesAgent.ps1 <action>`. The launchers `.cmd` and `.command` accept the same arguments.

| Action | What it does | Data |
|---|---|---|
| *(none)* / `install` | Install, repair or resume. Re-running is safe. When run from a newer package, it updates. | kept |
| `start` | Starts the containers; missing ones are re-created from the installed images. | kept |
| `stop` / `restart` | Stops / restarts the containers. | kept |
| `status` | Version, backend variant, per-service health, gateway probes. Exit code 0 = healthy, 2 = stopped, 3 = degraded. | – |
| `logs [-Service a,b] [-Follow] [-Tail n]` | Container logs. | – |
| `backup` | PostgreSQL (`pg_dump -Fc`) + MongoDB (`mongodump`) + configuration → `<config>/backups/<timestamp>…`. | – |
| `update` | Same as running a newer installer: backup → switch → health check → automatic rollback on failure. | backed up first |
| `rollback [-RestoreData]` | Returns to the version recorded before the last update. | optional restore |
| `uninstall [-RemoveImages] [-RemoveVolumes] [-RemoveConfig]` | Removes containers. Images, data and configuration go only on request; data deletion needs the typed phrase `DELETE ALL DATA` (or `-ConfirmDataDeletion 'DELETE ALL DATA'`). Docker is never uninstalled. | kept by default |

Common switches: `-ConfigDir`, `-EnvFile`, `-NonInteractive`, `-Yes`, `-NoBrowser`, `-HealthTimeoutSec`.

## Updates

Run the newer package's installer. It:

1. Keeps the configuration and asks only for settings the new version introduces.
2. Downloads and verifies the new images **while the old version keeps running**.
3. Backs up PostgreSQL, MongoDB and the configuration.
4. Re-creates the containers and waits for health.
5. **If anything fails**, switches back automatically to the previous images, compose files and configuration.
   It restores the database backup only with `-RestoreData` or when you confirm.

`rollback` repeats step 5 on demand. Backups do **not** include RustFS objects or Qdrant collections; for those,
back up the Docker volumes:

```bash
docker run --rm -v sales-agent_rustfs-data:/data -v "$PWD":/backup busybox tar czf /backup/rustfs-data.tgz -C /data .
docker run --rm -v sales-agent_qdrant-data:/data -v "$PWD":/backup busybox tar czf /backup/qdrant-data.tgz -C /data .
```

## Knowledge base (Qdrant `sop_documents`)

The service assistant searches the Qdrant collection `sop_documents`. It uses 384-dimension `BAAI/bge-small-en-v1.5` vectors, with payload fields such as `doc_type`, `document_id`, `engine_model`, `spn` and `fmi`. **A new installation ships it empty.** Service-assistant answers that rely on document search find nothing until the collection is filled.

To load a snapshot provided by your administrator:

```bash
# Qdrant is only on the internal network; upload through a throwaway curl container.
docker run --rm --network sales-agent-internal -v "$PWD:/s:ro" curlimages/curl:8.11.1 \
  -fsS -X POST "http://qdrant:6333/collections/sop_documents/snapshots/upload?priority=snapshot" \
  -F "snapshot=@/s/sop_documents.snapshot"
```

Snapshots are created on the source system with `POST /collections/sop_documents/snapshots`. The application team's ingestion scripts (`TSB_pdf_file_ingestion_scripts`) are the original way to build the collection.

## Seed bundle (drawings, UI assets)

Proposal PDFs embed general-arrangement drawings from the RustFS bucket `engine-drawings-v2`. The comparison table shows `ui-assets/genset.svg`. Neither ships in the images. The maintainers produce a bundle with `image-build/seed/export-drawings.ps1`, and you import it with:

```powershell
pwsh ./Install-SalesAgent.ps1 -SeedBundle ./sales-agent-seed-<date>.tar.gz     # or SEED_BUNDLE=... in sales-agent.env
```

Importing is idempotent: objects that already exist are skipped.

## Reference data note

The genset price list and specification tables come from the application's SQL snapshot. That snapshot has **no `app_code` values** in `price_list_genset`, so price and drawing lookups in proposals return nothing until the database is loaded with current reference data. See `image-build/db/export-live-reference-data.ps1` on the maintainer side.

## HTTPS / access from other computers

- By default the gateway listens only on `127.0.0.1`. Set `BIND_ADDRESS=0.0.0.0` and `PUBLIC_HOST=<name>` in `sales-agent.env` so other computers can connect over plain HTTP. Cookies then use `SameSite=Lax` with `Secure=false`.
- For HTTPS, put a TLS reverse proxy in front of the gateway, then set `PUBLIC_BASE_URL=https://…` and `COOKIE_SECURE=true` in `sales-agent.env`, and run the installer again.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `backend` keeps restarting; *Likely cause: The LLM endpoint is not reachable* | The backend cannot start without the LLM. Check `OPENAI_API_BASE`; for an LLM on this computer use `host.docker.internal`. |
| Backend is `starting` for a long time on first install | Guideline evaluation against the LLM; 5–15 minutes is normal. Watch progress with `Install-SalesAgent.ps1 logs -Service backend -Follow`. |
| `Port 8080 ... in use` | Set `APP_PORT=9090` in `sales-agent.env` (interactive installs offer a free port). |
| `This installer has not been released yet` / `No image digest recorded` | The package was not prepared for distribution (no registry/digests). Ask for a released package. |
| `Could not pull … authentication/authorization failed` | Run `docker login <registry>` with your read-only token. The token may have expired or been revoked. |
| Login form accepts nothing | Use the administrator user name (`SYSTEM_ADMIN_USERNAME`, default `admin`). LDAP users need the LDAP integration. |
| Docker Desktop: containers killed / very slow | Give Docker more memory (8 GB or more) in Settings → Resources. |

Installer logs are stored in `<config>/logs`, and every secret in them is masked.
