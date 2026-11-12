BeforeAll {
    $script:Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $script:Root 'Install-SalesAgent.ps1')
    # Pester can only mock commands that exist.
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { function global:docker { $global:LASTEXITCODE = 1 } }
    function Set-TestMode([switch]$Yes) { $script:Opt.NonInteractive = $true; $script:Opt.AssumeYes = [bool]$Yes }
    function Def([string]$Name) { $script:Settings | Where-Object Name -eq $Name }
    function New-FileValues {
        $m = [ordered]@{
            LITELLM_PROVIDER_MODEL_NAME = 'openai/test-model'
            OPENAI_API_BASE             = 'http://llm.example.test:8000/v1'
            OPENAI_API_KEY              = 'sk-test-openai-key-123'
            GEMINI_API_KEY              = 'gemini-test-key-456'
            SYSTEM_ADMIN_EMAIL          = 'admin@example.com'
            SYSTEM_ADMIN_PASSWORD       = 'correct horse battery staple'
            APP_PORT                    = '18080'
        }
        return $m
    }
    $script:Hash = '$2b$12$abcdefghijklmnopqrstuuJ2v8L8dQm1nVb7cE0x4QpXjKz7o6x9e'
}

Describe 'sales-agent.env parsing' {
    It 'treats template comments as empty values' {
        $f = Join-Path $TestDrive 't.env'
        Set-Content $f "A=                # REQUIRED`nB=value   # trailing comment`nC='x # not a comment'`nexport D=d`n# E=commented"
        $m = Read-SADotEnv $f
        $m.A | Should -Be ''
        $m.B | Should -Be 'value'
        $m.C | Should -Be 'x # not a comment'
        $m.D | Should -Be 'd'
        $m.Contains('E') | Should -BeFalse
    }
    It 'the shipped example matches the settings catalogue' {
        $m = Read-SADotEnv (Join-Path $script:Root 'sales-agent.env.example')
        @($m.Keys | Sort-Object) | Should -Be @($script:Settings.Name | Sort-Object)
        @($m.Values | Where-Object { $_ }).Count | Should -Be 0
    }
}

Describe 'Generated env files are read literally by Compose' {
    It 'round-trips special characters' -ForEach @(@{ V = '$2b$12$abc/def' }, @{ V = "it's" }, @{ V = 'a"b\c' }, @{ V = '${HOME}' }) {
        $f = Join-Path $TestDrive "e-$([guid]::NewGuid()).env"
        Write-SADotEnv $f ([ordered]@{ K = $V })
        (Read-SADotEnv $f).K | Should -BeExactly $V
    }
}

Describe 'Value validation' {
    It 'validates types' {
        (Test-SAValue (Def APP_PORT) '70000').Ok | Should -BeFalse
        (Test-SAValue (Def APP_PORT) '9090').Value | Should -Be 9090
        (Test-SAValue (Def OPENAI_API_BASE) 'not-a-url').Ok | Should -BeFalse
        (Test-SAValue (Def SYSTEM_ADMIN_EMAIL) 'nope').Ok | Should -BeFalse
        (Test-SAValue (Def COOKIE_SECURE) 'yes').Value | Should -BeTrue
        (Test-SAValue (Def COOKIE_SAMESITE) 'sideways').Ok | Should -BeFalse
        (Test-SAValue (Def SYSTEM_ADMIN_PASSWORD) 'short').Ok | Should -BeFalse
        (Test-SAValue (Def LDAP_HOST) 'bad host!').Ok | Should -BeFalse
        (Test-SAValue (Def SERVICE_AGENT_DATA_DIR) (Join-Path $TestDrive 'missing')).Ok | Should -BeFalse
        (Test-SAValue (Def LITELLM_PROVIDER_API_KEY) 'PASTE_YOUR_GEMINI_KEY_HERE').Error | Should -Match 'placeholder'
        (Test-SAValue (Def GEMINI_API_KEY) '<your key>').Ok | Should -BeFalse
        (Test-SAValue (Def LITELLM_PROVIDER_MODEL_NAME) '=gemini/gemini-3.5-flash').Error | Should -Match "starts with '='"
        (Test-SAValue (Def LITELLM_PROVIDER_MODEL_NAME) 'qwen2.5:7b').Ok | Should -BeFalse
        (Test-SAValue (Def LITELLM_PROVIDER_MODEL_NAME) 'gemini/gemini-3.5-flash').Ok | Should -BeTrue
        (Test-SAValue (Def LITELLM_PROVIDER_MODEL_NAME) 'openai/Qwen/Qwen3-Coder-30B-A3B-Instruct').Ok | Should -BeTrue
    }
}

