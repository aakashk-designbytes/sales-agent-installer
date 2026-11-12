#Requires -Version 7.2
<#
.SYNOPSIS
    Sales Agent: one-file installer and manager (Windows, macOS, Linux).

.DESCRIPTION
    Double-click Install-SalesAgent.cmd (Windows) or Install-SalesAgent.command
    (macOS), or run:  pwsh ./Install-SalesAgent.ps1

    install (default)
        1. Checks the computer (OS, CPU, RAM, disk, ports, NVIDIA GPU).
        2. Installs / starts Docker if needed (always asks first).
        3. Reads your values from sales-agent.env next to this file and asks
           for anything still missing. Internal passwords are generated.
        4. Downloads the digest-pinned Sales Agent images from the registry.
        5. Starts everything, waits until it is healthy and opens the browser.
        Re-running is safe; it resumes after interruptions and applies changes
        made in sales-agent.env (after confirmation). Running a newer copy of
        this file on an existing installation performs an update.

    Other actions:  start | stop | restart | status | logs | update | rollback |
                    backup | uninstall

    Configuration and data live outside this folder:
      Windows %LOCALAPPDATA%\SalesAgent, macOS ~/Library/Application Support/SalesAgent,
      Linux ~/.config/sales-agent  (override with -ConfigDir).

.EXAMPLE
    pwsh ./Install-SalesAgent.ps1
.EXAMPLE
    pwsh ./Install-SalesAgent.ps1 status
.EXAMPLE
    pwsh ./Install-SalesAgent.ps1 logs -Service backend -Follow
.EXAMPLE
    pwsh ./Install-SalesAgent.ps1 uninstall -RemoveVolumes
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'logs', 'update', 'rollback', 'backup', 'uninstall')]
    [string]$Action = 'install',

    # Values file (default: sales-agent.env next to this script).
    [string]$EnvFile,
    [string]$ConfigDir,
    [ValidateSet('auto', 'cpu', 'cuda')][string]$Variant,

    # logs
    [string[]]$Service,
    [Alias('f')][switch]$Follow,
    [int]$Tail = 200,

    [string]$SeedBundle,
    [switch]$RestoreData,

    # uninstall
    [switch]$RemoveImages,
    [switch]$RemoveVolumes,
    [switch]$RemoveConfig,
    [string]$ConfirmDataDeletion,

    [switch]$NonInteractive,
    [Alias('y')][switch]$Yes,
    [switch]$NoBrowser,
    [switch]$SkipEndpointCheck,
    [int]$HealthTimeoutSec = 1500,

    # MAINTAINERS ONLY: use images already present in the local Docker image
    # store (built with image-build/build-images.ps1) instead of the registry.
    [switch]$UseLocalImages
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# =============================================================================
#  RELEASE INFORMATION - the only section to edit when publishing a release
#  (see docs/RELEASING.md). Digests are those of the multi-platform indexes.
# =============================================================================
$script:Release = @{
    InstallerVersion  = '1.0.0'
    AppVersion        = '1.0.0'
    ConfigVersion     = 1
    RegistryHost      = 'registry.example.com'     # e.g. salesagentreg.azurecr.io
    RegistryNamespace = 'my-organization'          # e.g. sales-agent
    Images            = [ordered]@{
        'frontend'     = @{ Repository = 'sales-agent-frontend'; Tag = '1.0.0';      Digest = $null }
        'backend-cpu'  = @{ Repository = 'sales-agent-backend';  Tag = '1.0.0-cpu';  Digest = $null }
        'backend-cuda' = @{ Repository = 'sales-agent-backend';  Tag = '1.0.0-cuda'; Digest = $null }
        'db'           = @{ Repository = 'sales-agent-db';       Tag = '1.0.0';      Digest = $null }
    }
    ThirdParty        = [ordered]@{
        gateway = 'nginxinc/nginx-unprivileged:1.28.2-alpine@sha256:7377697a821c131a924a7105fafbe7414db4e9fcc77a6f08f776f33f141ec3f8'
        mongo   = 'mongo:8.0.34@sha256:b9924c330a8bbc5800fe9c69f04a84e221eca7b28fd049a0354147d9908fa142'
        redis   = 'redis:7.4.12-alpine@sha256:c5d34a98396a4775e223c74e929162c35c5a2182901ba26b50ade939941ce14b'
        qdrant  = 'qdrant/qdrant:v1.20.0@sha256:9bfc89f9914fc14876a88c05270685921a55b8877b254a98bcc1cc2f0a424cd2'
        rustfs  = 'rustfs/rustfs:1.0.4@sha256:ed9210d6411d77ffceb70d94b964a3cb7d225983368bc25bebe01e995293dcc2'
    }
    Requirements      = @{ DockerMin = '24.0.0'; ComposeMin = '2.20.0'; RamGBMin = 8; RamGBRecommended = 16; DiskGBCpu = 30; DiskGBCuda = 45; CudaMin = '12.6' }
}

# =============================================================================
#  SETTINGS CATALOGUE - the values users provide in sales-agent.env.
#  Names are the application's own environment variables (plus a few
#  installer settings). Everything else is generated or derived.
# =============================================================================
function New-SASetting {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Name,
        [Parameter(Mandatory, Position = 1)][string]$Group,
        [Parameter(Position = 2)][ValidateSet('string', 'int', 'bool', 'url', 'port', 'path', 'secret', 'email', 'host')][string]$Type = 'string',
        [switch]$Required, $Default, [string]$Prompt, [switch]$Advanced, [string[]]$Enum, [string]$Pattern,
        [ValidateSet('installer', 'backend', 'both')][string]$Target = 'backend', [int]$MinLength = 0
    )
    [pscustomobject]@{ Name = $Name; Group = $Group; Type = $Type; Required = [bool]$Required; Default = $Default
        Prompt = ($Prompt ? $Prompt : $Name); Advanced = [bool]$Advanced; Enum = $Enum; Pattern = $Pattern; Target = $Target; MinLength = $MinLength }
}

$script:Settings = @(
    # --- installer ------------------------------------------------------------
    New-SASetting APP_PORT              installer port   -Default 8080 -Target installer -Prompt 'Port for the web application (http://localhost:<port>)'
    New-SASetting BIND_ADDRESS          installer string -Default '127.0.0.1' -Enum '127.0.0.1', '0.0.0.0' -Target installer -Advanced
    New-SASetting PUBLIC_HOST           installer host   -Default 'localhost' -Target installer -Advanced
    New-SASetting PUBLIC_BASE_URL       installer url    -Target installer -Advanced
    New-SASetting BACKEND_VARIANT       installer string -Default 'auto' -Enum 'auto', 'cpu', 'cuda' -Target installer -Advanced
    New-SASetting SERVICE_AGENT_DATA_DIR installer path  -Target installer -Advanced
    New-SASetting SEED_BUNDLE           installer path   -Target installer -Advanced
    # --- required application values -------------------------------------------------
    New-SASetting LITELLM_PROVIDER_MODEL_NAME llm string -Required -Pattern '^[a-z0-9_]+(_[a-z0-9]+)*/\S+$' -Prompt 'Chat model name, LiteLLM format (e.g. openai/Qwen/Qwen3-Coder-30B-A3B-Instruct)'
    New-SASetting OPENAI_API_BASE       llm url    -Required -Prompt 'OpenAI-compatible LLM base URL (e.g. http://llm-server:8000/v1)'
    New-SASetting OPENAI_API_KEY        llm secret -Required -Default 'EMPTY' -Prompt 'API key of that LLM endpoint (EMPTY if none)'
    New-SASetting GEMINI_API_KEY        gemini secret -Required -Prompt 'Google Gemini API key'
    New-SASetting SYSTEM_ADMIN_USERNAME admin string -Required -Default 'admin' -Pattern '^[A-Za-z0-9._-]{3,64}$' -Prompt 'Administrator user name'
    New-SASetting SYSTEM_ADMIN_EMAIL    admin email  -Required -Prompt 'Administrator e-mail'
    New-SASetting SYSTEM_ADMIN_PASSWORD admin secret -Required -MinLength 12 -Prompt 'Administrator password (min. 12 characters)'
    New-SASetting SYSTEM_ADMIN_NAME     admin string -Default 'System Administrator' -Advanced
    # --- optional tuning (defaults = application defaults) -------------------------------
    New-SASetting LITELLM_PROVIDER_API_KEY  llm secret -Advanced
    New-SASetting LITELLM_PROVIDER_BASE_URL llm url    -Advanced
    New-SASetting QWEN_MODEL_NAME       llm string -Pattern '^[a-z0-9_]+(_[a-z0-9]+)*/\S+$' -Advanced
    New-SASetting LLM_PROVIDER          llm string -Default 'litellm' -Enum 'litellm', 'ollama' -Advanced
    New-SASetting MAX_MODEL_LEN         llm int    -Advanced
    New-SASetting LITELLM_EMBEDDING_MODEL_NAME llm string -Advanced
    New-SASetting ALGORITHM             auth string -Default 'HS256' -Enum 'HS256', 'HS384', 'HS512' -Advanced
    New-SASetting ACCESS_TOKEN_EXPIRE_MINUTES  auth int -Default 60  -Advanced
    New-SASetting REFRESH_TOKEN_EXPIRE_MINUTES auth int -Default 480 -Advanced
    New-SASetting JWT_LEEWAY_SECONDS    auth int  -Default 30 -Advanced
    New-SASetting MAX_CONCURRENT_SESSIONS auth int -Default 2 -Advanced
    New-SASetting LOGIN_RATE_LIMIT_MAX  auth int  -Default 10 -Advanced
    New-SASetting LOGIN_RATE_LIMIT_WINDOW auth int -Default 60 -Advanced
    New-SASetting COOKIE_SECURE         auth bool -Default $false -Target both -Advanced
    New-SASetting COOKIE_SAMESITE       auth string -Default 'lax' -Enum 'lax', 'strict', 'none' -Target both -Advanced
    New-SASetting ENABLE_GENERAL_ASSISTANT core bool -Default $true -Advanced
    New-SASetting AGENT_ACCESS_ENFORCEMENT core bool -Default $true -Advanced
    New-SASetting MAX_FILE_SIZE_MB      core int  -Default 50 -Advanced
    New-SASetting PARLANT_TOOL_RESULT_MAX_PAYLOAD_KB core int -Default 10240 -Advanced
    # --- optional integrations: a group is enabled when its first key is set -----------
    New-SASetting OLLAMA_BASE_URL       ollama url
    New-SASetting OLLAMA_MODEL          ollama string -Default 'qwen3-coder:30b'
    New-SASetting TRANSLATION_API_URL   translation url
    New-SASetting TRANSLATION_MODEL_NAME translation string -Default 'gemma4:31b'
    New-SASetting VLM_URL               vlm url
    New-SASetting VLM_MODEL             vlm string -Default 'Qwen/Qwen3.5-35B-A3B-FP8'
    New-SASetting VLM_PARALLEL_WORKERS  vlm int -Default 8 -Advanced
    New-SASetting ORACLE_DB_URL         oracle string
    New-SASetting ORACLE_DB_USERNAME    oracle string
    New-SASetting ORACLE_DB_PASSWORD    oracle secret
    New-SASetting IKONNECT_MSSQL_DB_HOST mssql host
    New-SASetting IKONNECT_MSSQL_DB_PORT mssql port -Default 1433
    New-SASetting IKONNECT_MSSQL_DB_NAME mssql string
    New-SASetting IKONNECT_MSSQL_DB_USER mssql string
    New-SASetting IKONNECT_MSSQL_DB_PASSWORD mssql secret
    New-SASetting LDAP_HOST             ldap host
    New-SASetting LDAP_PORT             ldap port -Default 389
    New-SASetting LDAP_USE_TLS          ldap bool -Default $false
    New-SASetting LDAP_SEARCH_BASE      ldap string
    New-SASetting LDAP_DOMAIN           ldap string
    New-SASetting LDAP_UPN_SUFFIX       ldap string
    New-SASetting LDAP_SERVICE_BIND_DN  ldap string
    New-SASetting LDAP_SERVICE_BIND_PASSWORD ldap secret
    New-SASetting LDAP_BIND_TIMEOUT     ldap int -Default 5 -Advanced
    New-SASetting LDAP_SEARCH_TIMEOUT   ldap int -Default 5 -Advanced
    New-SASetting SMTP_HOST             smtp host
    New-SASetting SMTP_PORT             smtp port -Default 587
    New-SASetting SMTP_USE_TLS          smtp bool -Default $true
    New-SASetting SMTP_FROM             smtp email
    New-SASetting OTP_EMAIL_APP_NAME    smtp string -Default 'Sales Agent' -Advanced
    New-SASetting OTP_LENGTH            smtp int -Default 6 -Advanced
    New-SASetting OTP_EXPIRE_SECONDS    smtp int -Default 600 -Advanced
    New-SASetting OTP_MAX_VERIFY_ATTEMPTS smtp int -Default 5 -Advanced
    New-SASetting OTP_RESEND_COOLDOWN_SECONDS smtp int -Default 60 -Advanced
    New-SASetting OTP_LOCK_SECONDS      smtp int -Default 900 -Advanced
)
$script:OptionalGroups = [ordered]@{
    ollama = 'OLLAMA_BASE_URL'; translation = 'TRANSLATION_API_URL'; vlm = 'VLM_URL'; oracle = 'ORACLE_DB_URL'
    mssql = 'IKONNECT_MSSQL_DB_HOST'; ldap = 'LDAP_HOST'; smtp = 'SMTP_HOST'
}

# Written for DISABLED integrations so the application never falls back to the
# company addresses that its code still uses as defaults (docs/SOURCE-CHANGES.md B1/B3).
$script:DisabledGroupValues = @{
    ollama      = [ordered]@{ OLLAMA_BASE_URL = 'http://127.0.0.1:9' }
    translation = [ordered]@{ TRANSLATION_API_URL = 'http://127.0.0.1:9/v1/chat/completions' }
    vlm         = [ordered]@{}
    oracle      = [ordered]@{ ORACLE_DB_URL = ''; ORACLE_DB_USERNAME = ''; ORACLE_DB_PASSWORD = '' }
    mssql       = [ordered]@{ IKONNECT_MSSQL_DB_HOST = ''; IKONNECT_MSSQL_DB_USER = ''; IKONNECT_MSSQL_DB_PASSWORD = ''; IKONNECT_MSSQL_DB_NAME = '' }
    ldap        = [ordered]@{ LDAP_UPN_SUFFIX = 'ldap.invalid' }
    smtp        = [ordered]@{ SMTP_FROM = 'noreply@localhost' }
}

# =============================================================================
#  EMBEDDED FILES - written to <config>/runtime on every install/update.
# =============================================================================
$script:Embedded = [ordered]@{}
$script:Embedded['docker-compose.yml'] = @'
# Generated by Install-SalesAgent.ps1 - do not edit (re-run the installer instead).
# Only the gateway publishes a host port; everything else is on the private network.
name: ${COMPOSE_PROJECT_NAME:-sales-agent}

x-logging: &logging
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"

x-hardening: &hardening
  restart: unless-stopped
  logging: *logging
  security_opt:
    - no-new-privileges:true
  networks:
    - internal

