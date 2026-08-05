function Initialize-BRAVOCredentialManager {
    if ("BRAVO.Security.CredentialManager" -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security;
using System.Text;

namespace BRAVO.Security
{
    public sealed class StoredCredential
    {
        public string TargetName { get; internal set; }
        public string UserName { get; internal set; }

        // SecureString, а не string (аудит #5). Раніше секрет матеріалізувався
        // тут як звичайний managed string: у .NET він незмінний, тому його
        // НЕМОЖЛИВО занулити — копія пароля лишалась у керованій купі до
        // збирання сміття й могла потрапити у дамп процесу або в pagefile.
        // Кожне читання credential створювало ще одну таку копію, а
        // Archive/Health/Maintenance читають облікові дані кілька разів за
        // запуск. SecureString зберігається зашифрованим (DPAPI) і
        // звільняється детерміновано.
        public SecureString Secret { get; internal set; }
    }

    public static class CredentialManager
    {
        private const int CRED_TYPE_GENERIC = 1;
        private const int CRED_PERSIST_LOCAL_MACHINE = 2;
        private const int ERROR_NOT_FOUND = 1168;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct CREDENTIAL
        {
            public int Flags;
            public int Type;
            public string TargetName;
            public string Comment;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
            public int CredentialBlobSize;
            public IntPtr CredentialBlob;
            public int Persist;
            public int AttributeCount;
            public IntPtr Attributes;
            public string TargetAlias;
            public string UserName;
        }

        [DllImport("advapi32.dll", EntryPoint = "CredReadW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredRead(string target, int type, int flags, out IntPtr credentialPointer);

        [DllImport("advapi32.dll", EntryPoint = "CredWriteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredWrite(ref CREDENTIAL credential, int flags);

        [DllImport("advapi32.dll", EntryPoint = "CredDeleteW", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CredDelete(string target, int type, int flags);

        [DllImport("advapi32.dll", SetLastError = false)]
        private static extern void CredFree(IntPtr buffer);

        public static StoredCredential ReadGeneric(string target)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");

            IntPtr pointer;
            if (!CredRead(target, CRED_TYPE_GENERIC, 0, out pointer))
            {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_NOT_FOUND)
                    return null;
                throw new Win32Exception(error, "CredRead failed for target '" + target + "'.");
            }

            try
            {
                CREDENTIAL credential = (CREDENTIAL)Marshal.PtrToStructure(pointer, typeof(CREDENTIAL));
                SecureString secret = new SecureString();
                if (credential.CredentialBlob != IntPtr.Zero && credential.CredentialBlobSize > 0)
                {
                    byte[] secretBytes = new byte[credential.CredentialBlobSize];
                    Marshal.Copy(credential.CredentialBlob, secretBytes, 0, secretBytes.Length);
                    // Декодуємо в char[], а не в string: масив можна занулити,
                    // рядок — ні. Символи додаються в SecureString по одному,
                    // тому повного відкритого пароля не існує в керованій
                    // пам'яті на жодному кроці.
                    char[] secretChars = new char[secretBytes.Length / sizeof(char)];
                    try
                    {
                        Encoding.Unicode.GetChars(
                            secretBytes, 0, secretBytes.Length, secretChars, 0);
                        for (int i = 0; i < secretChars.Length; i++)
                        {
                            // Credential Manager доповнює блоб нулями.
                            if (secretChars[i] == '\0')
                                break;
                            secret.AppendChar(secretChars[i]);
                        }
                    }
                    finally
                    {
                        Array.Clear(secretChars, 0, secretChars.Length);
                        Array.Clear(secretBytes, 0, secretBytes.Length);
                    }
                }
                secret.MakeReadOnly();

                return new StoredCredential
                {
                    TargetName = credential.TargetName,
                    UserName = credential.UserName ?? String.Empty,
                    Secret = secret
                };
            }
            finally
            {
                CredFree(pointer);
            }
        }

        public static void WriteGeneric(string target, string userName, SecureString secret)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");
            if (secret == null || secret.Length == 0)
                throw new ArgumentException("Credential secret is empty.", "secret");

            IntPtr secretPointer = IntPtr.Zero;
            try
            {
                secretPointer = Marshal.SecureStringToCoTaskMemUnicode(secret);
                CREDENTIAL credential = new CREDENTIAL
                {
                    Flags = 0,
                    Type = CRED_TYPE_GENERIC,
                    TargetName = target,
                    Comment = "BRAVO protected credential",
                    CredentialBlobSize = checked(secret.Length * 2),
                    CredentialBlob = secretPointer,
                    Persist = CRED_PERSIST_LOCAL_MACHINE,
                    AttributeCount = 0,
                    Attributes = IntPtr.Zero,
                    TargetAlias = null,
                    UserName = userName ?? String.Empty
                };

                if (!CredWrite(ref credential, 0))
                {
                    int error = Marshal.GetLastWin32Error();
                    throw new Win32Exception(error, "CredWrite failed for target '" + target + "'.");
                }
            }
            finally
            {
                if (secretPointer != IntPtr.Zero)
                    Marshal.ZeroFreeCoTaskMemUnicode(secretPointer);
            }
        }

        public static bool DeleteGeneric(string target)
        {
            if (String.IsNullOrWhiteSpace(target))
                throw new ArgumentException("Credential target is empty.", "target");

            if (CredDelete(target, CRED_TYPE_GENERIC, 0))
                return true;

            int error = Marshal.GetLastWin32Error();
            if (error == ERROR_NOT_FOUND)
                return false;
            throw new Win32Exception(error, "CredDelete failed for target '" + target + "'.");
        }
    }
}
'@
}

function Get-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    Initialize-BRAVOCredentialManager
    return [BRAVO.Security.CredentialManager]::ReadGeneric($Target)
}

function Get-BRAVOCredentialSecureSecret {
    # Секрет, який НІКОЛИ не перетворюється на відкритий рядок. Використовуйте
    # цю функцію скрізь, де плейнтекст не потрібен — наприклад, там, де далі
    # будується PSCredential (SMB).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    $credential = Get-BRAVOCredential -Target $Target
    if ($null -eq $credential) {
        return $null
    }
    return $credential.Secret
}

function ConvertFrom-BRAVOSecureSecret {
    # Єдина точка перетворення SecureString -> відкритий рядок.
    #
    # ЧЕСНА МЕЖА (аудит #5, не обходьте її мовчки): рядок, повернутий звідси,
    # це звичайний managed string — незмінний, а отже незанулюваний. Він
    # лишається в керованій купі до збирання сміття. Ця функція прибирає
    # проміжну некеровану копію (BSTR зануляється детерміновано) і робить
    # кожне таке перетворення видимим у коді, але не усуває плейнтекст як
    # такий: SFTP-URL для WinSCP і пароль 7-Zip технічно потребують саме
    # рядка. Тому виклик цієї функції має бути якомога ближче до місця
    # використання, а не на початку runtime.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Функція навмисно повертає плейнтекст для API, які приймають лише рядок; межа задокументована.')]
    [CmdletBinding()]
    param(
        [AllowNull()]
        [Security.SecureString]$Secret
    )

    if ($null -eq $Secret) {
        return $null
    }

    $bstr = [IntPtr]::Zero
    try {
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Secret)
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
        if ($bstr -ne [IntPtr]::Zero) {
            # Некерована копія зануляється детерміновано, не чекаючи GC.
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

function Get-BRAVOCredentialSecret {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', '',
        Justification = 'Сумісність API: 19 місць runtime очікують рядок; плейнтекст створюється через ConvertFrom-BRAVOSecureSecret.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    $secureSecret = Get-BRAVOCredentialSecureSecret -Target $Target
    if ($null -eq $secureSecret) {
        return $null
    }
    return (ConvertFrom-BRAVOSecureSecret -Secret $secureSecret)
}

function Set-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target,

        [string]$UserName = "",

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$Secret
    )

    Initialize-BRAVOCredentialManager
    [BRAVO.Security.CredentialManager]::WriteGeneric($Target, $UserName, $Secret)
}

function Remove-BRAVOCredential {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Target
    )

    Initialize-BRAVOCredentialManager
    return [BRAVO.Security.CredentialManager]::DeleteGeneric($Target)
}

function Get-BRAVOCredentialIdentity {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Get-BRAVOArchivePasswordTarget {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'CredentialSettings',
        Justification = 'Хибне спрацювання: $CredentialSettings — це hashtable налаштувань (назви записів Credential Manager), не секрет.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CredentialSettings,

        [string]$InstitutionCode
    )

    $configuredTarget = [string]$CredentialSettings.Targets.ArchivePassword
    if (-not [string]::IsNullOrWhiteSpace($configuredTarget)) {
        return $configuredTarget
    }

    return "BRAVO_7Z_PASSWORD"
}

function Test-BRAVOInstitutionSettingValue {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet("InstitutionName", "InstitutionCode", "ArchivePrefix")]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $normalized = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        throw "$Name не може бути порожнім"
    }
    if ($normalized -match '[\x00-\x1F\x7F]') {
        throw "$Name містить керуючі символи"
    }

    switch ($Name) {
        "InstitutionName" {
            if ($normalized.Length -gt 160) {
                throw "InstitutionName не може бути довшим за 160 символів"
            }
        }
        "InstitutionCode" {
            if ($normalized -notmatch '^[\p{L}\p{Nd}._-]{1,64}$') {
                throw "InstitutionCode: дозволені лише літери, цифри, крапка, '_' і '-' (до 64 символів)"
            }
        }
        "ArchivePrefix" {
            if ($normalized -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$') {
                throw "ArchivePrefix повинен починатися з латинської літери/цифри; дозволені A-Z, 0-9, '.', '_' і '-' (до 80 символів)"
            }
            if ($normalized.EndsWith(".")) {
                throw "ArchivePrefix не може закінчуватися крапкою"
            }
        }
    }
    return $normalized
}