Describe 'Resolve-SAConfiguration' {
    BeforeEach { Set-TestMode }

    It 'builds a configuration from sales-agent.env and generates secrets' {
        $r = Resolve-SAConfiguration -FileValues (New-FileValues)
        $c = $r.Config
        $c.values.APP_PORT | Should -Be 18080
        $c.values.SYSTEM_ADMIN_USERNAME | Should -Be 'admin'
        $c.values.COOKIE_SAMESITE | Should -Be 'lax'
        $c.internal.POSTGRES_PASSWORD.Length | Should -Be 32
        $c.internal.SECRET_KEY.Length | Should -Be 64
        $r.PendingPassword | Should -Be 'correct horse battery staple'
        ($c | ConvertTo-Json -Depth 10) | Should -Not -Match 'battery staple'
    }
    It 'lists every missing required value (non-interactive)' {
        $f = New-FileValues; $f.Remove('GEMINI_API_KEY'); $f.Remove('SYSTEM_ADMIN_EMAIL')
        $err = { Resolve-SAConfiguration -FileValues $f } | Should -Throw -PassThru
        $err.Exception.Message | Should -Match 'GEMINI_API_KEY'
        $err.Exception.Message | Should -Match 'SYSTEM_ADMIN_EMAIL'
    }
    It 'rejects invalid values with the key name' {
        $f = New-FileValues; $f.OPENAI_API_BASE = 'llm-without-scheme'
        { Resolve-SAConfiguration -FileValues $f } | Should -Throw '*OPENAI_API_BASE*'
    }
    It 'keeps saved values when the file is empty (re-run)' {
        $first = (Resolve-SAConfiguration -FileValues (New-FileValues)).Config
        $first.values.SYSTEM_ADMIN_PASSWORD_HASH = $script:Hash
        $second = Resolve-SAConfiguration -Saved $first -FileValues ([ordered]@{})
        $second.Config.internal.POSTGRES_PASSWORD | Should -Be $first.internal.POSTGRES_PASSWORD
        $second.Config.values.OPENAI_API_BASE | Should -Be 'http://llm.example.test:8000/v1'
        $second.PendingPassword | Should -BeNullOrEmpty
    }
    It 'does not apply changed file values without confirmation' {
        $first = (Resolve-SAConfiguration -FileValues (New-FileValues)).Config
        $first.values.SYSTEM_ADMIN_PASSWORD_HASH = $script:Hash
        $f = [ordered]@{ OPENAI_API_BASE = 'http://other.example.test/v1' }
        (Resolve-SAConfiguration -Saved $first -FileValues $f).Config.values.OPENAI_API_BASE | Should -Be 'http://llm.example.test:8000/v1'
        Set-TestMode -Yes
        (Resolve-SAConfiguration -Saved $first -FileValues $f).Config.values.OPENAI_API_BASE | Should -Be 'http://other.example.test/v1'
    }
    It 'enables an optional integration when its key is set and requires its fields' {
        $f = New-FileValues; $f.LDAP_HOST = 'ldap.example.com'
        { Resolve-SAConfiguration -FileValues $f } | Should -Throw '*LDAP_SEARCH_BASE*'
    }
    It 'clears a value with "-" (switching an integration off) after confirmation' {
        $f = New-FileValues; $f.LDAP_HOST = 'ldap.example.com'; $f.LDAP_SEARCH_BASE = 'DC=x'; $f.LDAP_DOMAIN = 'X'; $f.LDAP_UPN_SUFFIX = 'x.com'; $f.LDAP_SERVICE_BIND_DN = 'cn=s'; $f.LDAP_SERVICE_BIND_PASSWORD = 'secret-pw-1'
        $first = (Resolve-SAConfiguration -FileValues $f).Config
        $first.values.SYSTEM_ADMIN_PASSWORD_HASH = $script:Hash
        $clr = [ordered]@{ LDAP_HOST = '-' }
        (Resolve-SAConfiguration -Saved $first -FileValues $clr).Config.values.LDAP_HOST | Should -Be 'ldap.example.com'
        Set-TestMode -Yes
        $c = (Resolve-SAConfiguration -Saved $first -FileValues $clr).Config
        $c.values.ContainsKey('LDAP_HOST') | Should -BeFalse
        (Get-SAEnvironmentFiles $c @{ frontend = 'f'; backend = 'b'; db = 'd' } (Get-SAPaths (Join-Path $TestDrive 'x'))).Backend.LDAP_UPN_SUFFIX | Should -Be 'ldap.invalid'
    }
    It 'refuses to clear a required value' {
        { Resolve-SAConfiguration -FileValues ([ordered]@{ OPENAI_API_BASE = '-' }) } | Should -Throw '*cannot be cleared*'
    }
    It 'rejects SameSite=none without Secure' {
        $f = New-FileValues; $f.COOKIE_SAMESITE = 'none'
        { Resolve-SAConfiguration -FileValues $f } | Should -Throw '*COOKIE_SECURE*'
    }
}