services:
  gateway:
    <<: *hardening
    image: ${GATEWAY_IMAGE:?}
    ports:
      - "${APP_BIND_ADDRESS:-127.0.0.1}:${APP_PORT:-8080}:8080"
    volumes:
      - ./gateway/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    read_only: true
    tmpfs:
      - /tmp
    cap_drop: [ALL]
    depends_on:
      frontend:
        condition: service_healthy
      backend:
        condition: service_started
    healthcheck:
      test: ["CMD", "wget", "-q", "--spider", "http://127.0.0.1:8080/gateway-health"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 10s

  frontend:
    <<: *hardening
    image: ${FRONTEND_IMAGE:?}
    env_file:
      - ${SA_CONFIG_DIR:?}/frontend.env
    cap_drop: [ALL]

  backend:
    <<: *hardening
    image: ${BACKEND_IMAGE:?}
    env_file:
      - ${SA_CONFIG_DIR:?}/backend.env
    cap_drop: [ALL]
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - backend-outputs:/app/outputs
      - parlant-data:/app/parlant-data
      - backend-data:/app/data
    depends_on:
      db:
        condition: service_healthy
      mongo:
        condition: service_healthy
      redis:
        condition: service_healthy
      qdrant:
        condition: service_healthy
      storage-init:
        condition: service_completed_successfully
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=8)"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 900s

  db:
    <<: *hardening
    image: ${DB_IMAGE:?}
    environment:
      POSTGRES_USER: ${POSTGRES_USER:?}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?}
      POSTGRES_DB: ${POSTGRES_DB:?}
    volumes:
      - pg-data:/var/lib/postgresql/data
    shm_size: 256mb

  mongo:
    <<: *hardening
    image: ${MONGO_IMAGE:?}
    command: ["mongod", "--wiredTigerCacheSizeGB", "0.5"]
    environment:
      MONGO_INITDB_ROOT_USERNAME: ${MONGO_ROOT_USERNAME:?}
      MONGO_INITDB_ROOT_PASSWORD: ${MONGO_ROOT_PASSWORD:?}
    volumes:
      - mongo-data:/data/db
      - mongo-config:/data/configdb
    healthcheck:
      test: ["CMD", "mongosh", "--quiet", "--norc", "--eval", "db.adminCommand('ping').ok"]
      interval: 15s
      timeout: 10s
      retries: 10
      start_period: 30s

  redis:
    <<: *hardening
    image: ${REDIS_IMAGE:?}
    command: ["sh", "-c", "exec redis-server --appendonly yes --requirepass \"$$REDIS_PASSWORD\""]
    environment:
      REDIS_PASSWORD: ${REDIS_PASSWORD:?}
      REDISCLI_AUTH: ${REDIS_PASSWORD:?}
    volumes:
      - redis-data:/data
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 5s
      retries: 10

  qdrant:
    <<: *hardening
    image: ${QDRANT_IMAGE:?}
    environment:
      QDRANT__TELEMETRY_DISABLED: "true"
    volumes:
      - qdrant-data:/qdrant/storage
      - qdrant-snapshots:/qdrant/snapshots
    healthcheck:
      test: ["CMD", "bash", "-c", "exec 3<>/dev/tcp/127.0.0.1/6333 && printf 'GET /readyz HTTP/1.0\\r\\n\\r\\n' >&3 && grep -q '200 OK' <&3"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 20s

  rustfs:
    <<: *hardening
    image: ${RUSTFS_IMAGE:?}
    environment:
      RUSTFS_ACCESS_KEY: ${RUSTFS_ACCESS_KEY:?}
      RUSTFS_SECRET_KEY: ${RUSTFS_SECRET_KEY:?}
      RUSTFS_ADDRESS: ":9000"
      RUSTFS_CONSOLE_ENABLE: "false"
    volumes:
      - rustfs-data:/data
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://127.0.0.1:9000/health"]
      interval: 15s
      timeout: 5s
      retries: 10
      start_period: 15s

  storage-init:
    image: ${BACKEND_IMAGE:?}
    restart: "no"
    logging: *logging
    security_opt:
      - no-new-privileges:true
    cap_drop: [ALL]
    networks:
      - internal
    entrypoint: ["python", "/storage-init/init_storage.py"]
    healthcheck:
      disable: true
    environment:
      DOCUMENT_STORE: http://rustfs:9000
      DOCUMENT_STORE_USER: ${RUSTFS_ACCESS_KEY:?}
      DOCUMENT_STORE_PASSWORD: ${RUSTFS_SECRET_KEY:?}
      SEED_DIR: /seed
    volumes:
      - ./storage-init:/storage-init:ro
      - ${SA_SEED_DIR:-./storage-init/empty-seed}:/seed:ro
    depends_on:
      rustfs:
        condition: service_healthy

networks:
  internal:
    name: ${COMPOSE_PROJECT_NAME:-sales-agent}-internal

volumes:
  pg-data:
  mongo-data:
  mongo-config:
  redis-data:
  qdrant-data:
  qdrant-snapshots:
  rustfs-data:
  backend-outputs:
  parlant-data:
  backend-data:
'@

$script:Embedded['docker-compose.gpu.yml'] = @'
# Generated by Install-SalesAgent.ps1: NVIDIA GPU for the CUDA backend.
services:
  backend:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
'@

$script:Embedded['gateway/nginx.conf'] = @'
# Generated by Install-SalesAgent.ps1. One origin for the browser:
#   /eb-backend/* -> backend:8080 (SSE-safe)   /viewer/* -> rustfs:9000 (read-only)   /* -> frontend:8000
map $http_upgrade $connection_upgrade { default upgrade; '' ''; }
map $arg_sse $sse_accel { "true" "no"; default ""; }
map $request_uri $eb_backend_uri { "~^/eb-backend(?<eb_rest>/.*)$" $eb_rest; default /; }
map $request_uri $viewer_uri { "~^/viewer(?<viewer_rest>/.*)$" $viewer_rest; default /; }
resolver 127.0.0.11 valid=10s ipv6=off;

server {
    listen 8080;
    server_name _;
    server_tokens off;
    client_max_body_size 50M;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    location = /gateway-health { access_log off; default_type text/plain; return 200 "ok\n"; }

    location /eb-backend/ {
        set $backend_host backend:8080;
        proxy_pass http://$backend_host$eb_backend_uri;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        # Same-origin only: never let the backend's CORS rules grant other sites access.
        proxy_hide_header Access-Control-Allow-Origin;
        proxy_hide_header Access-Control-Allow-Credentials;
        proxy_hide_header Access-Control-Allow-Methods;
        proxy_hide_header Access-Control-Allow-Headers;
        proxy_hide_header Access-Control-Expose-Headers;
        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;
        proxy_read_timeout 1800s;
        proxy_send_timeout 1800s;
        add_header X-Accel-Buffering $sse_accel always;
        add_header Cache-Control "no-cache, no-transform" always;
    }

    location /viewer/ {
        limit_except GET HEAD { deny all; }
        set $rustfs_host rustfs:9000;
        proxy_pass http://$rustfs_host$viewer_uri;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host rustfs:9000;
        proxy_set_header Authorization "";
        proxy_set_header Cookie "";
        proxy_hide_header Set-Cookie;
        proxy_read_timeout 300s;
    }

    location / {
        set $frontend_host frontend:8000;
        proxy_pass http://$frontend_host$request_uri;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_read_timeout 300s;
    }
}
'@

$script:Embedded['storage-init/init_storage.py'] = @'
"""One-shot RustFS initialisation (idempotent): buckets, anonymous object
reads (served only through the gateway's read-only /viewer/), seed import."""
import json, os, sys, time
from pathlib import Path
import boto3
from botocore.client import Config
from botocore.exceptions import ClientError, EndpointConnectionError

BUCKETS = ["sales-proposal", "chat-uploads", "technical-repository-v2",
           os.getenv("DRAWING_BUCKET_NAME", "engine-drawings-v2"), "ui-assets", "data"]

def log(m): print(f"[storage-init] {m}", flush=True)

def main():
    s3 = boto3.client("s3", endpoint_url=os.environ["DOCUMENT_STORE"],
                      aws_access_key_id=os.environ["DOCUMENT_STORE_USER"],
                      aws_secret_access_key=os.environ["DOCUMENT_STORE_PASSWORD"], region_name="us-east-1",
                      config=Config(signature_version="s3v4", s3={"addressing_style": "path"}))
    deadline = time.time() + 120
    while True:
        try:
            s3.list_buckets(); break
        except (EndpointConnectionError, ClientError) as exc:
            if time.time() > deadline: raise SystemExit(f"RustFS not reachable: {exc}")
            time.sleep(2)
    existing = {b["Name"] for b in s3.list_buckets().get("Buckets", [])}
    for b in dict.fromkeys(BUCKETS):
        if b not in existing:
            s3.create_bucket(Bucket=b); log(f"created bucket {b}")
        s3.put_bucket_policy(Bucket=b, Policy=json.dumps({"Version": "2012-10-17", "Statement": [{
            "Sid": "PublicReadObjects", "Effect": "Allow", "Principal": {"AWS": ["*"]},
            "Action": ["s3:GetObject"], "Resource": [f"arn:aws:s3:::{b}/*"]}]}))
    log("buckets ready: " + ", ".join(dict.fromkeys(BUCKETS)))
    seed = Path(os.getenv("SEED_DIR", "/seed"))
    for bdir in sorted(p for p in seed.iterdir() if p.is_dir()) if seed.is_dir() else []:
        if bdir.name not in BUCKETS: log(f"seed: skipping unknown folder {bdir.name}"); continue
        up = skip = 0
        for f in sorted(p for p in bdir.rglob("*") if p.is_file()):
            key = f.relative_to(bdir).as_posix()
            try:
                s3.head_object(Bucket=bdir.name, Key=key); skip += 1; continue
            except ClientError as exc:
                if exc.response.get("Error", {}).get("Code") not in ("404", "NoSuchKey", "NotFound"): raise
            s3.upload_file(str(f), bdir.name, key); up += 1
        log(f"seed: {bdir.name}: uploaded {up}, already present {skip}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
'@
$script:Embedded['storage-init/empty-seed/.keep'] = ''

# =============================================================================
#  LOGGING (secrets are masked everywhere)
# =============================================================================
$script:LogFile = $null
$script:Secrets = [System.Collections.Generic.HashSet[string]]::new()
$script:Opt = @{ NonInteractive = [bool]$NonInteractive; AssumeYes = [bool]$Yes }

function Register-SASecret([AllowNull()][AllowEmptyString()][string]$Value) {
    if ($Value -and $Value.Length -ge 4 -and $Value -ne 'EMPTY') {
        [void]$script:Secrets.Add($Value)
        $enc = [Uri]::EscapeDataString($Value); if ($enc -ne $Value) { [void]$script:Secrets.Add($enc) }
    }
}

function Hide-SASecrets([AllowNull()][AllowEmptyString()][string]$Text) {
    if (-not $Text) { return $Text }
    $out = $Text
    foreach ($s in ($script:Secrets | Sort-Object Length -Descending)) { $out = $out.Replace($s, '********') }
    $out = [regex]::Replace($out, '(?im)^(\s*[A-Z0-9_]*(PASSWORD|SECRET|_KEY|TOKEN|PEPPER|HASH)[A-Z0-9_]*\s*=\s*)(.+)$', '$1********')
    return [regex]::Replace($out, '([a-z][a-z0-9+.-]*://[^:/@\s]+:)[^@\s/]+@', '$1********@')
}

function Write-SALog([ValidateSet('DEBUG', 'INFO', 'STEP', 'OK', 'WARN', 'ERROR')][string]$Level, [AllowEmptyString()][string]$Message) {
    $safe = Hide-SASecrets $Message
    if ($script:LogFile) {
        try { Add-Content -LiteralPath $script:LogFile -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss.fffzzz'), $Level, $safe) -Encoding utf8 -ErrorAction Stop }
        catch { $script:LogFile = $null }
    }
    switch ($Level) {
        'DEBUG' { }
        'STEP'  { Write-Host "`n==> $safe" -ForegroundColor Cyan }
        'OK'    { Write-Host "    [ok] $safe" -ForegroundColor Green }
        'WARN'  { Write-Host "    [warn] $safe" -ForegroundColor Yellow }
        'ERROR' { Write-Host "    [error] $safe" -ForegroundColor Red }
        default { Write-Host "    $safe" }
    }
}
function Write-SAStep([string]$m) { Write-SALog STEP $m }
function Write-SAInfo([string]$m) { Write-SALog INFO $m }
function Write-SAOk([string]$m) { Write-SALog OK $m }
function Write-SAWarn([string]$m) { Write-SALog WARN $m }
function Write-SAError([string]$m) { Write-SALog ERROR $m }

# =============================================================================
#  GENERAL HELPERS
# =============================================================================
function Get-SAPlatform { if ($IsWindows) { 'Windows' } elseif ($IsMacOS) { 'macOS' } elseif ($IsLinux) { 'Linux' } else { throw 'Unsupported OS' } }

function Get-SAPaths([string]$Dir) {
    if (-not $Dir) {
        $Dir = if ($env:SALES_AGENT_CONFIG_DIR) { $env:SALES_AGENT_CONFIG_DIR } else {
            switch (Get-SAPlatform) {
                'Windows' { Join-Path $env:LOCALAPPDATA 'SalesAgent' }
                'macOS'   { Join-Path $HOME 'Library/Application Support/SalesAgent' }
                'Linux'   { Join-Path ($env:XDG_CONFIG_HOME ? $env:XDG_CONFIG_HOME : (Join-Path $HOME '.config')) 'sales-agent' }
            }
        }
    }
    $Dir = [IO.Path]::GetFullPath($Dir)
    [pscustomobject]@{
        ConfigDir = $Dir; ConfigJson = Join-Path $Dir 'config.json'; ComposeEnv = Join-Path $Dir '.env'
        BackendEnv = Join-Path $Dir 'backend.env'; FrontendEnv = Join-Path $Dir 'frontend.env'; StateFile = Join-Path $Dir 'state.json'
        LogDir = Join-Path $Dir 'logs'; BackupDir = Join-Path $Dir 'backups'; RuntimeDir = Join-Path $Dir 'runtime'
        PreviousDir = Join-Path $Dir 'runtime.previous'; SeedDir = Join-Path $Dir 'seed'; LockFile = Join-Path $Dir '.lock'
    }
}

function Protect-SAFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    if ($IsWindows) {
        $acl = if ($isDir) { [System.Security.AccessControl.DirectorySecurity]::new() } else { [System.Security.AccessControl.FileSecurity]::new() }
        $acl.SetAccessRuleProtection($true, $false)
        $inherit = $isDir ? 'ContainerInherit,ObjectInherit' : 'None'
        foreach ($id in @([System.Security.Principal.WindowsIdentity]::GetCurrent().Name, 'NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators')) {
            $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($id, 'FullControl', $inherit, 'None', 'Allow'))
        }
        Set-Acl -LiteralPath $Path -AclObject $acl
    } else {
        & chmod ($isDir ? '700' : '600') $Path
    }
}

function New-SADirectory([string]$Path, [switch]$Private) {
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Force -Path $Path | Out-Null }
    if ($Private) { Protect-SAFile $Path }
}

function Write-SATextFile([string]$Path, [AllowEmptyString()][string]$Content, [switch]$Private) {
    New-SADirectory (Split-Path -Parent $Path)
    $tmp = "$Path.$([guid]::NewGuid().ToString('N').Substring(0, 8)).tmp"
    [IO.File]::WriteAllText($tmp, $Content, [Text.UTF8Encoding]::new($false))
    if ($Private) { Protect-SAFile $tmp }
    Move-Item -LiteralPath $tmp -Destination $Path -Force
    if ($Private) { Protect-SAFile $Path }
}

