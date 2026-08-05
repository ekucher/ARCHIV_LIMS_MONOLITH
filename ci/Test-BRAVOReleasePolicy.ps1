[CmdletBinding()]
param(
    [string]$Root,
    [string]$Branch
)

# Перевірка RELEASE_POLICY.md: гілка <-> packageVersion <-> releaseChannel.
#
# RELEASE_POLICY.md, розділ 5.4: раніше releaseChannel зберігався
# однаковим на обох гілках, а реальне значення виводилось із .git/HEAD —
# саме тому, що ручна синхронізація двічі підвела при fast-forward. Тепер
# джерелом істини знову є VERSION.json (пакет на сервері може не мати
# .git взагалі), а замість людської дисципліни працює цей скрипт: якщо
# гілка, версія й канал не узгоджені — CI червоніє ще до merge.
#
# Запускається без параметрів і локально, і в GitHub Actions.

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = Split-Path -Parent $PSScriptRoot
}
if (-not (Test-Path -LiteralPath (Join-Path $Root 'BRAVO_SELF_TEST.ps1') -PathType Leaf)) {
    Write-Host "Не схоже на корінь репозиторію BRAVO: $Root" -ForegroundColor Red
    exit 1
}

$failures = New-Object System.Collections.ArrayList

function Add-BRAVOReleasePolicyFailure {
    param([Parameter(Mandatory = $true)][string]$Message)
    [void]$failures.Add($Message)
    Write-Host "::error::$Message"
}

function Resolve-BRAVOReleasePolicyBranch {
    param([Parameter(Mandatory = $true)][string]$RepositoryRoot)

    # У Pull Request значення має сенс брати з цільової гілки: promotion
    # developer -> master несе вже stable-версію, і перевіряти її треба
    # правилами master, а не гілки, з якої PR відкрито.
    foreach ($variableName in @('GITHUB_BASE_REF', 'GITHUB_REF_NAME')) {
        $value = [Environment]::GetEnvironmentVariable($variableName)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }

    $gitHeadPath = Join-Path $RepositoryRoot '.git\HEAD'
    if (Test-Path -LiteralPath $gitHeadPath -PathType Leaf) {
        $headContent = (Get-Content -LiteralPath $gitHeadPath -Raw -ErrorAction SilentlyContinue)
        if ($headContent -match '^ref:\s*refs/heads/(?<Branch>.+)$') {
            return $Matches.Branch.Trim()
        }
    }

    return $null
}

$versionPath = Join-Path $Root 'VERSION.json'
$version = [IO.File]::ReadAllText($versionPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$packageVersion = [string]$version.packageVersion
$releaseChannel = [string]$version.releaseChannel

$branch = if (-not [string]::IsNullOrWhiteSpace($Branch)) { $Branch.Trim() } else { Resolve-BRAVOReleasePolicyBranch -RepositoryRoot $Root }

# Гілка невідома лише у detached HEAD або в розпакованому архіві без
# .git — там ця перевірка нічого не охороняє, тому не вигадуємо режим.
if ([string]::IsNullOrWhiteSpace($branch)) {
    Write-Host "Гілку визначити не вдалося (detached HEAD або копія без .git) — перевірку пропущено." -ForegroundColor Yellow
    exit 0
}

$isStableBranch = $branch -in @('master', 'main')

Write-Host "Гілка:          $branch"
Write-Host "packageVersion: $packageVersion"
Write-Host "releaseChannel: $releaseChannel"
Write-Host ""

$stablePattern = '^\d+\.\d+\.\d+$'
$prereleasePattern = '^\d+\.\d+\.\d+-(dev|rc)\.\d+$'

if ($isStableBranch) {
    if ($packageVersion -notmatch $stablePattern) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 2.2: на гілці '$branch' дозволені лише stable-версії X.Y.Z, а packageVersion = '$packageVersion'."
    }
    if ($releaseChannel -ne 'stable') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: на гілці '$branch' releaseChannel має бути 'stable', а не '$releaseChannel'."
    }
} else {
    if ($packageVersion -notmatch $prereleasePattern) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 2.1: поза master дозволені лише prerelease-версії X.Y.Z-dev.N або X.Y.Z-rc.N, а packageVersion = '$packageVersion'."
    }
    if ($releaseChannel -notin @('development', 'prerelease')) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: поза master releaseChannel має бути 'development' або 'prerelease', а не '$releaseChannel'."
    }
    if ($packageVersion -match '-dev\.\d+$' -and $releaseChannel -ne 'development') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: версія '$packageVersion' це dev-реліз, тому releaseChannel має бути 'development', а не '$releaseChannel'."
    }
    if ($packageVersion -match '-rc\.\d+$' -and $releaseChannel -ne 'prerelease') {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.3: версія '$packageVersion' це release candidate, тому releaseChannel має бути 'prerelease', а не '$releaseChannel'."
    }
}