function Import-BRAVOInstitutionSettings {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'CredentialSettings',
        Justification = 'Хибне спрацювання: $CredentialSettings — це hashtable налаштувань (назви записів Credential Manager), не секрет.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        $CredentialSettings,

        [Parameter(Mandatory = $true)]
        $BravoSettings
    )

    $descriptors = @(
        [pscustomobject]@{
            Name = "InstitutionName"
            DefaultTarget = "BRAVO_INSTITUTION_NAME"
        },
        [pscustomobject]@{
            Name = "InstitutionCode"
            DefaultTarget = "BRAVO_INSTITUTION_CODE"
        },
        [pscustomobject]@{
            Name = "ArchivePrefix"
            DefaultTarget = "BRAVO_ARCHIVE_PREFIX"
        }
    )
    $results = New-Object System.Collections.ArrayList

    foreach ($descriptor in $descriptors) {
        $target = [string]$CredentialSettings.Targets[$descriptor.Name]
        if ([string]::IsNullOrWhiteSpace($target)) {
            $target = [string]$descriptor.DefaultTarget
        }

        $storedValue = Get-BRAVOCredentialSecret -Target $target
        $source = "CredentialManager"
        if ([string]::IsNullOrWhiteSpace($storedValue)) {
            $storedValue = [string]$BravoSettings[$descriptor.Name]
            $source = "ConfigurationFallback"
        }
        $normalizedValue = Test-BRAVOInstitutionSettingValue `
            -Name ([string]$descriptor.Name) `
            -Value $storedValue
        $BravoSettings[$descriptor.Name] = $normalizedValue

        [void]$results.Add([pscustomobject]@{
            Name = [string]$descriptor.Name
            Target = $target
            Source = $source
        })
        $storedValue = $null
        $normalizedValue = $null
    }

    # BRAVO.config створює ці похідні значення до читання Credential Manager.
    # Оновлюємо їх разом, щоб archive, maintenance і health мали один контекст.
    $global:archivePrefix = [string]$BravoSettings.ArchivePrefix
    if ($null -ne $global:maintenanceSettings -and
        $null -ne $global:maintenanceSettings.General) {
        $global:maintenanceSettings.General.ObjectName = (
            "$($BravoSettings.InstitutionName) [$($BravoSettings.InstitutionCode)]"
        )
        $global:maintenanceSettings.General.ArchivePrefix =
            [string]$BravoSettings.ArchivePrefix
    }
    if ($null -ne $global:backupMonitoring) {
        $global:backupMonitoring.InstitutionName =
            [string]$BravoSettings.InstitutionName
        $global:backupMonitoring.InstitutionCode =
            [string]$BravoSettings.InstitutionCode
    }

    return $results.ToArray()
}

