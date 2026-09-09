# BRAVO-Toolkit

`BRAVO-Toolkit` — модульний набір PowerShell-інструментів для архівації, перевірки стану, обслуговування, відновлення даних, керування обліковими даними, сповіщеннями та завданнями Windows Task Scheduler у середовищі BRAVO/LIMS.

## Архітектурний принцип

Проєкт будується як модульна система з тонкими кореневими entrypoint-скриптами. Це не один великий скрипт: кожна функціональна область має власний модуль і канонічного власника логіки.

- кореневі `BRAVO_*.ps1` відповідають за параметри запуску, bootstrap та orchestration;
- прикладна й доменна логіка розміщується у `modules/BRAVO.<Domain>/`;
- кожна policy, algorithm, parser або helper має одного канонічного власника;
- спільна функціональність виноситься лише у чітко визначені cross-cutting модулі;
- нова функціональність не повинна збільшувати root entrypoint, якщо її можна розмістити у відповідному доменному модулі;
- цільова платформа виконання — Windows PowerShell 5.1.

## Основні модулі

До функціональних областей toolkit належать Archive, Health, Maintenance, DataRestore, BazaSync, Notifications, Credentials, Discovery, ExitCodes, Console, Compatibility, System та інші модулі простору імен `BRAVO.*`.

Канонічні built-in дефолти й deterministic deep merge конфігурації живуть у `modules/BRAVO.Configuration/` (`BRAVO.Configuration.psm1`, `BRAVO.Configuration.Derivation.psm1`); orchestration і snapshot-виконання опційного `BRAVO.config`/`BRAVO.local.config` лишається за кореневим `BRAVO_CONFIG_LOADER.ps1`, який імпортує цей модуль. Детальніше — `docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.

Назва `Archive` використовується для конкретної функції резервного копіювання і не є назвою всього проєкту.

## План розвитку

Актуальний порядок пріоритетів і послідовність реалізації визначені в [ROADMAP.md](ROADMAP.md). Детальні технічні design notes для великих функцій зберігаються в [TODO_FEATURES.md](TODO_FEATURES.md); якщо порядок у цих документах відрізняється, пріоритет має `ROADMAP.md`.
