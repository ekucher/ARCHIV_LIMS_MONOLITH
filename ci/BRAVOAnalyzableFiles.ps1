function Get-BRAVOAnalyzableFile {
    <#
        Повертає PowerShell-файли, що реально належать репозиторію.

        Джерело правди — `git ls-files`, а не обхід файлової системи:
        інакше локальний запуск аналізує й каталоги, які git ігнорує
        (`local-backups/` через .git/info/exclude, `LOGS/` через
        .gitignore), і дає знахідки, яких CI ніколи не побачить — бо у
        checkout цих файлів немає. Розбіжність між локальним і CI
        результатом гірша за саму знахідку.

        Якщо git недоступний (розпакований архів дистрибутиву без
        .git), відкочується на обхід файлової системи.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root
    )

    $extensions = @('.ps1', '.psm1', '.psd1')

    $gitCommand = Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue
    if ($null -ne $gitCommand -and (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        try {
            $tracked = & git -C $Root ls-files --cached --others --exclude-standard 2>$null
            if ($LASTEXITCODE -eq 0 -and $tracked) {
                return @(
                    $tracked |
                        Where-Object { [IO.Path]::GetExtension($_) -in $extensions } |
                        ForEach-Object { Join-Path $Root $_ } |
                        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
                        ForEach-Object { Get-Item -LiteralPath $_ }
                )
            }
        } catch {
            # Свідомий fallback нижче: git є, але репозиторій у стані,
            # де ls-files не працює (пошкоджений індекс, submodule).
            Write-Host "::warning::git ls-files недоступний, аналізуємо файлову систему: $($_.Exception.Message)"
        }
    }

    return @(
        Get-ChildItem -LiteralPath $Root -Recurse -File |
            Where-Object { $_.Extension -in $extensions }
    )
}