Describe 'Environment files' {
    BeforeAll {
        Set-TestMode
        $script:Cfg = (Resolve-SAConfiguration -FileValues (New-FileValues)).Config
        $script:Cfg.values.SYSTEM_ADMIN_PASSWORD_HASH = $script:Hash
        $script:P = Get-SAPaths (Join-Path $TestDrive 'cfg')
        $script:Refs = @{ frontend = 'sales-agent-frontend:1.0.0'; backend = 'sales-agent-backend:1.0.0-cpu'; db = 'sales-agent-db:1.0.0' }
        $script:F = Get-SAEnvironmentFiles $script:Cfg $script:Refs $script:P
    }
    It 'derives internal URLs and public links' {
        $b = $script:F.Backend
        $b.DATABASE_URL | Should -Match '^postgresql\+asyncpg://sales_agent:[A-Za-z0-9]{32}@db:5432/sales_agent$'
        $b.LOGIN_DATABASE_URL | Should -Match '^postgresql://'
        $b.MONGO_URI | Should -Match '@mongo:27017/\?authSource=admin$'
        $b.RUSTFS_VIEWER_URL | Should -Be 'http://localhost:18080/viewer'
        $b.FRONTEND_URL | Should -Be 'http://localhost:18080'
        $b.GOOGLE_API_KEY | Should -Be 'gemini-test-key-456'
        $b.SYSTEM_ADMIN_PASSWORD_HASH | Should -Be $script:Hash
        $script:F.Frontend.BACKEND_INTERNAL_URL | Should -Be 'http://backend:8080'
        $script:F.Frontend.COOKIE_SECURE | Should -Be 'false'
    }
    It 'overrides the company defaults of disabled integrations' {
        $b = $script:F.Backend
        $b.Contains('IKONNECT_MSSQL_DB_HOST') | Should -BeTrue
        $b.IKONNECT_MSSQL_DB_HOST | Should -Be ''
        $b.IKONNECT_MSSQL_DB_PASSWORD | Should -Be ''
        $b.TRANSLATION_API_URL | Should -Match '^http://127\.0\.0\.1:9/'
        $b.OLLAMA_BASE_URL | Should -Be 'http://127.0.0.1:9'
        $b.LDAP_UPN_SUFFIX | Should -Be 'ldap.invalid'
        $b.SERVICE_AGENT_ROOT | Should -Be '/data/service_agent'
        $b.DOCUMENT_STORE | Should -Be 'http://rustfs:9000'
    }
    It 'never writes installer-only or plain password keys into backend.env' {
        $script:F.Backend.Keys | Should -Not -Contain 'SYSTEM_ADMIN_PASSWORD'
        $script:F.Backend.Keys | Should -Not -Contain 'APP_PORT'
    }
    It 'pins all images in the compose env' {
        $c = $script:F.Compose
        foreach ($k in 'GATEWAY_IMAGE', 'MONGO_IMAGE', 'REDIS_IMAGE', 'QDRANT_IMAGE', 'RUSTFS_IMAGE') { $c[$k] | Should -Match '@sha256:[0-9a-f]{64}$' }
        $c.BACKEND_IMAGE | Should -Be 'sales-agent-backend:1.0.0-cpu'
    }
    It 'writes owner-only files' -Skip:$IsWindows {
        Export-SAConfiguration $script:Cfg $script:Refs $script:P
        foreach ($f in $script:P.ConfigJson, $script:P.ComposeEnv, $script:P.BackendEnv, $script:P.FrontendEnv) {
            (& stat ($IsMacOS ? '-f' : '-c') ($IsMacOS ? '%Lp' : '%a') $f) | Should -Be '600'
        }
    }
}