function Resolve-BRAVOSftpHostName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [string]$HostTemplate,

        [string]$FallbackHostName
    )

    $normalizedUserName = $UserName.Trim()
    $resolvedHostName = ""

    if (-not [string]::IsNullOrWhiteSpace($HostTemplate)) {
        if ($HostTemplate -notmatch '\{0\}') {
            throw "SFTP host template must contain {0} for BRAVO_SFTP_LOGIN substitution"
        }
        try {
            $resolvedHostName = $HostTemplate.Trim() -f $normalizedUserName
        } catch {
            throw "Cannot build SFTP host from template '$HostTemplate': $($_.Exception.Message)"
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($FallbackHostName)) {
        # Compatibility with old BRAVO.config files that contain a full hostname.
        $resolvedHostName = $FallbackHostName.Trim()
    } else {
        throw "Neither sftpHostTemplate nor legacy sftpHost is configured"
    }

    $resolvedHostName = $resolvedHostName.Trim().TrimEnd(".")
    if ($resolvedHostName.Length -gt 253 -or
        $resolvedHostName -notmatch '^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$') {
        throw "Invalid SFTP host was generated: '$resolvedHostName'"
    }

    return $resolvedHostName.ToLowerInvariant()
}

function New-BRAVOSftpUrl {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Мета функції — побудувати рядок sftp://user:pass@host для WinSCP; SecureString неможливо вставити в URL.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'PSCredential тут не підійде: WinSCP отримує саме рядковий URL з логіном і паролем.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$HostName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password,

        [ValidateRange(1, 65535)]
        [int]$Port = 22
    )

    $escapedUserName = [Uri]::EscapeDataString($UserName)
    $escapedPassword = [Uri]::EscapeDataString($Password)
    $portSuffix = if ($Port -eq 22) { "" } else { ":$Port" }
    return "sftp://${escapedUserName}:${escapedPassword}@${HostName}${portSuffix}/"
}