# RELEASE_POLICY 3.4: ModuleVersion не приймає prerelease-суфікса
# ([System.Version]), тому маніфести модулів несуть базову частину.
$baseVersion = ($packageVersion -replace '-.*$', '')
if ($baseVersion -notmatch $stablePattern) {
    Add-BRAVOReleasePolicyFailure "packageVersion '$packageVersion' не має вигляду X.Y.Z[-suffix] — базову версію визначити неможливо."
} else {
    $manifests = @(Get-ChildItem -LiteralPath (Join-Path $Root 'modules') -Recurse -Filter '*.psd1' -File)
    if ($manifests.Count -eq 0) {
        Add-BRAVOReleasePolicyFailure "У modules\ не знайдено жодного .psd1 — перевірка ModuleVersion не має сенсу."
    }
    foreach ($manifest in $manifests) {
        $manifestVersion = [string](Test-ModuleManifest -Path $manifest.FullName -ErrorAction Stop).Version
        if ($manifestVersion -ne $baseVersion) {
            Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 3.4: $($manifest.Name) має ModuleVersion '$manifestVersion', очікується базова версія '$baseVersion' (з packageVersion '$packageVersion')."
        }
    }
}

# RELEASE_POLICY 14.3: версія має бути описана в CHANGELOG.md і в
# заголовках документації — інакше на сервері неможливо звірити, що саме
# розгорнуто.
$changelogText = [IO.File]::ReadAllText((Join-Path $Root 'CHANGELOG.md'), [Text.Encoding]::UTF8)
if (-not $changelogText.Contains($packageVersion)) {
    Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 14.3: CHANGELOG.md не містить розділу для версії '$packageVersion'."
}

foreach ($documentName in @('README.md', 'BRAVO_SETUP.md')) {
    $documentPath = Join-Path $Root $documentName
    $firstLine = ([IO.File]::ReadAllLines($documentPath, [Text.Encoding]::UTF8))[0]
    if (-not $firstLine.Contains($packageVersion)) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 14.3: заголовок $documentName ('$firstLine') не містить версії '$packageVersion'."
    }
}

# RELEASE_POLICY 5.4: .git більше не джерело каналу, але поки він поруч —
# він безкоштовна перехресна перевірка того самого твердження.
$loaderPath = Join-Path $Root 'BRAVO_CONFIG_LOADER.ps1'
. $loaderPath
$gitChannel = Resolve-BRAVOReleaseChannelFromGit -ConfigRoot $Root
if (-not [string]::IsNullOrWhiteSpace($gitChannel)) {
    $expectedForGitChannel = if ($gitChannel -eq 'stable') { @('stable') } else { @('development', 'prerelease') }
    if ($releaseChannel -notin $expectedForGitChannel) {
        Add-BRAVOReleasePolicyFailure "RELEASE_POLICY 5.4: .git/HEAD вказує на канал '$gitChannel', а VERSION.json містить '$releaseChannel' — одне з двох неправильне."
    }
}

Write-Host ""
if ($failures.Count -gt 0) {
    Write-Host "RELEASE_POLICY: порушень — $($failures.Count)" -ForegroundColor Red
    exit 1
}

Write-Host "RELEASE_POLICY: гілка, версія і канал узгоджені." -ForegroundColor Green
exit 0