Describe 'Secret redaction' {
    It 'masks registered values, secret keys and URL credentials' {
        Register-SASecret 'SuperSecretValue123'
        $t = Hide-SASecrets "x SuperSecretValue123`nGEMINI_API_KEY=abc`nmongodb://u:hunter2@mongo"
        $t | Should -Not -Match 'SuperSecretValue123|hunter2'
        $t | Should -Match 'GEMINI_API_KEY=\*{8}'
    }
}

Describe 'Images' {
    It 'refuses the unreleased placeholder registry' {
        { Get-SAImageRefs cpu } | Should -Throw '*not been released*'
    }
    It 'requires digests' {
        $saved = $script:Release.RegistryHost; $ns = $script:Release.RegistryNamespace
        try {
            $script:Release.RegistryHost = 'reg.example.net'; $script:Release.RegistryNamespace = 'acme'
            { Get-SAImageRefs cpu } | Should -Throw '*digest*'
            foreach ($k in @($script:Release.Images.Keys)) { $script:Release.Images[$k].Digest = 'sha256:' + ('b' * 64) }
            (Get-SAImageRefs cuda).backend | Should -Be ('reg.example.net/acme/sales-agent-backend@sha256:' + ('b' * 64))
        } finally {
            $script:Release.RegistryHost = $saved; $script:Release.RegistryNamespace = $ns
            foreach ($k in @($script:Release.Images.Keys)) { $script:Release.Images[$k].Digest = $null }
        }
    }
    It 'uses repository:tag with -UseLocalImages and never pulls application images' {
        (Get-SAImageRefs cpu -Local).frontend | Should -Be 'sales-agent-frontend:1.0.0'
        Mock docker { $global:LASTEXITCODE = 1 }
        { Sync-SAImages @{ backend = 'sales-agent-backend:9.9.9-cpu' } -Local } | Should -Throw '*not in the local Docker image store*'
        Should -Invoke docker -ParameterFilter { $args -contains 'pull' } -Times 0
    }
    It 'recognises registry authentication errors' {
        Test-SAAuthError 'unauthorized: authentication required' | Should -BeTrue
        Test-SAAuthError 'manifest unknown' | Should -BeFalse
    }
}