function Read-SAJson([string]$Path) { if (Test-Path -LiteralPath $Path) { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable } }
function Write-SAJson([string]$Path, $Data) { Write-SATextFile -Path $Path -Content ($Data | ConvertTo-Json -Depth 20) -Private }

function ConvertTo-SADotEnvValue($Value) {
    # Literal for Docker Compose: single quotes, or double quotes with \ " $ escaped.
    if ($null -eq $Value) { return "''" }
    $s = ($Value -is [bool]) ? ($Value ? 'true' : 'false') : [string]$Value
    if ($s -match "[\r\n]") { throw 'Multi-line values are not supported.' }
    if ($s -notmatch "'") { return "'$s'" }
    return '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace('$', '$$') + '"'
}

function Write-SADotEnv([string]$Path, [System.Collections.IDictionary]$Values) {
    $lines = @('# Generated by Install-SalesAgent.ps1 - do not edit. Contains secrets.')
    foreach ($k in $Values.Keys) {
        if ($k -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Invalid variable name '$k'" }
        $lines += "$k=$(ConvertTo-SADotEnvValue $Values[$k])"
    }
    Write-SATextFile -Path $Path -Content (($lines -join "`n") + "`n") -Private
}

function Read-SADotEnv([string]$Path) {
    $map = [ordered]@{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if ($line -notmatch '^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$') { continue }
        $k = $Matches[1]; $v = $Matches[2].Trim()
        if ($v.Length -ge 2 -and $v[0] -eq "'" -and $v[-1] -eq "'") { $v = $v.Substring(1, $v.Length - 2) }
        elseif ($v.Length -ge 2 -and $v[0] -eq '"' -and $v[-1] -eq '"') { $v = $v.Substring(1, $v.Length - 2).Replace('$$', '$').Replace('\"', '"').Replace('\\', '\') }
        elseif ($v.StartsWith('#')) { $v = '' }                  # 'KEY=   # comment' means empty
        elseif ($v -match '^(.*?)\s+#') { $v = $Matches[1].TrimEnd() }   # inline comment on unquoted values
        $map[$k] = $v
    }
    return $map
}

function Invoke-SANative {
    param([Parameter(Mandatory)][string]$FilePath, [string[]]$ArgumentList = @(), [switch]$AllowFailure, [switch]$Interactive, [string]$InputText)
    Write-SALog DEBUG ("exec: {0} {1}" -f $FilePath, ($ArgumentList -join ' '))
    if ($Interactive) {
        & $FilePath @ArgumentList | Out-Host
        $code = $LASTEXITCODE; $text = ''
    } else {
        $out = if ($PSBoundParameters.ContainsKey('InputText')) { $InputText | & $FilePath @ArgumentList 2>&1 } else { & $FilePath @ArgumentList 2>&1 }
        $code = $LASTEXITCODE
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        if ($text) { Write-SALog DEBUG $text }
    }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw (Hide-SASecrets ("'{0} {1}' failed (exit {2})`n{3}" -f $FilePath, ($ArgumentList -join ' '), $code, (($text -split "`n" | Select-Object -Last 20) -join "`n")))
    }
    [pscustomobject]@{ ExitCode = $code; Output = $text }
}

function Confirm-SAAction([string]$Question, [bool]$Default = $false) {
    if ($script:Opt.AssumeYes) { Write-SALog DEBUG "$Question -> yes (-Yes)"; return $true }
    if ($script:Opt.NonInteractive) { return $Default }
    $suffix = $Default ? '[Y/n]' : '[y/N]'
    while ($true) {
        $a = Read-Host "    $Question $suffix"
        if (-not $a) { return $Default }
        if ($a -match '^(y|yes)$') { return $true }
        if ($a -match '^(n|no)$') { return $false }
    }
}

function ConvertTo-SAVersion([string]$Text) {
    $m = [regex]::Match(("$Text").Trim().TrimStart('v'), '^\d+(\.\d+){0,3}')
    $n = @(($m.Success ? $m.Value : '0') -split '\.') + @('0', '0', '0', '0')
    [version]::new([int]$n[0], [int]$n[1], [int]$n[2], [int]$n[3])
}
function Compare-SAVersion([string]$A, [string]$B) { (ConvertTo-SAVersion $A).CompareTo((ConvertTo-SAVersion $B)) }

function New-SASecret([int]$Length = 32) {
    $chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'.ToCharArray()
    $sb = [Text.StringBuilder]::new()
    while ($sb.Length -lt $Length) {
        foreach ($b in [Security.Cryptography.RandomNumberGenerator]::GetBytes($Length)) { if ($b -lt 248 -and $sb.Length -lt $Length) { [void]$sb.Append($chars[$b % 62]) } }
    }
    $s = $sb.ToString(); Register-SASecret $s; return $s
}

function Get-SAState($Paths) { $s = Read-SAJson $Paths.StateFile; if (-not $s) { $s = @{} }; return $s }
function Save-SAState($Paths, [hashtable]$State) { $State['updatedAt'] = (Get-Date).ToString('o'); Write-SAJson $Paths.StateFile $State }

function Enter-SALock($Paths, [string]$Operation) {
    New-SADirectory $Paths.ConfigDir -Private
    if (Test-Path -LiteralPath $Paths.LockFile) {
        $i = Get-Content -Raw -LiteralPath $Paths.LockFile -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($i -and $i.pid -and $i.pid -ne $PID -and (Get-Process -Id $i.pid -ErrorAction SilentlyContinue)) { throw "Another Sales Agent '$($i.operation)' is running (PID $($i.pid))." }
    }
    @{ pid = $PID; operation = $Operation } | ConvertTo-Json | Set-Content -LiteralPath $Paths.LockFile
}
function Exit-SALock($Paths) { Remove-Item -LiteralPath $Paths.LockFile -Force -ErrorAction SilentlyContinue }

# =============================================================================
#  SYSTEM DETECTION
# =============================================================================
function Get-SACpuArchitecture {
    if ($IsMacOS -and "$(& sysctl -n hw.optional.arm64 2>$null)".Trim() -eq '1') { return 'arm64' }
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) { 'X64' { 'amd64' } 'Arm64' { 'arm64' } default { "$_".ToLower() } }
}

function Get-SAOsInfo {
    $i = [ordered]@{ Platform = Get-SAPlatform; Name = (Get-SAPlatform); Version = [Environment]::OSVersion.Version.ToString(); Distro = $null; DistroLike = $null }
    if ($IsWindows) { try { $o = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop; $i.Name = $o.Caption; $i.Version = $o.Version } catch { Write-SALog DEBUG $_.Exception.Message } }
    elseif ($IsMacOS) { $i.Name = 'macOS'; $v = & sw_vers -productVersion 2>$null; if ($v) { $i.Version = "$v".Trim() } }
    elseif (Test-Path /etc/os-release) {
        $kv = @{}; foreach ($l in Get-Content /etc/os-release) { if ($l -match '^([A-Z_]+)=(.*)$') { $kv[$Matches[1]] = $Matches[2].Trim('"') } }
        $i.Name = $kv['PRETTY_NAME'] ?? 'Linux'; $i.Distro = $kv['ID']; $i.DistroLike = $kv['ID_LIKE']; $i.Version = $kv['VERSION_ID']
    }
    [pscustomobject]$i
}

function Get-SAMemoryGB {
    try {
        $b = switch (Get-SAPlatform) {
            'Windows' { (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).TotalPhysicalMemory }
            'macOS'   { [long]("$(& sysctl -n hw.memsize)".Trim()) }
            'Linux'   { [long]((Select-String -Path /proc/meminfo -Pattern '^MemTotal:\s+(\d+)').Matches[0].Groups[1].Value) * 1KB }
        }
        [math]::Round($b / 1GB, 1)
    } catch { $null }
}

function Get-SAFreeDiskGB([string]$Path = $HOME) {
    try {
        $p = $Path; while ($p -and -not (Test-Path -LiteralPath $p)) { $p = Split-Path -Parent $p }
        if (-not $IsWindows) {
            $line = & df -Pk -- $p 2>$null | Select-Object -Last 1
            if ($line -match '\s(\d+)\s+\d+%\s') { return [math]::Round([long]$Matches[1] * 1KB / 1GB, 1) }
        }
        [math]::Round(([IO.DriveInfo]::new([IO.Path]::GetPathRoot([IO.Path]::GetFullPath($p)))).AvailableFreeSpace / 1GB, 1)
    } catch { $null }
}

function Get-SADockerInfo {
    $r = [ordered]@{ Installed = $false; CliVersion = $null; DaemonRunning = $false; DaemonError = $null; ServerVersion = $null; OSType = $null
        Architecture = $null; MemTotalGB = $null; NCPU = $null; Runtimes = @(); IsDockerDesktop = $false; ComposeVersion = $null }
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return [pscustomobject]$r }
    $r.Installed = $true
    $r.CliVersion = "$(& docker version --format '{{.Client.Version}}' 2>$null)".Trim()
    $json = & docker info --format '{{json .}}' 2>&1
    if ($LASTEXITCODE -eq 0) {
        try {
            $i = ($json | Out-String) | ConvertFrom-Json -AsHashtable
            if ($i.ServerErrors) { $r.DaemonError = ($i.ServerErrors -join '; ') }
            elseif ($i.ServerVersion) {
                $r.DaemonRunning = $true; $r.ServerVersion = $i.ServerVersion; $r.OSType = $i.OSType; $r.Architecture = $i.Architecture
                $r.NCPU = $i.NCPU; $r.MemTotalGB = [math]::Round([long]$i.MemTotal / 1GB, 1)
                $r.IsDockerDesktop = ("$($i.OperatingSystem)" -match 'Docker Desktop')
                if ($i.Runtimes) { $r.Runtimes = @($i.Runtimes.Keys) }
            }
        } catch { $r.DaemonError = 'unexpected docker info output' }
    } else { $r.DaemonError = (($json | Out-String).Trim() -split "`n" | Select-Object -Last 1) }
    $cv = & docker compose version --short 2>$null
    if ($LASTEXITCODE -eq 0 -and $cv) { $r.ComposeVersion = "$cv".Trim().TrimStart('v') }
    [pscustomobject]$r
}

function Test-SAPortAvailable([int]$Port, [string]$BindAddress = '0.0.0.0', [string]$OwnProject) {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        $rows = @(& docker ps --filter "publish=$Port" --format '{{.Label "com.docker.compose.project"}}' 2>$null | Where-Object { $_ -ne $null })
        if ($rows) { return [bool]($OwnProject -and -not ($rows | Where-Object { $_ -ne $OwnProject })) }
    }
    foreach ($addr in @($BindAddress, '127.0.0.1') | Select-Object -Unique) {
        $l = $null
        try { $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse($addr), $Port); $l.ExclusiveAddressUse = $true; $l.Start() }
        catch { return $false } finally { if ($l) { $l.Stop() } }
    }
    return $true
}

function Find-SAFreePort([int]$Start, [string]$BindAddress) {
    for ($p = $Start; $p -lt $Start + 50; $p++) { if (Test-SAPortAvailable -Port $p -BindAddress $BindAddress) { return $p } }
}

function Test-SATcpEndpoint([string]$HostName, [int]$Port, [int]$TimeoutMs = 3000) {
    $c = [System.Net.Sockets.TcpClient]::new()
    try { $t = $c.ConnectAsync($HostName, $Port); return ($t.Wait($TimeoutMs) -and $c.Connected) } catch { return $false } finally { $c.Dispose() }
}

# =============================================================================
#  DOCKER INSTALLATION / START (always asks before changing the system)
# =============================================================================
function Start-SADockerDaemon {
    switch (Get-SAPlatform) {
        'macOS' { if (Test-Path '/Applications/Docker.app') { & open -a Docker; return $true }; return $false }
        'Windows' {
            foreach ($root in @($env:ProgramFiles, $env:LOCALAPPDATA)) {
                $exe = $root ? (Join-Path $root 'Docker\Docker\Docker Desktop.exe') : $null
                if ($exe -and (Test-Path -LiteralPath $exe)) { Start-Process -FilePath $exe | Out-Null; return $true }
            }
            return $false
        }
        'Linux' {
            if (-not (Get-Command systemctl -ErrorAction SilentlyContinue)) { return $false }
            if ("$(& systemctl --user list-unit-files docker-desktop.service 2>$null)" -match 'docker-desktop') { & systemctl --user start docker-desktop; return $true }
            if (Confirm-SAAction 'Start the Docker service now (sudo systemctl enable --now docker)?' $true) { & sudo systemctl enable --now docker; return $true }
            return $false
        }
    }
}

function Wait-SADockerReady([int]$TimeoutSec = 240) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    Write-Host '    Waiting for Docker to become ready' -NoNewline
    try {
        while ((Get-Date) -lt $deadline) {
            & docker info --format '{{.ServerVersion}}' *> $null
            if ($LASTEXITCODE -eq 0) { return $true }
            Write-Host '.' -NoNewline; Start-Sleep -Seconds 3
        }
        return $false
    } finally { Write-Host '' }
}

