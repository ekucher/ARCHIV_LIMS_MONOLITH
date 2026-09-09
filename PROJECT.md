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

## Мова документації

Основна мова документації BRAVO-Toolkit — українська.

Українською мовою мають викладатися:

- заголовки та підзаголовки;
- пояснювальний текст;
- архітектурні рішення;
- статуси й roadmap-пояснення;
- вимоги;
- критерії готовності;
- operator documentation;
- design documentation;
- security/threat-model explanations;
- migration/activation/rollback/recovery explanations;
- пояснення до прикладів.

Англійська мова допустима там, де важливо зберегти точну технічну
ідентичність:

- file/directory names;
- identifiers;
- PowerShell function/class/parameter names;
- enum/status literal values;
- environment variables;
- CLI commands;
- code;
- exact logs/output;
- API/protocol/standard names;
- Git/GitHub object names;
- product/proper names;
- established engineering terms where translation reduces precision.

Ключовий принцип: англійський технічний термін може використовуватися
всередині українського речення, але цілі пояснювальні речення, абзаци
та заголовки не повинні залишатися англійською лише через наявність
технічної термінології.

Точні цитати й upstream-докази (логи, вивід програм, зовнішні
специфікації) можуть залишатися мовою оригіналу, коли важлива саме
точність цитати.

## Основні модулі

До функціональних областей toolkit належать Archive, Health, Maintenance, DataRestore, BazaSync, Notifications, Credentials, Discovery, ExitCodes, Console, Compatibility, System та інші модулі простору імен `BRAVO.*`.

Канонічні built-in дефолти й deterministic deep merge конфігурації живуть у `modules/BRAVO.Configuration/` (`BRAVO.Configuration.psm1`, `BRAVO.Configuration.Derivation.psm1`); orchestration і snapshot-виконання опційного `BRAVO.config`/`BRAVO.local.config` лишається за кореневим `BRAVO_CONFIG_LOADER.ps1`, який імпортує цей модуль. Детальніше — `docs/design/BRAVO_CONFIGURATION_FOUNDATION_DESIGN.md`.

Назва `Archive` використовується для конкретної функції резервного копіювання і не є назвою всього проєкту.

## План розвитку

Актуальний порядок пріоритетів і послідовність реалізації визначені в [ROADMAP.md](ROADMAP.md). Детальні технічні design notes для великих функцій зберігаються в [TODO_FEATURES.md](TODO_FEATURES.md); якщо порядок у цих документах відрізняється, пріоритет має `ROADMAP.md`.
