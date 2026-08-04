@{
    # Налаштування PSScriptAnalyzer для BRAVO Archive.
    #
    # МОДЕЛЬ: два проходи в CI (.github/workflows/ci.yml).
    #
    #   1. БЛОКУЮЧИЙ прохід — рівно набір Severity-правил нижче
    #      (`IncludeRules`). Жодне з них НЕ виключається глобально:
    #      кожне обґрунтоване місце має точковий
    #      [Diagnostics.CodeAnalysis.SuppressMessageAttribute] біля
    #      конкретної функції з полем Justification. Тому будь-яке НОВЕ
    #      входження цих патернів у будь-якому файлі завалить CI, навіть
    #      якщо десь поруч уже є легітимне обґрунтоване використання.
    #
    #   2. ІНФОРМАЦІЙНИЙ прохід — усі інші правила, лише виводяться як
    #      ::warning без блокування (стилістика, яка суперечить усталеній
    #      архітектурі репозиторію: Write-Host для інтерактивної консолі
    #      допоміжних скриптів, $global: як контракт між BRAVO.config і
    #      runtime-модулями).
    #
    # Чому саме цей файл, а не -ExcludeRule у workflow: глобальний
    # -ExcludeRule означав, що новий небезпечний код теж мовчки проходив
    # CI. Точкові suppressions прив'язані до конкретної функції й видимі
    # при код-рев'ю разом зі змінами.

    IncludeRules = @(
        # --- Секрети та облікові дані ---
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        'PSUsePSCredentialType',

        # --- Виконання довільного коду ---
        'PSAvoidUsingInvokeExpression',

        # --- Мережа та зовнішні залежності ---
        'PSAvoidUsingComputerNameHardcoded',

        # --- Криптографія ---
        'PSAvoidUsingBrokenHashAlgorithms',

        # --- Коректність, дешева в підтримці, без хибних спрацювань ---
        'PSPossibleIncorrectComparisonWithNull',
        'PSAvoidUsingCmdletAliases'

        # PSUseDeclaredVarsMoreThanAssignments свідомо НЕ блокує: воно дає
        # хибні спрацювання на змінних, які читаються в іншому scope
        # (перевірено — з 5 знахідок 3 виявились хибними). Лишається в
        # інформаційному проході.
    )
}