function Install-SADocker($Os) {
    switch ($Os.Platform) {
        'Windows' {
            if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-SAWarn 'Install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/'; return $false }
            if (-not (Confirm-SAAction 'Install WSL 2 and Docker Desktop now (administrator rights; a restart may be needed)?' $false)) { return $false }
            & wsl.exe --status *> $null
            if ($LASTEXITCODE -ne 0) { Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait }
            Invoke-SANative winget @('install', '--id', 'Docker.DockerDesktop', '-e', '--accept-package-agreements', '--accept-source-agreements') -Interactive | Out-Null
            Write-SAWarn 'If Windows asks for a restart: restart, then run the installer again (it resumes).'
            $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
            return [bool](Get-Command docker -ErrorAction SilentlyContinue)
        }
        'macOS' {
            if ((Get-Command brew -ErrorAction SilentlyContinue) -and (Confirm-SAAction 'Install Docker Desktop with Homebrew (brew install --cask docker)?' $false)) {
                Invoke-SANative brew @('install', '--cask', 'docker') -Interactive | Out-Null; & open -a Docker; return $true
            }
            $arch = Get-SACpuArchitecture
            Write-SAWarn "Install Docker Desktop from https://desktop.docker.com/mac/main/$arch/Docker.dmg, start it once, then run the installer again."
            return $false
        }
        'Linux' {
            $id = "$($Os.Distro)"; $like = "$($Os.DistroLike)"
            $apt = $id -in 'ubuntu', 'debian' -or $like -match 'debian|ubuntu'
            $dnf = $id -in 'fedora', 'rhel', 'centos', 'rocky', 'almalinux' -or $like -match 'rhel|fedora|centos'
            if (-not ($apt -or $dnf)) { Write-SAWarn "Install Docker Engine: https://docs.docker.com/engine/install/ (unsupported distribution '$id')."; return $false }
            if (-not (Confirm-SAAction "Install Docker Engine + Compose plugin from Docker's official repository (uses sudo)?" $false)) { return $false }
            $repo = if ($id -in 'ubuntu', 'debian', 'fedora', 'rhel', 'centos') { $id } elseif ($like -match 'ubuntu') { 'ubuntu' } elseif ($like -match 'debian') { 'debian' } else { 'rhel' }
            $sh = if ($apt) {
@"
set -e
sudo apt-get update && sudo apt-get install -y ca-certificates curl
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/$repo/gpg -o /etc/apt/keyrings/docker.asc && sudo chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=`$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$repo `${UBUNTU_CODENAME:-`$VERSION_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
"@ } else {
@"
set -e
sudo dnf -y install dnf-plugins-core
sudo dnf config-manager --add-repo https://download.docker.com/linux/$repo/docker-ce.repo || sudo dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/$repo/docker-ce.repo
sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker
"@ }
            Invoke-SANative bash @('-c', $sh) -Interactive | Out-Null
            if ($env:USER -and $env:USER -ne 'root' -and (Confirm-SAAction "Allow '$($env:USER)' to use Docker without sudo (adds you to the 'docker' group)?" $true)) {
                & sudo usermod -aG docker $env:USER
                Write-SAWarn "Log out and back in (or run 'newgrp docker'), then run the installer again."
            }
            return [bool](Get-Command docker -ErrorAction SilentlyContinue)
        }
    }
}

function Assert-SADockerReady($Os, [switch]$NoInstall) {
    $d = Get-SADockerInfo
    if (-not $d.Installed) {
        Write-SAWarn 'Docker is not installed.'
        if ($NoInstall -or -not (Install-SADocker $Os)) { throw 'Docker is required. Install it (see above) and run the installer again.' }
        $d = Get-SADockerInfo
    }
    if (-not $d.DaemonRunning) {
        if ($d.DaemonError -match 'permission denied') { throw "Your user cannot use Docker. Run: sudo usermod -aG docker `$USER, log out and in, then retry." }
        Write-SAWarn 'Docker is not running; starting it.'
        if (-not (Start-SADockerDaemon)) { throw 'Start Docker (Docker Desktop or the docker service) and run the installer again.' }
        if (-not (Wait-SADockerReady)) { throw 'Docker did not become ready within 4 minutes. Start it manually and retry.' }
        $d = Get-SADockerInfo
    }
    if ($d.OSType -and $d.OSType -ne 'linux') { throw "Docker is in '$($d.OSType)' containers mode. Switch Docker Desktop to Linux containers." }
    Write-SAOk "Docker $($d.ServerVersion) is running"
    return $d
}

# =============================================================================
#  GPU
# =============================================================================
function Get-SAGpuInfo($Docker) {
    $g = [ordered]@{ HasNvidia = $false; Name = $null; Driver = $null; CudaVersion = $null; Eligible = $false; Reason = $null }
    if ($IsMacOS) { $g.Reason = 'Docker on macOS cannot use a GPU; the CPU build is used.'; return [pscustomobject]$g }
    if ($Docker.Architecture -and $Docker.Architecture -notmatch '^(x86_64|amd64)$') { $g.Reason = "The GPU build is x86_64 only (Docker: $($Docker.Architecture))."; return [pscustomobject]$g }
    if (-not (Get-Command nvidia-smi -ErrorAction SilentlyContinue)) { $g.Reason = 'No NVIDIA GPU detected.'; return [pscustomobject]$g }
    $q = & nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>$null | Select-Object -First 1
    $full = (& nvidia-smi 2>$null | Out-String)
    if (-not $q) { $g.Reason = 'nvidia-smi reported no GPU (driver problem?).'; return [pscustomobject]$g }
    $p = "$q".Split(','); $g.HasNvidia = $true; $g.Name = $p[0].Trim(); if ($p.Count -gt 1) { $g.Driver = $p[1].Trim() }
    if ($full -match 'CUDA Version:\s*([0-9]+\.[0-9]+)') { $g.CudaVersion = [version]$Matches[1] }
    $runtime = ($Docker.Runtimes -contains 'nvidia') -or $Docker.IsDockerDesktop
    if (-not $g.CudaVersion -or $g.CudaVersion -lt [version]$script:Release.Requirements.CudaMin) { $g.Reason = "Driver supports CUDA $($g.CudaVersion ?? '?'); $($script:Release.Requirements.CudaMin)+ is needed. Update the NVIDIA driver to use the GPU." }
    elseif (-not $runtime) { $g.Reason = 'Docker has no NVIDIA runtime: install the NVIDIA Container Toolkit (https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html).' }
    else { $g.Eligible = $true }
    [pscustomobject]$g
}

function Select-SAVariant([string]$Requested, $Gpu) {
    if ($Gpu.HasNvidia) { Write-SAInfo "NVIDIA GPU : $($Gpu.Name) (driver $($Gpu.Driver), CUDA $($Gpu.CudaVersion))" }
    if ($Gpu.Reason) { Write-SAInfo "GPU note   : $($Gpu.Reason)" }
    switch ($Requested) {
        'cpu'  { return 'cpu' }
        'cuda' { if ($IsMacOS) { throw 'The GPU (CUDA) build is not available on macOS.' }; if (-not $Gpu.Eligible) { Write-SAWarn "GPU requested although: $($Gpu.Reason)" }; return 'cuda' }
        default { return ($Gpu.Eligible ? 'cuda' : 'cpu') }
    }
}

# =============================================================================
#  CONFIGURATION
# =============================================================================
function Test-SAValue($Def, $Value) {
    $fail = { param($m) @{ Ok = $false; Value = $Value; Error = "$($Def.Name): $m" } }
    if ($null -eq $Value -or ($Value -is [string] -and $Value -eq '')) {
        if ($Def.Required) { return (& $fail 'a value is required') }
        return @{ Ok = $true; Value = $null }
    }
    if ("$Value" -match '^\s*=') { return (& $fail "starts with '=' - check for a doubled '=' (KEY==value)") }
    if ("$Value" -match '^\s*<[^>]+>\s*$|PASTE_YOUR|YOUR_[A-Z_]*HERE') { return (& $fail 'still contains a placeholder - replace it with the real value') }
    $v = $Value
    switch ($Def.Type) {
        'int'  { $n = 0; if ($v -is [bool] -or -not [int]::TryParse("$v", [ref]$n)) { return (& $fail "'$v' is not a whole number") }; $v = $n }
        'port' { $n = 0; if ($v -is [bool] -or -not [int]::TryParse("$v", [ref]$n) -or $n -lt 1 -or $n -gt 65535) { return (& $fail "'$v' is not a port (1-65535)") }; $v = $n }
        'bool' {
            if ($v -isnot [bool]) {
                if ("$v".Trim() -match '^(true|yes|y|1|on)$') { $v = $true } elseif ("$v".Trim() -match '^(false|no|n|0|off)$') { $v = $false } else { return (& $fail "'$v' is not true/false") }
            }
        }
        'url'  { $v = "$v".Trim(); $u = $null; if (-not [Uri]::TryCreate($v, 'Absolute', [ref]$u) -or $u.Scheme -notin 'http', 'https' -or -not $u.Host) { return (& $fail "'$v' is not an http(s) URL") } }
        'email' { $v = "$v".Trim(); if ($v -notmatch '^[^@\s]+@[^@\s]+$') { return (& $fail "'$v' is not an e-mail address") } }
        'host' { $v = "$v".Trim(); if ($v -notmatch '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$' -and $v -notmatch '^\[?[0-9A-Fa-f:]+\]?$') { return (& $fail "'$v' is not a host name or IP") } }
        'path' { $v = "$v".Trim(); if (-not (Test-Path -LiteralPath $v)) { return (& $fail "'$v' does not exist") }; $v = (Resolve-Path -LiteralPath $v).Path }
        default { $v = "$v"; if ($v -match "[\r\n]") { return (& $fail 'must be one line') } }
    }
    if ($Def.Enum -and "$v" -notin $Def.Enum) { return (& $fail "must be one of: $($Def.Enum -join ', ')") }
    if ($Def.Pattern -and $v -is [string] -and $v -notmatch $Def.Pattern) { return (& $fail 'has an invalid format') }
    if ($Def.MinLength -and $v -is [string] -and $v.Length -lt $Def.MinLength) { return (& $fail "needs at least $($Def.MinLength) characters") }
    @{ Ok = $true; Value = $v }
}

function Get-SADefaultEnvFile { Join-Path $PSScriptRoot 'sales-agent.env' }

function New-SAEnvTemplate([string]$Path) {
    $groups = [ordered]@{
        llm = 'Required: OpenAI-compatible LLM'; gemini = 'Required: Google Gemini'; admin = 'Required: administrator account'
        installer = 'Installation (optional)'; ollama = 'Optional: Ollama (set OLLAMA_BASE_URL to enable)'
        translation = 'Optional: translation LLM (set TRANSLATION_API_URL to enable)'; vlm = 'Optional: vision LLM (set VLM_URL to enable)'
        oracle = 'Optional: Oracle (set ORACLE_DB_URL to enable)'; mssql = 'Optional: iKonnect MSSQL (set IKONNECT_MSSQL_DB_HOST to enable)'
        ldap = 'Optional: LDAP / Active Directory (set LDAP_HOST to enable)'; smtp = 'Optional: SMTP relay for one-time login codes (set SMTP_HOST to enable)'
        auth = 'Advanced: sessions and cookies'; core = 'Advanced: application'
    }
    $lines = @(
        '# Sales Agent settings. Fill in the REQUIRED values, then run the installer.'
        '# Empty values keep the current value (or the default); "-" clears a value (e.g. KEY=- switches an integration off).'
        '# SYSTEM_ADMIN_PASSWORD is hashed during installation and then removed from this file.'
        '# Use http://host.docker.internal:<port> for services running on this computer.'
    )
    foreach ($g in $groups.Keys) {
        $defs = @($script:Settings | Where-Object Group -eq $g)
        if (-not $defs) { continue }
        $lines += ''; $lines += "# ---- $($groups[$g]) ----"
        foreach ($d in $defs) {
            $hint = @(($d.Required -and $d.Group -notin 'installer') ? 'REQUIRED' : 'optional')
            if ($d.Enum) { $hint += ($d.Enum -join '|') }
            if ($null -ne $d.Default) { $hint += "default: $(($d.Default -is [bool]) ? ($d.Default ? 'true' : 'false') : $d.Default)" }
            if ($d.Prompt -ne $d.Name) { $lines += "# $($d.Prompt)" }
            $lines += "$($d.Name)=" + "                # $($hint -join '; ')"
        }
    }
    Write-SATextFile -Path $Path -Content (($lines -join "`n") + "`n") -Private
}

function Read-SAPromptValue($Def, $Default) {
    while ($true) {
        if ($Def.Type -eq 'secret') {
            $raw = [Net.NetworkCredential]::new('', (Read-Host "    $($Def.Prompt)$($Default ? ' (Enter = default)' : '')" -AsSecureString)).Password
            if (-not $raw -and $Default) { $raw = $Default }
            if ($Def.Name -eq 'SYSTEM_ADMIN_PASSWORD' -and $raw) {
                $again = [Net.NetworkCredential]::new('', (Read-Host '    Repeat the password' -AsSecureString)).Password
                if ($again -cne $raw) { Write-Host '    The passwords do not match.' -ForegroundColor Yellow; continue }
            }
        } else {
            $shown = if ($null -ne $Default -and "$Default" -ne '') { " [$Default]" } else { '' }
            $raw = Read-Host "    $($Def.Prompt)$shown"
            if ($raw -eq '' -and $null -ne $Default) { $raw = $Default }
        }
        $r = Test-SAValue $Def $raw
        if ($r.Ok) { if ($Def.Type -eq 'secret') { Register-SASecret "$($r.Value)" }; return $r.Value }
        Write-Host "    $($r.Error)" -ForegroundColor Yellow
    }
}

function Test-SAGroupEnabled([hashtable]$Values, [string]$Group) {
    if (-not $script:OptionalGroups.Contains($Group)) { return $true }
    return [bool]$Values[$script:OptionalGroups[$Group]]
}

function Resolve-SAConfiguration {
    <#
      Merge: saved config (config.json) <- sales-agent.env <- prompts/defaults.
      Changed values from the file need confirmation. Returns @{ Config; PendingPassword; Changes }.
    #>
    param([hashtable]$Saved, [System.Collections.IDictionary]$FileValues, [hashtable]$Overrides = @{})
    $interactive = -not $script:Opt.NonInteractive
    $cfg = if ($Saved) { $Saved | ConvertTo-Json -Depth 10 | ConvertFrom-Json -AsHashtable } else { @{} }
    foreach ($s in 'values', 'internal') { if (-not $cfg[$s]) { $cfg[$s] = @{} } }
    $vals = $cfg.values
    $changes = [System.Collections.Generic.List[string]]::new()
    $pendingPassword = $null
    $missing = [System.Collections.Generic.List[string]]::new()

    # 1. values from the file (validated); changed values need confirmation
    $proposed = @{}
    $clear = [System.Collections.Generic.List[string]]::new()
    foreach ($def in $script:Settings) {
        if (-not $FileValues.Contains($def.Name)) { continue }
        $raw = $FileValues[$def.Name]
        if ("$raw".Trim() -eq '') { continue }
        if ("$raw".Trim() -eq '-') {            # '-' clears a stored value (e.g. switches an integration off)
            if ($def.Required) { throw "sales-agent.env: $($def.Name) is required and cannot be cleared." }
            if ($null -ne $vals[$def.Name]) { $clear.Add($def.Name) }
            continue
        }
        $r = Test-SAValue $def $raw
        if (-not $r.Ok) { throw "sales-agent.env: $($r.Error)" }
        if ($def.Type -eq 'secret') { Register-SASecret "$($r.Value)" }
        $proposed[$def.Name] = $r.Value
    }
    foreach ($k in $Overrides.Keys) { if ($null -ne $Overrides[$k]) { $proposed[$k] = $Overrides[$k] } }
    if ($proposed.ContainsKey('SYSTEM_ADMIN_PASSWORD')) {
        $pendingPassword = $proposed['SYSTEM_ADMIN_PASSWORD']; $proposed.Remove('SYSTEM_ADMIN_PASSWORD')
        if ($vals.SYSTEM_ADMIN_PASSWORD_HASH) { $changes.Add('SYSTEM_ADMIN_PASSWORD') }
    }
    foreach ($k in $proposed.Keys) {
        $old = $vals[$k]
        if ($null -ne $old -and "$old" -ne "$($proposed[$k])") { $changes.Add($k) }
        elseif ($null -eq $old) { $vals[$k] = $proposed[$k] }
    }
    foreach ($k in $clear) { $changes.Add($k); $proposed[$k] = $null }
    if ($changes.Count) {
        $secretNames = @($script:Settings | Where-Object Type -eq 'secret' | ForEach-Object Name)
        Write-SAStep 'Changed settings in sales-agent.env'
        foreach ($k in $changes) {
            $shownOld = ($k -in $secretNames) ? '********' : "$($vals[$k])"
            $shownNew = ($null -eq $proposed[$k]) ? '(cleared)' : (($k -in $secretNames) ? '********' : "$($proposed[$k])")
            Write-SAInfo ("{0}: {1} -> {2}" -f $k, $shownOld, $shownNew)
        }
        if (Confirm-SAAction 'Apply these changes?' $false) {
            foreach ($k in $changes) {
                if ($k -eq 'SYSTEM_ADMIN_PASSWORD') { continue }
                if ($null -eq $proposed[$k]) { $vals.Remove($k) } else { $vals[$k] = $proposed[$k] }
            }
        } else {
            Write-SAWarn 'Keeping the current configuration (use -Yes to apply file changes unattended).'
            if ($changes -contains 'SYSTEM_ADMIN_PASSWORD') { $pendingPassword = $null }
            $changes.Clear()
        }
    }

    # 2. fill what is still missing
    $header = $false
    foreach ($def in $script:Settings) {
        if ($def.Name -eq 'SYSTEM_ADMIN_PASSWORD') {
            if ($vals.SYSTEM_ADMIN_PASSWORD_HASH -or $pendingPassword) { continue }
            if ($env:SALES_AGENT_ADMIN_PASSWORD) { $pendingPassword = $env:SALES_AGENT_ADMIN_PASSWORD; Register-SASecret $pendingPassword; continue }
            if ($interactive) { if (-not $header) { Write-SAStep 'Please enter the missing settings'; $header = $true }; $pendingPassword = Read-SAPromptValue $def $null }
            else { $missing.Add('SYSTEM_ADMIN_PASSWORD') }
            continue
        }
        if (-not (Test-SAGroupEnabled $vals $def.Group)) { continue }
        if ($null -ne $vals[$def.Name] -and "$($vals[$def.Name])" -ne '') { continue }
        $optionalGroup = $script:OptionalGroups.Contains($def.Group)
        $required = $def.Required -or ($optionalGroup -and -not $def.Advanced -and $null -eq $def.Default)
        if ($null -ne $def.Default -and (-not $def.Required -or $def.Name -in 'OPENAI_API_KEY', 'SYSTEM_ADMIN_USERNAME') -and -not ($interactive -and $def.Required)) {
            $vals[$def.Name] = $def.Default; continue
        }
        if (-not $required) { continue }
        if ($interactive) {
            if (-not $header) { Write-SAStep 'Please enter the missing settings'; $header = $true }
            $vals[$def.Name] = Read-SAPromptValue ($def | Select-Object *, @{ n = 'Required'; e = { $true } } -ExcludeProperty Required) $def.Default
        } else { $missing.Add($def.Name) }
    }
    if ($missing.Count) { throw "Missing settings: $($missing -join ', '). Fill them in sales-agent.env and run the installer again." }
    if ($vals.COOKIE_SAMESITE -eq 'none' -and -not $vals.COOKIE_SECURE) { throw 'COOKIE_SAMESITE=none requires COOKIE_SECURE=true (HTTPS only).' }

    # 3. generated secrets (never prompted, never changed)
    $gen = @{ POSTGRES_PASSWORD = 32; MONGO_ROOT_PASSWORD = 32; REDIS_PASSWORD = 32; RUSTFS_ACCESS_KEY = 20; RUSTFS_SECRET_KEY = 40; SECRET_KEY = 64; OTP_PEPPER = 32 }
    foreach ($k in $gen.Keys) { if (-not $cfg.internal[$k]) { $cfg.internal[$k] = New-SASecret $gen[$k] } }
    foreach ($k in 'POSTGRES_USER', 'POSTGRES_DB', 'MONGO_ROOT_USERNAME') { if (-not $cfg.internal[$k]) { $cfg.internal[$k] = 'sales_agent' } }
    $cfg.configVersion = $script:Release.ConfigVersion
    Register-SAConfigSecrets $cfg
    @{ Config = $cfg; PendingPassword = $pendingPassword; Changes = $changes }
}

function Register-SAConfigSecrets([hashtable]$Config) {
    foreach ($v in $Config.internal.Values) { Register-SASecret "$v" }
    foreach ($d in ($script:Settings | Where-Object Type -eq 'secret')) { if ($Config.values[$d.Name]) { Register-SASecret "$($Config.values[$d.Name])" } }
    if ($Config.values.SYSTEM_ADMIN_PASSWORD_HASH) { Register-SASecret $Config.values.SYSTEM_ADMIN_PASSWORD_HASH }
}

function Get-SAPublicBaseUrl([hashtable]$Config) {
    $v = $Config.values
    if ($v.PUBLIC_BASE_URL) { return ([string]$v.PUBLIC_BASE_URL).TrimEnd('/') }
    $port = [int]($v.APP_PORT ?? 8080)
    $h = $v.PUBLIC_HOST ?? 'localhost'
    return ($port -eq 80) ? "http://$h" : "http://${h}:$port"
}

function ConvertTo-SAEnvString($v) { if ($v -is [bool]) { $v ? 'true' : 'false' } else { "$v" } }

function Get-SAEnvironmentFiles([hashtable]$Config, [hashtable]$Images, $Paths) {
    $v = $Config.values; $i = $Config.internal
    $enc = { param($s) [Uri]::EscapeDataString("$s") }
    $base = Get-SAPublicBaseUrl $Config
    $compose = [ordered]@{
        COMPOSE_PROJECT_NAME = 'sales-agent'; SA_CONFIG_DIR = $Paths.ConfigDir
        APP_PORT = "$($v.APP_PORT ?? 8080)"; APP_BIND_ADDRESS = $v.BIND_ADDRESS ?? '127.0.0.1'
        FRONTEND_IMAGE = $Images.frontend; BACKEND_IMAGE = $Images.backend; DB_IMAGE = $Images.db
        GATEWAY_IMAGE = $script:Release.ThirdParty.gateway; MONGO_IMAGE = $script:Release.ThirdParty.mongo; REDIS_IMAGE = $script:Release.ThirdParty.redis
        QDRANT_IMAGE = $script:Release.ThirdParty.qdrant; RUSTFS_IMAGE = $script:Release.ThirdParty.rustfs
        POSTGRES_USER = $i.POSTGRES_USER; POSTGRES_DB = $i.POSTGRES_DB; POSTGRES_PASSWORD = $i.POSTGRES_PASSWORD
        MONGO_ROOT_USERNAME = $i.MONGO_ROOT_USERNAME; MONGO_ROOT_PASSWORD = $i.MONGO_ROOT_PASSWORD; REDIS_PASSWORD = $i.REDIS_PASSWORD
        RUSTFS_ACCESS_KEY = $i.RUSTFS_ACCESS_KEY; RUSTFS_SECRET_KEY = $i.RUSTFS_SECRET_KEY
    }
    if (Test-Path -LiteralPath $Paths.SeedDir) { $compose['SA_SEED_DIR'] = $Paths.SeedDir }

    $backend = [ordered]@{}
    $frontend = [ordered]@{ BACKEND_INTERNAL_URL = 'http://backend:8080' }
    foreach ($def in $script:Settings) {
        if ($def.Target -eq 'installer' -or $def.Name -eq 'SYSTEM_ADMIN_PASSWORD') { continue }
        if (-not (Test-SAGroupEnabled $v $def.Group)) { continue }
        $val = $v[$def.Name]
        if ($null -eq $val -or "$val" -eq '') { continue }
        $backend[$def.Name] = ConvertTo-SAEnvString $val
        if ($def.Target -eq 'both') { $frontend[$def.Name] = ConvertTo-SAEnvString $val }
    }
    foreach ($g in $script:OptionalGroups.Keys) {
        if (-not (Test-SAGroupEnabled $v $g)) { foreach ($k in $script:DisabledGroupValues[$g].Keys) { $backend[$k] = $script:DisabledGroupValues[$g][$k] } }
    }
    $pgUrl = "$(& $enc $i.POSTGRES_USER):$(& $enc $i.POSTGRES_PASSWORD)@db:5432/$($i.POSTGRES_DB)"
    $derived = [ordered]@{
        ENV = 'production'; PORT = '8080'; TOOL_SERVICE_PORT = '8818'
        SYSTEM_ADMIN_PASSWORD_HASH = $v.SYSTEM_ADMIN_PASSWORD_HASH
        SECRET_KEY = $i.SECRET_KEY; OTP_PEPPER = $i.OTP_PEPPER
        DATABASE_URL = "postgresql+asyncpg://$pgUrl"; LOGIN_DATABASE_URL = "postgresql://$pgUrl"; POSTGRE_SCHEMA_LOGIN = 'auth'
        PG_HOST = 'db'; PG_PORT = '5432'; PG_DB = $i.POSTGRES_DB; PG_USER = $i.POSTGRES_USER; PG_PASSWORD = $i.POSTGRES_PASSWORD
        MONGO_URI = "mongodb://$(& $enc $i.MONGO_ROOT_USERNAME):$(& $enc $i.MONGO_ROOT_PASSWORD)@mongo:27017/?authSource=admin"
        REDIS_HOST = 'redis'; REDIS_PORT = '6379'; REDIS_DB = '1'; REDIS_PASSWORD = $i.REDIS_PASSWORD
        QDRANT_URL = 'http://qdrant:6333'
        DOCUMENT_STORE = 'http://rustfs:9000'; DOCUMENT_STORE_USER = $i.RUSTFS_ACCESS_KEY; DOCUMENT_STORE_PASSWORD = $i.RUSTFS_SECRET_KEY
        DRAWING_BUCKET_NAME = 'engine-drawings-v2'; RUSTFS_VIEWER_URL = "$base/viewer"
        FRONTEND_URL = $base; BACKEND_URL = "$base/eb-backend"; ABSOLUTE_BACKEND_URL = "$base/eb-backend"
        GOOGLE_API_KEY = $v.GEMINI_API_KEY; SERVICE_AGENT_ROOT = '/data/service_agent'
    }
    foreach ($k in $derived.Keys) { $backend[$k] = $derived[$k] }
    if (-not $backend.Contains('QWEN_MODEL_NAME')) { $backend['QWEN_MODEL_NAME'] = $v.LITELLM_PROVIDER_MODEL_NAME }
    if (-not $backend.Contains('LITELLM_PROVIDER_API_KEY')) { $backend['LITELLM_PROVIDER_API_KEY'] = $v.OPENAI_API_KEY }
    foreach ($x in $backend.Values) { if ("$x" -match '://[^:/@]+:[^@]+@') { Register-SASecret "$x" } }
    @{ Compose = $compose; Backend = $backend; Frontend = $frontend }
}

function Export-SAConfiguration([hashtable]$Config, [hashtable]$Images, $Paths) {
    New-SADirectory $Paths.ConfigDir -Private
    $f = Get-SAEnvironmentFiles $Config $Images $Paths
    Write-SAJson $Paths.ConfigJson $Config
    Write-SADotEnv $Paths.ComposeEnv $f.Compose
    Write-SADotEnv $Paths.BackendEnv $f.Backend
    Write-SADotEnv $Paths.FrontendEnv $f.Frontend
    Write-SAOk "configuration saved in $($Paths.ConfigDir) (readable only by you)"
}

function Remove-SAPasswordFromEnvFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $lines = [IO.File]::ReadAllLines($Path)
    $changed = $false
    for ($n = 0; $n -lt $lines.Count; $n++) {
        if ($lines[$n] -match '^\s*SYSTEM_ADMIN_PASSWORD\s*=\s*\S') { $lines[$n] = 'SYSTEM_ADMIN_PASSWORD=                # stored as a hash; set a value here only to change it'; $changed = $true }
    }
    if ($changed) { [IO.File]::WriteAllLines($Path, $lines); Write-SAOk 'administrator password removed from sales-agent.env (only its hash is stored)' }
}

function Set-SAAdminPasswordHash([hashtable]$Config, [string]$Password, [string]$BackendImage) {
    $code = 'import bcrypt,sys; pw=sys.stdin.buffer.read().rstrip(b"\r\n"); print(bcrypt.hashpw(pw, bcrypt.gensalt(12)).decode())'
    $r = Invoke-SANative docker @('run', '--rm', '-i', '--network', 'none', '--entrypoint', 'python', $BackendImage, '-c', $code) -InputText $Password
    $hash = $r.Output -split "`n" | Where-Object { $_ -match '^\$2[aby]\$' } | Select-Object -Last 1
    if (-not $hash) { throw 'Could not hash the administrator password.' }
    $Config.values.SYSTEM_ADMIN_PASSWORD_HASH = $hash.Trim(); Register-SASecret $hash.Trim()
}

function Test-SAExternalEndpoints([hashtable]$Config) {
    $v = $Config.values
    $t = [System.Collections.Generic.List[object]]::new()
    $addUrl = { param($label, $url) if ($url) { $u = [Uri]$url; $t.Add(@{ L = $label; H = $u.Host; P = ($u.IsDefaultPort ? (($u.Scheme -eq 'https') ? 443 : 80) : $u.Port) }) } }
    & $addUrl 'LLM endpoint (OPENAI_API_BASE)' $v.OPENAI_API_BASE
    $t.Add(@{ L = 'Google Gemini API'; H = 'generativelanguage.googleapis.com'; P = 443 })
    if (Test-SAGroupEnabled $v ollama) { & $addUrl 'Ollama' $v.OLLAMA_BASE_URL }
    if (Test-SAGroupEnabled $v translation) { & $addUrl 'Translation LLM' $v.TRANSLATION_API_URL }
    if (Test-SAGroupEnabled $v vlm) { & $addUrl 'Vision LLM' $v.VLM_URL }
    if (Test-SAGroupEnabled $v ldap) { $t.Add(@{ L = 'LDAP'; H = $v.LDAP_HOST; P = [int]$v.LDAP_PORT }) }
    if (Test-SAGroupEnabled $v smtp) { $t.Add(@{ L = 'SMTP'; H = $v.SMTP_HOST; P = [int]$v.SMTP_PORT }) }
    if (Test-SAGroupEnabled $v mssql) { $t.Add(@{ L = 'MSSQL'; H = $v.IKONNECT_MSSQL_DB_HOST; P = [int]$v.IKONNECT_MSSQL_DB_PORT }) }
    foreach ($x in $t) {
        if ($x.H -in 'localhost', '127.0.0.1', '::1') { Write-SAWarn "$($x.L) uses '$($x.H)', which inside a container is the container itself; use host.docker.internal." }
        $probe = ($x.H -eq 'host.docker.internal') ? '127.0.0.1' : $x.H
        if (Test-SATcpEndpoint $probe $x.P) { Write-SAOk "$($x.L) reachable ($($x.H):$($x.P))" }
        else { Write-SAWarn "$($x.L) NOT reachable at $($x.H):$($x.P); related features will fail until it is." }
    }
}

# =============================================================================
#  IMAGES (registry by digest; local images only with -UseLocalImages)
# =============================================================================
function Get-SAImageRefs([ValidateSet('cpu', 'cuda')][string]$Variant, [switch]$Local) {
    $keys = @{ frontend = 'frontend'; backend = "backend-$Variant"; db = 'db' }
    $refs = @{}
    if ($Local) {
        foreach ($k in $keys.Keys) { $img = $script:Release.Images[$keys[$k]]; $refs[$k] = "$($img.Repository):$($img.Tag)" }
        return $refs
    }
    $h = $script:Release.RegistryHost; $ns = $script:Release.RegistryNamespace
    if ($h -in 'registry.example.com', '', $null -or $ns -in 'my-organization', '', $null) {
        throw 'This installer has not been released yet: no registry is configured (RELEASE INFORMATION at the top of Install-SalesAgent.ps1).'
    }
    foreach ($k in $keys.Keys) {
        $img = $script:Release.Images[$keys[$k]]
        if ("$($img.Digest)" -notmatch '^sha256:[0-9a-f]{64}$') { throw "No image digest recorded for '$($keys[$k])'. Only digest-pinned images are installed." }
        $refs[$k] = "$h/$ns/$($img.Repository)@$($img.Digest)"
    }
    $refs
}

function Test-SAImagePresent([string]$Ref) { & docker image inspect $Ref *> $null; $LASTEXITCODE -eq 0 }

function Test-SAAuthError([string]$Text) { $Text -match '(?i)unauthorized|authentication required|access denied|denied: |no basic auth credentials|requested access to the resource is denied|insufficient_scope|authorization token has expired|token has expired' }

# ---- Amazon ECR: 12-hour docker login tokens from a read-only access key, no AWS CLI needed ----
function Get-SAEcrRegion([string]$RegistryHost) {
    $m = [regex]::Match($RegistryHost, '^\d{12}\.dkr\.ecr(-fips)?\.([a-z0-9-]+)\.amazonaws\.com(\.cn)?$')
    if ($m.Success) { return $m.Groups[2].Value }
    return $null
}

function Get-SASha256Hex([byte[]]$Bytes) { -join ([Security.Cryptography.SHA256]::HashData($Bytes) | ForEach-Object { $_.ToString('x2') }) }
function Get-SAHmac([byte[]]$Key, [string]$Data) { [Security.Cryptography.HMACSHA256]::HashData($Key, [Text.Encoding]::UTF8.GetBytes($Data)) }

function New-SASigV4Authorization {
    <# AWS Signature Version 4 for a request without query string. Returns the Authorization header value. #>
    param([string]$Method, [string]$HostName, [string]$Path = '/', [hashtable]$Headers, [string]$Body = '',
          [string]$Region, [string]$Service, [string]$AccessKey, [string]$SecretKey, [string]$AmzDate)
    $date = $AmzDate.Substring(0, 8)
    $all = @{ host = $HostName; 'x-amz-date' = $AmzDate }
    foreach ($k in $Headers.Keys) { $all[$k.ToLower()] = "$($Headers[$k])".Trim() }
    $names = $all.Keys | Sort-Object
    $canonicalHeaders = ($names | ForEach-Object { "${_}:$($all[$_])`n" }) -join ''
    $signed = $names -join ';'
    $canonical = "$Method`n$Path`n`n$canonicalHeaders`n$signed`n$(Get-SASha256Hex ([Text.Encoding]::UTF8.GetBytes($Body)))"
    $scope = "$date/$Region/$Service/aws4_request"
    $toSign = "AWS4-HMAC-SHA256`n$AmzDate`n$scope`n$(Get-SASha256Hex ([Text.Encoding]::UTF8.GetBytes($canonical)))"
    $k = Get-SAHmac ([Text.Encoding]::UTF8.GetBytes("AWS4$SecretKey")) $date
    $k = Get-SAHmac $k $Region; $k = Get-SAHmac $k $Service; $k = Get-SAHmac $k 'aws4_request'
    $sig = -join ((Get-SAHmac $k $toSign) | ForEach-Object { $_.ToString('x2') })
    "AWS4-HMAC-SHA256 Credential=$AccessKey/$scope, SignedHeaders=$signed, Signature=$sig"
}

function Get-SAEcrPassword([string]$RegistryHost) {
    <# Returns a 12-hour ECR docker password. Sources, in order: SALES_AGENT_AWS_* variables,
       the AWS CLI (if installed and configured), an interactive prompt. Keys are never stored. #>
    $region = Get-SAEcrRegion $RegistryHost
    $ak = $env:SALES_AGENT_AWS_ACCESS_KEY_ID; $sk = $env:SALES_AGENT_AWS_SECRET_ACCESS_KEY; $st = $env:SALES_AGENT_AWS_SESSION_TOKEN
    if (-not ($ak -and $sk) -and (Get-Command aws -ErrorAction SilentlyContinue)) {
        $r = Invoke-SANative aws @('ecr', 'get-login-password', '--region', $region) -AllowFailure
        if ($r.ExitCode -eq 0 -and $r.Output.Trim()) { $pw = ($r.Output -split "`n" | Select-Object -Last 1).Trim(); Register-SASecret $pw; return $pw }
    }
    if (-not ($ak -and $sk)) {
        if ($script:Opt.NonInteractive) { throw "Set SALES_AGENT_AWS_ACCESS_KEY_ID and SALES_AGENT_AWS_SECRET_ACCESS_KEY (read-only key you received) to download from $RegistryHost." }
        Write-SAInfo 'Enter the READ-ONLY AWS access key you received for downloading Sales Agent (it is not stored).'
        $ak = (Read-Host '    Access key ID').Trim()
        $sk = [Net.NetworkCredential]::new('', (Read-Host '    Secret access key' -AsSecureString)).Password.Trim()
    }
    Register-SASecret $sk; if ($st) { Register-SASecret $st }
    $api = "api.ecr.$region.amazonaws.com"
    $amzDate = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $h = @{ 'content-type' = 'application/x-amz-json-1.1'; 'x-amz-target' = 'AmazonEC2ContainerRegistry_V20150921.GetAuthorizationToken' }
    if ($st) { $h['x-amz-security-token'] = $st }
    $auth = New-SASigV4Authorization -Method POST -HostName $api -Headers $h -Body '{}' -Region $region -Service ecr -AccessKey $ak -SecretKey $sk -AmzDate $amzDate
    $req = @{ 'X-Amz-Date' = $amzDate; 'X-Amz-Target' = $h['x-amz-target']; Authorization = $auth }
    if ($st) { $req['X-Amz-Security-Token'] = $st }
    try {
        $resp = Invoke-RestMethod -Method Post -Uri "https://$api/" -Headers $req -ContentType 'application/x-amz-json-1.1' -Body '{}' -TimeoutSec 30
    } catch {
        throw "AWS refused the access key for $RegistryHost ($($_.Exception.Message)). Check the key, or ask for a new one."
    }
    $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($resp.authorizationData[0].authorizationToken))
    $pw = $decoded.Substring($decoded.IndexOf(':') + 1)
    Register-SASecret $pw
    return $pw
}