Describe 'Amazon ECR support' {
    It 'recognises ECR registry hosts and their region' {
        Get-SAEcrRegion '123456789012.dkr.ecr.ap-south-1.amazonaws.com' | Should -Be 'ap-south-1'
        Get-SAEcrRegion 'salesagentreg.azurecr.io' | Should -BeNullOrEmpty
    }
    It 'signs requests exactly like AWS (SigV4 test suite: get-vanilla)' {
        $a = New-SASigV4Authorization -Method GET -HostName 'example.amazonaws.com' -Headers @{} -Body '' -Region 'us-east-1' -Service 'service' `
            -AccessKey 'AKIDEXAMPLE' -SecretKey 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY' -AmzDate '20150830T123600Z'
        $a | Should -Be 'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31'
    }
    It 'treats an expired ECR token as an authentication error' {
        Test-SAAuthError 'Error response from daemon: pull access denied ... authorization token has expired' | Should -BeTrue
    }
}

Describe 'Embedded files' {
    It 'contain the gateway safety rules' {
        $n = $script:Embedded['gateway/nginx.conf']
        $n | Should -Match 'proxy_hide_header Access-Control-Allow-Origin'
        $n | Should -Match 'limit_except GET HEAD \{ deny all; \}'
        $n | Should -Match 'proxy_buffering off'
    }
    It 'publish only the gateway port' {
        ([regex]::Matches($script:Embedded['docker-compose.yml'], '(?m)^\s+ports:')).Count | Should -Be 1
    }
    It 'are valid for docker compose' -Skip:(-not (Get-Command docker -ErrorAction SilentlyContinue) -or (Get-Command docker).CommandType -eq 'Function') {
        Set-TestMode
        $cfg = (Resolve-SAConfiguration -FileValues (New-FileValues)).Config
        $cfg.values.SYSTEM_ADMIN_PASSWORD_HASH = $script:Hash
        $p = Get-SAPaths (Join-Path $TestDrive 'compose-check')
        Write-SARuntimeFiles $p $cfg
        Export-SAConfiguration $cfg @{ frontend = 'f:1'; backend = 'b:1'; db = 'd:1' } $p
        (Invoke-SACompose $p @('config', '--quiet') 'cuda' -AllowFailure).ExitCode | Should -Be 0
    }
}

Describe 'Versions and ports' {
    It 'compares versions' { Compare-SAVersion '1.10.0' '1.2.0' | Should -Be 1; Compare-SAVersion 'v2.20.2' '2.20.2' | Should -Be 0 }
    It 'detects a busy port' {
        $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start()
        try { Mock docker { }; Test-SAPortAvailable $l.LocalEndpoint.Port '127.0.0.1' | Should -BeFalse } finally { $l.Stop() }
    }
    It 'accepts a port held by its own stack' {
        Mock docker { 'sales-agent' }
        Test-SAPortAvailable 65001 '127.0.0.1' 'sales-agent' | Should -BeTrue
    }
}

Describe 'GPU selection' {
    It 'auto uses CUDA only when eligible' {
        Select-SAVariant auto ([pscustomobject]@{ HasNvidia = $true; Eligible = $true; Name = 'T4'; Driver = '560'; CudaVersion = '12.6'; Reason = $null }) 6>$null | Should -Be 'cuda'
        Select-SAVariant auto ([pscustomobject]@{ HasNvidia = $false; Eligible = $false; Reason = 'none' }) 6>$null | Should -Be 'cpu'
        Select-SAVariant cpu ([pscustomobject]@{ HasNvidia = $true; Eligible = $true; Name = 'T4'; Driver = '560'; CudaVersion = '12.6' }) 6>$null | Should -Be 'cpu'
    }
}

Describe 'Launchers' {
    It 'Windows launcher has CRLF line endings and calls the script' {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $script:Root 'Install-SalesAgent.cmd'))
        [Text.Encoding]::ASCII.GetString($bytes) | Should -Match "Install-SalesAgent\.ps1"
        ([Text.Encoding]::ASCII.GetString($bytes) -split "`r`n").Count | Should -BeGreaterThan 10
    }
    It 'macOS launcher is executable' -Skip:$IsWindows {
        (Get-Item (Join-Path $script:Root 'Install-SalesAgent.command')).UnixMode | Should -Match '^-rwx'
    }
}