function New-BRAVOPlainTextCredential {
    # Єдине місце в runtime, де секрет із Credential Manager конвертується
    # в SecureString для .NET API, що приймає лише PSCredential. Раніше цей
    # самий блок був продубльований у BRAVO.Archive.Runtime.ps1 і
    # BRAVO.Health.Runtime.ps1 — тепер точкове виключення PSScriptAnalyzer
    # стоїть тут, а не глобально на весь репозиторій, тому будь-яке НОВЕ
    # входження ConvertTo-SecureString -AsPlainText поза цією функцією
    # заблокує CI.
    #
    # Secret походить із Windows Credential Manager (уже захищене сховище),
    # а не з джерела чи конфігурації — це міст до API, а не хардкод.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Секрет прочитаний із Windows Credential Manager; SecureString потрібен лише для конструктора PSCredential.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingPlainTextForPassword', 'Password',
        Justification = 'Get-BRAVOCredentialSecret повертає рядок; SecureString створюється тут же і одразу передається в PSCredential.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Функція саме і будує PSCredential з окремо збережених у Credential Manager логіна та пароля.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Password
    )

    $securePassword = ConvertTo-SecureString -String $Password -AsPlainText -Force
    return New-Object System.Management.Automation.PSCredential($UserName, $securePassword)
}

function New-BRAVOSecureCredential {
    # Те саме, що New-BRAVOPlainTextCredential, але БЕЗ проміжного
    # плейнтексту: секрет іде з Credential Manager у PSCredential, жодного
    # разу не ставши звичайним рядком. Саме цей шлях треба використовувати
    # скрізь, де далі потрібен лише PSCredential (SMB) — там плейнтекст не
    # потрібен узагалі, і платити за нього незанулюваною копією в пам'яті
    # немає причин.
    #
    # New-BRAVOPlainTextCredential лишається для випадків, де рядок уже
    # існує з інших причин.
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingUsernameAndPasswordParams', '',
        Justification = 'Функція будує PSCredential з окремо збережених у Credential Manager логіна та SecureString-секрету.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName,

        [Parameter(Mandatory = $true)]
        [Security.SecureString]$SecureSecret
    )

    return New-Object System.Management.Automation.PSCredential($UserName, $SecureSecret)
}