function Invoke-SARegistryLogin([string]$RegistryHost) {
    if (Get-SAEcrRegion $RegistryHost) {
        $pw = Get-SAEcrPassword $RegistryHost
        Invoke-SANative docker @('login', $RegistryHost, '--username', 'AWS', '--password-stdin') -InputText $pw | Out-Null
        Write-SAOk "signed in to $RegistryHost (12-hour token)"
        return
    }
    if ($env:SALES_AGENT_REGISTRY_USERNAME -and $env:SALES_AGENT_REGISTRY_TOKEN) {
        Register-SASecret $env:SALES_AGENT_REGISTRY_TOKEN
        Invoke-SANative docker @('login', $RegistryHost, '--username', $env:SALES_AGENT_REGISTRY_USERNAME, '--password-stdin') -InputText $env:SALES_AGENT_REGISTRY_TOKEN | Out-Null
        return
    }
    if ($script:Opt.NonInteractive) { throw "Log in first: docker login $RegistryHost (read-only credentials), or set SALES_AGENT_REGISTRY_USERNAME / SALES_AGENT_REGISTRY_TOKEN." }
    Write-SAInfo "Sign in to $RegistryHost with the READ-ONLY user name and token you received (stored by Docker, not by this installer)."
    if ((Invoke-SANative docker @('login', $RegistryHost) -Interactive -AllowFailure).ExitCode -ne 0) { throw "docker login $RegistryHost failed." }
}

function Confirm-SAImageDigest([string]$Ref) {
    if ($Ref -notmatch '^(?<repo>.+)@(?<digest>sha256:[0-9a-f]{64})$') { return }
    $repo = $Matches.repo; $digest = $Matches.digest
    $slash = $repo.LastIndexOf('/'); $colon = $repo.LastIndexOf(':'); if ($colon -gt $slash) { $repo = $repo.Substring(0, $colon) }
    $have = @((& docker image inspect $Ref --format '{{json .RepoDigests}}' 2>$null) | ConvertFrom-Json -ErrorAction SilentlyContinue)
    if (-not ($have | Where-Object { $_ -in "$repo@$digest", "docker.io/$repo@$digest", "docker.io/library/$repo@$digest" })) { throw "Digest verification failed for $Ref" }
}

function Get-SAImage([string]$Ref, [string]$RegistryHost) {
    if ($Ref -match '@sha256:' -and (Test-SAImagePresent $Ref)) { Confirm-SAImageDigest $Ref; Write-SAOk "present: $Ref"; return }
    Write-SAInfo "downloading $Ref"
    $r = Invoke-SANative docker @('pull', '--quiet', $Ref) -AllowFailure
    if ($r.ExitCode -ne 0 -and (Test-SAAuthError $r.Output) -and $RegistryHost) {
        Invoke-SARegistryLogin $RegistryHost
        $r = Invoke-SANative docker @('pull', '--quiet', $Ref) -AllowFailure
    }
    if ($r.ExitCode -ne 0) { throw "Could not download $Ref`: $((Test-SAAuthError $r.Output) ? 'access denied (invalid or expired read-only token?)' : ($r.Output -split "`n" | Select-Object -Last 1))" }
    Confirm-SAImageDigest $Ref
    Write-SAOk "verified $Ref"
}

function Sync-SAImages([hashtable]$Refs, [switch]$Local) {
    if ($Local) {
        $missing = @($Refs.Values | Where-Object { -not (Test-SAImagePresent $_) })
        if ($missing) { throw "-UseLocalImages: not in the local Docker image store: $($missing -join ', '). Build them with image-build/build-images.ps1." }
        foreach ($r in $Refs.Values) { Write-SAOk "local image: $r" }
    } else {
        foreach ($r in $Refs.Values) { Get-SAImage $r $script:Release.RegistryHost }
    }
    foreach ($r in $script:Release.ThirdParty.Values) { Get-SAImage $r $null }
}

function Test-SALlmFromContainer([hashtable]$Config, [string]$Image) {
    <# The backend cannot start without its LLM. Probe it from a container (same network
       path as the backend: Docker DNS, VPN routing, host.docker.internal) before starting. #>
    $u = [Uri]$Config.values.OPENAI_API_BASE
    $port = $u.IsDefaultPort ? (($u.Scheme -eq 'https') ? 443 : 80) : $u.Port
    $code = "import socket,sys`ntry:`n    socket.create_connection(('$($u.Host)', $port), timeout=8).close(); print('ok')`nexcept Exception as e:`n    print(type(e).__name__ + ': ' + str(e)); sys.exit(3)"
    $r = Invoke-SANative docker @('run', '--rm', '--add-host', 'host.docker.internal:host-gateway', '--entrypoint', 'python', $Image, '-c', $code) -AllowFailure
    [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Target = "$($u.Host):$port"; Detail = ($r.Output -split "`n" | Select-Object -Last 1) }
}

function Test-SAGpuContainer([string]$Image) {
    $r = Invoke-SANative docker @('run', '--rm', '--gpus', 'all', '--entrypoint', 'python', $Image, '-c',
        'import torch,sys; ok=torch.cuda.is_available(); print(torch.__version__, torch.version.cuda, torch.cuda.get_device_name(0) if ok else "no GPU"); sys.exit(0 if ok else 3)') -AllowFailure
    [pscustomobject]@{ Ok = ($r.ExitCode -eq 0); Output = $r.Output.Trim() }
}

# =============================================================================
#  DEPLOYMENT
# =============================================================================
function Write-SARuntimeFiles($Paths, [hashtable]$Config, [switch]$KeepPrevious) {
    if ($KeepPrevious -and (Test-Path -LiteralPath $Paths.RuntimeDir)) {
        Remove-Item -LiteralPath $Paths.PreviousDir -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $Paths.RuntimeDir -Destination $Paths.PreviousDir -Recurse -Force
    }
    foreach ($name in $script:Embedded.Keys) {
        $target = Join-Path $Paths.RuntimeDir $name
        New-SADirectory (Split-Path -Parent $target)
        [IO.File]::WriteAllText($target, ($script:Embedded[$name] -replace "`r`n", "`n"), [Text.UTF8Encoding]::new($false))
    }
    $override = Join-Path $Paths.RuntimeDir 'docker-compose.override.yml'
    $dir = $Config.values.SERVICE_AGENT_DATA_DIR
    if ($dir) {
        $full = (Resolve-Path -LiteralPath $dir).Path -replace '\\', '/'
        Set-Content -LiteralPath $override -Encoding utf8NoBOM -Value "services:`n  backend:`n    volumes:`n      - type: bind`n        source: `"$full`"`n        target: /data/service_agent`n        read_only: true`n"
    } else { Remove-Item -LiteralPath $override -Force -ErrorAction SilentlyContinue }
}

function Import-SASeedBundle($Paths, [string]$Bundle) {
    if (-not (Test-Path -LiteralPath $Bundle -PathType Leaf)) { throw "Seed bundle not found: $Bundle" }
    $tmp = "$($Paths.SeedDir).new"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue; New-SADirectory $tmp
    Invoke-SANative tar @('-xzf', $Bundle, '-C', $tmp) | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $tmp 'manifest.json'))) { Remove-Item -LiteralPath $tmp -Recurse -Force; throw "$Bundle is not a Sales Agent seed bundle." }
    if (Get-ChildItem -LiteralPath $tmp -Recurse -Force | Where-Object { $_.LinkType }) { Remove-Item -LiteralPath $tmp -Recurse -Force; throw 'Seed bundles must not contain links.' }
    Remove-Item -LiteralPath $Paths.SeedDir -Recurse -Force -ErrorAction SilentlyContinue
    Move-Item -LiteralPath $tmp -Destination $Paths.SeedDir
    Write-SAOk "seed bundle unpacked: $Bundle"
}

function Invoke-SACompose($Paths, [string[]]$Arguments, [string]$Variant, [switch]$AllowFailure, [switch]$Interactive) {
    if (-not $Variant) { $Variant = (Get-SAState $Paths).variant ?? 'cpu' }
    $rt = $Paths.RuntimeDir
    if (-not (Test-Path -LiteralPath (Join-Path $rt 'docker-compose.yml'))) { throw "Sales Agent is not installed in $($Paths.ConfigDir)." }
    $a = @('compose', '--project-directory', $rt, '--env-file', $Paths.ComposeEnv, '-f', (Join-Path $rt 'docker-compose.yml'))
    if ($Variant -eq 'cuda') { $a += @('-f', (Join-Path $rt 'docker-compose.gpu.yml')) }
    if (Test-Path -LiteralPath (Join-Path $rt 'docker-compose.override.yml')) { $a += @('-f', (Join-Path $rt 'docker-compose.override.yml')) }
    Invoke-SANative docker ($a + $Arguments) -AllowFailure:$AllowFailure -Interactive:$Interactive
}

function Get-SAServiceStatus($Paths, [string]$Variant) {
    $r = Invoke-SACompose $Paths @('ps', '--all', '--format', 'json') $Variant -AllowFailure
    if ($r.ExitCode -ne 0 -or -not $r.Output.Trim()) { return @() }
    $t = $r.Output.Trim()
    $items = if ($t.StartsWith('[')) { $t | ConvertFrom-Json } else { $t -split "`n" | Where-Object { $_.Trim().StartsWith('{') } | ForEach-Object { $_ | ConvertFrom-Json } }
    foreach ($i in $items) { [pscustomobject]@{ Service = $i.Service; Name = $i.Name; State = $i.State; Health = $i.Health; ExitCode = $i.ExitCode; Status = $i.Status } }
}

function Get-SAFailureHint($Paths, [string]$Variant, [string]$Svc) {
    $Config = Read-SAJson $Paths.ConfigJson
    $text = (Invoke-SACompose $Paths @('logs', '--no-color', '--tail', '400', $Svc) $Variant -AllowFailure).Output
    $hint = if ($text -match "model '([^']+)' not found|NotFoundError") {
                $m = [regex]::Match($text, "model '([^']+)' not found")
                "The LLM endpoint does not know the model$($m.Success ? " '$($m.Groups[1].Value)'" : '') - check LITELLM_PROVIDER_MODEL_NAME (format openai/<model name as the server lists it>)."
            }
            elseif ($text -match 'Evaluation failed' -and $text -match '(?i)connect(ion)? (call )?(failed|error|refused)|ConnectTimeout|timed out') { 'The LLM endpoint (OPENAI_API_BASE) is not reachable from the backend container.' }
            elseif ($text -match '(?i)AuthenticationError|invalid api key|Incorrect API key|Error code: 401\b') { 'The LLM or Gemini API key was rejected.' }
            elseif ($text -match 'does not match expected schema|(Evaluation failed[\s\S]*(ValidationError|JSONDecodeError))') { "The LLM's answers did not match the required structure: the model ($($Config.values.LITELLM_PROVIDER_MODEL_NAME)) is too small or unsuitable. Use a stronger model (e.g. Qwen3-Coder 30B, or at least a 7B instruct model)." }
            elseif ($text -match '(?i)password authentication failed') { 'Database credentials do not match the existing data (configuration replaced?).' }
            else { $null }
    $lines = @($text -split "`n" | Where-Object { $_ -match '(?i)error|exception|failed|refused|denied' } | Select-Object -Last 5 | ForEach-Object { '      ' + $_.Trim().Substring(0, [Math]::Min(200, $_.Trim().Length)) })
    Hide-SASecrets ((@($hint ? "Likely cause: $hint" : $null) + $lines | Where-Object { $_ }) -join "`n")
}

function Reset-SACrashLoops($Paths, [string]$Variant) {
    # Restart counters survive re-runs; give previously crash-looping services a fresh start.
    foreach ($s in Get-SAServiceStatus $Paths $Variant) {
        if (-not $s.Name -or $s.Service -eq 'storage-init') { continue }
        $n = 0; [int]::TryParse("$(& docker inspect -f '{{.RestartCount}}' $s.Name 2>$null)".Trim(), [ref]$n) | Out-Null
        if ($n -ge 2) { Invoke-SACompose $Paths @('up', '--detach', '--force-recreate', '--no-deps', '--pull', 'never', $s.Service) $Variant | Out-Null }
    }
}

function Wait-SAHealthy($Paths, [string]$Variant, [int]$TimeoutSec) {
    Reset-SACrashLoops $Paths $Variant
    $long = 'gateway', 'frontend', 'backend', 'db', 'mongo', 'redis', 'qdrant', 'rustfs'
    $deadline = (Get-Date).AddSeconds($TimeoutSec); $last = ''; $start = Get-Date
    while ($true) {
        $by = @{}; foreach ($s in Get-SAServiceStatus $Paths $Variant) { $by[$s.Service] = $s }
        $pending = @()
        foreach ($n in $long) {
            $s = $by[$n]
            if (-not $s) { $pending += "$n(missing)"; continue }
            $restarts = 0
            if ($s.Name -and $s.State -ne 'exited') { [int]::TryParse("$(& docker inspect -f '{{.RestartCount}}' $s.Name 2>$null)".Trim(), [ref]$restarts) | Out-Null }
            if ($s.State -in 'exited', 'dead' -or $s.State -eq 'restarting' -or $s.Health -eq 'unhealthy' -or $restarts -ge 2) {
                throw "Service '$n' failed ($($s.State)/$($s.Health)).`n$(Get-SAFailureHint $Paths $Variant $n)`n      Details: pwsh ./Install-SalesAgent.ps1 logs -Service $n"
            }
            if ($s.Health -and $s.Health -ne 'healthy') { $pending += "$n($($s.Health))" } elseif (-not $s.Health -and $s.State -ne 'running') { $pending += "$n($($s.State))" }
        }
        $si = $by['storage-init']
        if ($si -and $si.State -eq 'exited' -and "$($si.ExitCode)" -ne '0') { throw "Storage initialisation failed.`n$(Get-SAFailureHint $Paths $Variant 'storage-init')" }
        if (-not $si -or $si.State -ne 'exited') { $pending += 'storage-init' }
        if (-not $pending) { Write-SAOk "all services healthy after $([int]((Get-Date) - $start).TotalSeconds) s"; return }
        $rep = $pending -join ', '; if ($rep -ne $last) { Write-SAInfo "waiting: $rep"; $last = $rep }
        if ((Get-Date) -gt $deadline) { throw "Timed out after $TimeoutSec s waiting for: $rep" }
        Start-Sleep -Seconds 5
    }
}

function Test-SAGateway([hashtable]$Config) {
    $addr = ($Config.values.BIND_ADDRESS -eq '0.0.0.0') ? '127.0.0.1' : ($Config.values.BIND_ADDRESS ?? '127.0.0.1')
    $base = "http://${addr}:$($Config.values.APP_PORT ?? 8080)"
    $ok = $true
    foreach ($c in @(@('gateway', '/gateway-health', @(200)), @('frontend', '/', @(200, 302, 303, 307, 308)), @('backend', '/eb-backend/healthz', @(200)), @('files', '/viewer/ui-assets/.probe', @(200, 403, 404)))) {
        $code = try { [int](Invoke-WebRequest -Uri "$base$($c[1])" -MaximumRedirection 0 -TimeoutSec 15 -SkipHttpErrorCheck).StatusCode } catch { 0 }
        if ($code -in $c[2]) { Write-SAOk ("{0,-9} {1} -> {2}" -f $c[0], $c[1], $code) } else { $ok = $false; Write-SAError ("{0,-9} {1} -> {2}" -f $c[0], $c[1], ($code ? $code : 'no response')) }
    }
    $ok
}

# =============================================================================
#  BACKUP / RESTORE
# =============================================================================
function Backup-SAData($Paths, [string]$Variant, [string]$Label = 'manual') {
    $state = Get-SAState $Paths
    $dir = Join-Path $Paths.BackupDir ("{0}_v{1}_{2}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ($state.installedVersion ?? 'unknown'), $Label)
    New-SADirectory $Paths.BackupDir -Private; New-SADirectory $dir -Private
    $by = @{}; foreach ($s in Get-SAServiceStatus $Paths $Variant) { $by[$s.Service] = $s }
    foreach ($n in 'db', 'mongo') { if ($by[$n].State -ne 'running') { throw "Cannot back up: '$n' is not running (start Sales Agent first)." } }
    Invoke-SACompose $Paths @('exec', '-T', 'db', 'sh', '-c', 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f /tmp/sa.dump') $Variant | Out-Null
    Invoke-SACompose $Paths @('cp', 'db:/tmp/sa.dump', (Join-Path $dir 'postgres.dump')) $Variant | Out-Null
    Invoke-SACompose $Paths @('exec', '-T', 'db', 'rm', '-f', '/tmp/sa.dump') $Variant -AllowFailure | Out-Null
    Invoke-SACompose $Paths @('exec', '-T', 'mongo', 'sh', '-c', 'mongodump --quiet --uri "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@127.0.0.1:27017/?authSource=admin" --gzip --archive=/tmp/sa.archive.gz') $Variant | Out-Null
    Invoke-SACompose $Paths @('cp', 'mongo:/tmp/sa.archive.gz', (Join-Path $dir 'mongo.archive.gz')) $Variant | Out-Null
    Invoke-SACompose $Paths @('exec', '-T', 'mongo', 'rm', '-f', '/tmp/sa.archive.gz') $Variant -AllowFailure | Out-Null
    $cfgDir = Join-Path $dir 'config'; New-SADirectory $cfgDir -Private
    foreach ($f in $Paths.ConfigJson, $Paths.ComposeEnv, $Paths.BackendEnv, $Paths.FrontendEnv, $Paths.StateFile) { if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $cfgDir -Force } }
    Get-ChildItem -LiteralPath $dir -Recurse -File -Force | ForEach-Object { Protect-SAFile $_.FullName }
    foreach ($f in 'postgres.dump', 'mongo.archive.gz') { if ((Get-Item -LiteralPath (Join-Path $dir $f)).Length -lt 64) { throw "Backup file $f is unexpectedly small." } }
    Write-SAOk "backup: $dir"
    $dir
}

function Restore-SAData($Paths, [string]$Variant, [string]$Dir) {
    Invoke-SACompose $Paths @('stop', 'gateway', 'frontend', 'backend') $Variant -AllowFailure | Out-Null
    Invoke-SACompose $Paths @('cp', (Join-Path $Dir 'postgres.dump'), 'db:/tmp/sa.dump') $Variant | Out-Null
    Invoke-SACompose $Paths @('exec', '-T', 'db', 'sh', '-c', 'pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner /tmp/sa.dump; rc=$?; rm -f /tmp/sa.dump; exit $rc') $Variant | Out-Null
    Invoke-SACompose $Paths @('cp', (Join-Path $Dir 'mongo.archive.gz'), 'mongo:/tmp/sa.archive.gz') $Variant | Out-Null
    Invoke-SACompose $Paths @('exec', '-T', 'mongo', 'sh', '-c', 'mongorestore --quiet --uri "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@127.0.0.1:27017/?authSource=admin" --drop --gzip --archive=/tmp/sa.archive.gz; rc=$?; rm -f /tmp/sa.archive.gz; exit $rc') $Variant | Out-Null
    Write-SAOk "data restored from $Dir"
}

function Wait-SAServices($Paths, [string]$Variant, [string[]]$Names, [int]$TimeoutSec = 300) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (@(Get-SAServiceStatus $Paths $Variant | Where-Object { $_.Service -in $Names -and $_.Health -eq 'healthy' }).Count -eq $Names.Count) { return }
        Start-Sleep -Seconds 3
    }
    throw "Timed out waiting for $($Names -join ', ')"
}

# =============================================================================
#  ACTIONS
# =============================================================================
function Open-SABrowser([string]$Url) {
    if ($NoBrowser -or $script:Opt.NonInteractive) { return }
    try {
        if ($IsWindows) { Start-Process $Url } elseif ($IsMacOS) { & open $Url } elseif (Get-Command xdg-open -ErrorAction SilentlyContinue) { & xdg-open $Url *> $null }
    } catch { Write-SALog DEBUG "browser: $($_.Exception.Message)" }
}

function Invoke-SAInstall($Paths, [switch]$IsUpdate) {
    $os = Get-SAOsInfo
    Write-SAStep 'Checking this computer'
    $docker = Assert-SADockerReady $os
    $arch = Get-SACpuArchitecture; $ram = Get-SAMemoryGB; $disk = Get-SAFreeDiskGB $Paths.ConfigDir
    Write-SAInfo ("{0} {1} ({2}), {3} GB RAM, {4} GB free disk, Docker {5} / Compose {6} ({7} GB for containers)" -f $os.Name, $os.Version, $arch, $ram, $disk, $docker.ServerVersion, $docker.ComposeVersion, $docker.MemTotalGB)

    $state = Get-SAState $Paths
    $saved = Read-SAJson $Paths.ConfigJson
    if ($state.installedVersion -and -not $IsUpdate) {
        $cmp = Compare-SAVersion $script:Release.AppVersion $state.installedVersion
        if ($cmp -gt 0) {
            if (-not (Confirm-SAAction "Sales Agent $($state.installedVersion) is installed. Update it to $($script:Release.AppVersion)? (a backup is made first)" $true)) { throw 'Cancelled.' }
            return Invoke-SAUpdate $Paths
        }
        if ($cmp -lt 0) { throw "A newer version ($($state.installedVersion)) is installed than this installer carries ($($script:Release.AppVersion))." }
        Write-SAInfo "Sales Agent $($state.installedVersion) is installed: checking and re-applying it."
    }

    # --- configuration -------------------------------------------------------------
    $envFile = $EnvFile ? $EnvFile : (Get-SADefaultEnvFile)
    if (-not (Test-Path -LiteralPath $envFile)) {
        New-SAEnvTemplate $envFile
        Write-SAInfo "Created $envFile - you can keep your settings there."
        if ($script:Opt.NonInteractive) { throw "Fill in the required values in $envFile and run the installer again." }
    }
    $fileValues = Read-SADotEnv $envFile
    $overrides = @{}
    if ($Variant) { $overrides.BACKEND_VARIANT = $Variant }
    if ($SeedBundle) { $overrides.SEED_BUNDLE = (Resolve-Path -LiteralPath $SeedBundle).Path }
    $res = Resolve-SAConfiguration -Saved $saved -FileValues $fileValues -Overrides $overrides
    $cfg = $res.Config; $v = $cfg.values

    # --- variant + prerequisites ---------------------------------------------------------
    Write-SAStep 'Checking requirements'
    $variantSel = Select-SAVariant ($v.BACKEND_VARIANT ?? 'auto') (Get-SAGpuInfo $docker)
    $req = $script:Release.Requirements
    $chk = {
        param($name, $status, $detail)
        switch ($status) { 'PASS' { Write-SAOk ("{0,-24} {1}" -f $name, $detail) } 'WARN' { Write-SAWarn ("{0,-24} {1}" -f $name, $detail) } 'FAIL' { Write-SAError ("{0,-24} {1}" -f $name, $detail) } }
        if ($status -eq 'FAIL') { $script:PrereqFails += $name }
    }
    $script:PrereqFails = @()
    & $chk 'CPU architecture' (($arch -in 'amd64', 'arm64') ? 'PASS' : 'FAIL') $arch
    & $chk 'Memory' (($null -eq $ram) ? 'WARN' : (($ram -lt $req.RamGBMin - 0.5) ? 'FAIL' : (($ram -lt $req.RamGBRecommended - 0.5) ? 'WARN' : 'PASS'))) "$ram GB (min $($req.RamGBMin), recommended $($req.RamGBRecommended))"
    $needDisk = ($variantSel -eq 'cuda') ? $req.DiskGBCuda : $req.DiskGBCpu
    & $chk 'Free disk' (($null -eq $disk) ? 'WARN' : (($disk -lt $needDisk) ? 'FAIL' : 'PASS')) "$disk GB (need $needDisk GB)"
    & $chk 'Docker engine' (((Compare-SAVersion $docker.ServerVersion $req.DockerMin) -ge 0) ? 'PASS' : 'FAIL') "$($docker.ServerVersion) (min $($req.DockerMin))"
    & $chk 'Docker Compose' (($docker.ComposeVersion -and (Compare-SAVersion $docker.ComposeVersion $req.ComposeMin) -ge 0) ? 'PASS' : 'FAIL') "$($docker.ComposeVersion ?? 'missing') (min $($req.ComposeMin))"
    if ($docker.MemTotalGB) { & $chk 'Memory for Docker' (($docker.MemTotalGB -lt 5.5) ? 'FAIL' : (($docker.MemTotalGB -lt 7.5) ? 'WARN' : 'PASS')) "$($docker.MemTotalGB) GB (Docker Desktop: Settings > Resources, 8 GB recommended)" }
    $port = [int]($v.APP_PORT ?? 8080); $bind = $v.BIND_ADDRESS ?? '127.0.0.1'
    if (-not (Test-SAPortAvailable $port $bind 'sales-agent')) {
        $alt = Find-SAFreePort ($port + 1) $bind
        if ($alt -and -not $script:Opt.NonInteractive -and (Confirm-SAAction "Port $port is in use. Use port $alt instead?" $true)) { $v.APP_PORT = $alt; $port = $alt }
    }
    & $chk "Port $port" ((Test-SAPortAvailable $port $bind 'sales-agent') ? 'PASS' : 'FAIL') "${bind}:$port"
    if ($script:PrereqFails) { throw "Requirements not met: $($script:PrereqFails -join ', ')" }

    # --- images --------------------------------------------------------------------------------
    Write-SAStep ($UseLocalImages ? 'Preparing images (local images - maintainer mode)' : 'Downloading Sales Agent')
    $refs = Get-SAImageRefs $variantSel -Local:$UseLocalImages
    Sync-SAImages $refs -Local:$UseLocalImages
    if ($variantSel -eq 'cuda') {
        $probe = Test-SAGpuContainer $refs.backend
        if ($probe.Ok) { Write-SAOk "GPU ready: $($probe.Output)" }
        elseif (($v.BACKEND_VARIANT ?? 'auto') -eq 'auto') {
            Write-SAWarn "The GPU is not usable from containers ($($probe.Output)); using the CPU build."
            $variantSel = 'cpu'; $refs = Get-SAImageRefs 'cpu' -Local:$UseLocalImages; Sync-SAImages $refs -Local:$UseLocalImages
        } else { throw "GPU build requested but the GPU is not usable from containers: $($probe.Output)" }
    }

    # --- write configuration ---------------------------------------------------------------------
    Write-SAStep 'Saving configuration'
    if ($res.PendingPassword) { Set-SAAdminPasswordHash $cfg $res.PendingPassword $refs.backend; Write-SAOk 'administrator password stored as a bcrypt hash' }
    if ($v.SEED_BUNDLE) { Import-SASeedBundle $Paths $v.SEED_BUNDLE }
    $backupDir = $null
    if ($IsUpdate) {
        Write-SAStep 'Backing up data before the update'
        $running = @(Get-SAServiceStatus $Paths $state.variant | Where-Object { $_.Service -in 'db', 'mongo' -and $_.State -eq 'running' })
        if ($running.Count -lt 2) { Invoke-SACompose $Paths @('up', '-d', '--no-recreate', '--pull', 'never', 'db', 'mongo') $state.variant | Out-Null; Wait-SAServices $Paths $state.variant 'db', 'mongo' }
        $backupDir = Backup-SAData $Paths $state.variant "pre-update-to-$($script:Release.AppVersion)"
        $state.previous = @{ version = $state.installedVersion; images = $state.images; variant = $state.variant; backupDir = $backupDir }
        Save-SAState $Paths $state
    }
    Write-SARuntimeFiles $Paths $cfg -KeepPrevious:$IsUpdate
    Export-SAConfiguration $cfg $refs $Paths
    if ($res.PendingPassword) { Remove-SAPasswordFromEnvFile $envFile }
    $state = Get-SAState $Paths
    $state.variant = $variantSel; $state.images = $refs; $state.localImages = [bool]$UseLocalImages; $state.installerVersion = $script:Release.InstallerVersion
    Save-SAState $Paths $state
    if (-not $SkipEndpointCheck) {
        Write-SAStep 'Checking external services'
        Test-SAExternalEndpoints $cfg
        $llm = Test-SALlmFromContainer $cfg $refs.backend
        if ($llm.Ok) { Write-SAOk "LLM endpoint reachable from containers ($($llm.Target))" }
        else {
            Write-SAError "The LLM endpoint $($llm.Target) is NOT reachable from Docker containers ($($llm.Detail))."
            Write-SAInfo 'Sales Agent cannot start without it. Check OPENAI_API_BASE, connect the VPN / network that reaches it'
            Write-SAInfo '(restart Docker Desktop after connecting a VPN), or use http://host.docker.internal:<port>/v1 for an LLM on this computer.'
            # -Yes / -NonInteractive never override this: without the LLM the backend cannot start.
            $stop = "LLM endpoint not reachable: $($llm.Target). Fix OPENAI_API_BASE or the network and run the installer again (-SkipEndpointCheck skips this check)."
            if ($script:Opt.AssumeYes -or $script:Opt.NonInteractive) { throw $stop }
            if (-not (Confirm-SAAction 'Start anyway?' $false)) { throw $stop }
        }
    }

    # --- start -----------------------------------------------------------------------------------------
    Write-SAStep 'Starting Sales Agent (the first start prepares the AI agent and can take 5-15 minutes)'
    try {
        Invoke-SACompose $Paths @('config', '--quiet') $variantSel | Out-Null
        Invoke-SACompose $Paths @('up', '--detach', '--remove-orphans', '--pull', 'never') $variantSel | Out-Null
        Wait-SAHealthy $Paths $variantSel $HealthTimeoutSec
        if (-not (Test-SAGateway $cfg)) { throw 'Gateway checks failed.' }
    } catch {
        if ($IsUpdate) {
            Write-SAError "Update failed: $($_.Exception.Message)"
            Invoke-SARollback $Paths -WithData:($RestoreData -or (Confirm-SAAction 'Also restore the database backup taken before the update?' $false))
            throw "The update was rolled back to $($state.previous.version)."
        }
        throw
    }
    $state = Get-SAState $Paths
    $state.installedVersion = $script:Release.AppVersion
    if (-not $state.installedAt) { $state.installedAt = (Get-Date).ToString('o') }
    Save-SAState $Paths $state
    $url = Get-SAPublicBaseUrl $cfg
    Write-Host ''
    Write-Host "  Sales Agent $($script:Release.AppVersion) is running: $url" -ForegroundColor Green
    Write-Host "  Sign in as '$($v.SYSTEM_ADMIN_USERNAME)' with the administrator password."
    if ($backupDir) { Write-Host "  Backup of the previous version: $backupDir   (undo: Install-SalesAgent.ps1 rollback)" }
    Write-Host '  Manage: Install-SalesAgent.ps1 status | logs | stop | start | uninstall'
    Open-SABrowser $url
}

function Invoke-SAUpdate($Paths) {
    $state = Get-SAState $Paths
    if (-not $state.installedVersion) { throw 'Sales Agent is not installed yet; run the installer without arguments.' }
    if ((Compare-SAVersion $script:Release.AppVersion $state.installedVersion) -lt 0) { throw "This installer ($($script:Release.AppVersion)) is older than the installed version ($($state.installedVersion))." }
    Invoke-SAInstall $Paths -IsUpdate
}

function Invoke-SARollback($Paths, [switch]$WithData) {
    $state = Get-SAState $Paths; $prev = $state.previous
    if (-not $prev -or -not $prev.backupDir -or -not (Test-Path -LiteralPath $prev.backupDir)) { throw 'No previous version is recorded; nothing to roll back to.' }
    Write-SAStep "Rolling back to $($prev.version)"
    foreach ($f in 'config.json', '.env', 'backend.env', 'frontend.env') {
        $src = Join-Path $prev.backupDir "config/$f"
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $Paths.ConfigDir $f) -Force; Protect-SAFile (Join-Path $Paths.ConfigDir $f) }
    }
    if (Test-Path -LiteralPath $Paths.PreviousDir) { Remove-Item -LiteralPath $Paths.RuntimeDir -Recurse -Force; Copy-Item -LiteralPath $Paths.PreviousDir -Destination $Paths.RuntimeDir -Recurse }
    foreach ($r in $prev.images.Values) { if (-not (Test-SAImagePresent $r)) { throw "Previous image $r is no longer available; cannot roll back." } }
    Invoke-SACompose $Paths @('up', '--detach', '--remove-orphans', '--pull', 'never') $prev.variant | Out-Null
    if ($WithData) { Wait-SAServices $Paths $prev.variant 'db', 'mongo'; Restore-SAData $Paths $prev.variant $prev.backupDir; Invoke-SACompose $Paths @('up', '--detach', '--pull', 'never') $prev.variant | Out-Null }
    Wait-SAHealthy $Paths $prev.variant $HealthTimeoutSec
    $state.installedVersion = $prev.version; $state.images = $prev.images; $state.variant = $prev.variant; $state.Remove('previous')
    Save-SAState $Paths $state
    Write-SAOk "rolled back to $($prev.version)"
}

function Invoke-SAStatus($Paths) {
    $cfg = Read-SAJson $Paths.ConfigJson
    if (-not $cfg) { Write-Host "Sales Agent is not installed ($($Paths.ConfigDir))."; return 1 }
    $state = Get-SAState $Paths
    Write-Host "Sales Agent $($state.installedVersion ?? '(installation incomplete)')  -  $(Get-SAPublicBaseUrl $cfg)  -  backend: $($state.variant)" -ForegroundColor Cyan
    if ($state.previous.version) { Write-Host "  previous version (rollback): $($state.previous.version)" }
    if (-not (Get-SADockerInfo).DaemonRunning) { Write-Host '  Docker is not running.' -ForegroundColor Yellow; return 2 }
    $svc = @(Get-SAServiceStatus $Paths)
    $svc | Sort-Object Service | Format-Table Service, State, @{ n = 'Health'; e = { $_.Health ? $_.Health : '-' } }, Status -AutoSize | Out-String -Width 160 | Write-Host
    if (-not @($svc | Where-Object State -eq 'running')) { Write-Host '  Stopped. Start with: Install-SalesAgent.ps1 start'; return 2 }
    return ((Test-SAGateway $cfg) ? 0 : 3)
}

function Invoke-SAUninstall($Paths) {
    $phrase = 'DELETE ALL DATA'
    if ($RemoveConfig -and -not $RemoveVolumes) { throw '-RemoveConfig requires -RemoveVolumes: kept data cannot be opened without the stored credentials.' }
    $deleteData = $false
    if ($RemoveVolumes) {
        if ($ConfirmDataDeletion) { $deleteData = ($ConfirmDataDeletion -ceq $phrase) }
        elseif (-not $script:Opt.NonInteractive) {
            Write-Host '    This permanently deletes ALL Sales Agent data (databases, files, chat history).' -ForegroundColor Yellow
            $deleteData = ((Read-Host "    Type '$phrase' to confirm") -ceq $phrase)
        }
        if (-not $deleteData) { throw 'Data deletion was not confirmed; nothing was removed.' }
    } elseif (-not (Confirm-SAAction 'Remove the Sales Agent containers? (your data is kept)' $true)) { throw 'Cancelled.' }
    if (-not (Get-SADockerInfo).DaemonRunning) { throw 'Docker is not running. Start Docker and try again.' }
    $state = Get-SAState $Paths
    $a = @('down', '--remove-orphans', '--timeout', '60'); if ($deleteData) { $a += '--volumes' }
    if (Test-Path -LiteralPath (Join-Path $Paths.RuntimeDir 'docker-compose.yml')) { Invoke-SACompose $Paths $a | Out-Null }
    Write-SAOk ($deleteData ? 'containers and data removed' : 'containers removed; data kept')
    if ($RemoveImages) {
        foreach ($i in @(@($state.images.Values) + @($state.previous.images.Values) | Where-Object { $_ } | Select-Object -Unique)) {
            $r = Invoke-SANative docker @('image', 'rm', $i) -AllowFailure; if ($r.ExitCode -eq 0) { Write-SAOk "removed $i" } else { Write-SAWarn "kept $i" }
        }
    }
    $state.Remove('installedVersion'); $state.uninstalledAt = (Get-Date).ToString('o'); Save-SAState $Paths $state
    if ($RemoveConfig) {
        Exit-SALock $Paths
        Get-ChildItem -LiteralPath $Paths.ConfigDir -Force | Where-Object { $_.Name -notin 'backups', 'logs' } | Remove-Item -Recurse -Force
        Write-SAOk "configuration removed (backups and logs kept in $($Paths.ConfigDir))"
    }
    Write-Host "`n  Sales Agent was uninstalled. Docker was not changed.$(if (-not $deleteData) { ' Your data is kept; running the installer again brings it back.' })" -ForegroundColor Green
}

function Invoke-SAMain {
    $paths = Get-SAPaths $ConfigDir
    New-SADirectory $paths.ConfigDir -Private
    New-SADirectory $paths.LogDir -Private
    $script:LogFile = Join-Path $paths.LogDir ("{0}-{1}.log" -f $Action, (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType File -Force -Path $script:LogFile | Out-Null; Protect-SAFile $script:LogFile
    $saved = Read-SAJson $paths.ConfigJson
    if ($saved) { Register-SAConfigSecrets $saved }
    if ($Action -in 'install', 'update') { Write-Host "Sales Agent installer $($script:Release.InstallerVersion) (application $($script:Release.AppVersion))" -ForegroundColor Cyan }
    $needsLock = $Action -notin 'status', 'logs'
    try {
        if ($needsLock) { Enter-SALock $paths $Action }
        if ($Action -notin 'install', 'uninstall' -and -not $saved) { throw "Sales Agent is not installed (no configuration in $($paths.ConfigDir))." }
        switch ($Action) {
            'install'   { $null = Invoke-SAInstall $paths }
            'update'    { $null = Invoke-SAUpdate $paths }
            'rollback'  {
                if (-not (Confirm-SAAction "Roll back to $((Get-SAState $paths).previous.version)?" $true)) { throw 'Cancelled.' }
                $null = Invoke-SARollback $paths -WithData:($RestoreData -or (Confirm-SAAction 'Also restore the database backup taken before the update?' $false))
            }
            'start'     {
                $null = Assert-SADockerReady (Get-SAOsInfo) -NoInstall
                Invoke-SACompose $paths @('up', '--detach', '--no-recreate', '--pull', 'never') | Out-Null
                Wait-SAHealthy $paths (Get-SAState $paths).variant $HealthTimeoutSec
                $null = Test-SAGateway $saved
                Write-SAOk "Sales Agent: $(Get-SAPublicBaseUrl $saved)"; Open-SABrowser (Get-SAPublicBaseUrl $saved)
            }
            'stop'      { if ((Get-SADockerInfo).DaemonRunning) { Invoke-SACompose $paths @('stop', '--timeout', '60') | Out-Null }; Write-SAOk 'stopped (data kept)' }
            'restart'   {
                Invoke-SACompose $paths @('restart', '--timeout', '60') | Out-Null
                Wait-SAHealthy $paths (Get-SAState $paths).variant $HealthTimeoutSec; Write-SAOk 'restarted'
            }
            'status'    { return (Invoke-SAStatus $paths) }
            'logs'      {
                $valid = 'gateway', 'frontend', 'backend', 'db', 'mongo', 'redis', 'qdrant', 'rustfs', 'storage-init'
                $svc = @(($Service -join ',') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                $bad = $svc | Where-Object { $_ -notin $valid }; if ($bad) { throw "Unknown service(s): $($bad -join ', '). Valid: $($valid -join ', ')" }
                $a = @('logs', '--tail', "$Tail"); if ($Follow) { $a += '--follow' }; $a += $svc
                return (Invoke-SACompose $paths $a -Interactive -AllowFailure).ExitCode
            }
            'backup'    { $null = Backup-SAData $paths (Get-SAState $paths).variant 'manual' }
            'uninstall' { if (-not $saved -and -not (Test-Path -LiteralPath $paths.RuntimeDir)) { Write-Host 'Nothing to uninstall.'; return 0 }; $null = Invoke-SAUninstall $paths }
        }
        return 0
    } catch {
        Write-SAError $_.Exception.Message
        Write-SALog DEBUG $_.ScriptStackTrace
        if ($Action -eq 'install') { Write-Host "`n  Fix the problem above and run the installer again; it continues where it stopped." -ForegroundColor Yellow }
        Write-Host "  Log: $($script:LogFile)" -ForegroundColor Yellow
        return 1
    } finally {
        if ($needsLock) { Exit-SALock $paths }
    }
}

# Run unless dot-sourced (unit tests dot-source this file to load the functions).
if ($MyInvocation.InvocationName -ne '.') {
    $rc = @(Invoke-SAMain) | Where-Object { $_ -is [int] } | Select-Object -Last 1
    exit ($rc ?? 1)
}
