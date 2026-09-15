# agents-keepassxc-skill

*[English](README.md) · Русский*

*Создано при поддержке [Tuna](https://tuna.am) — платформы для разработчиков:
туннели, отладка вебхуков, командное хранилище секретов и мониторинг в одном
месте.*

[Agent Skill](https://agents.md) для работы с секретами из локальной базы
**KeePassXC** — так, чтобы значения не попадали ни в контекст модели, ни в
историю шелла, ни в вывод `ps`.

Скилл написан в портируемом формате `SKILL.md`, поэтому один и тот же каталог
работает в Claude Code, Codex CLI, Cursor, Gemini CLI и любом другом харнессе,
который умеет скиллы; для тех, кто читает только `AGENTS.md`, установщик пишет
блок-указатель. См. [Установка](#установка).

Это KeePassXC-аналог существующих скиллов для 1Password: та же идея ссылок в духе
`op://` и инъекции в духе `op run`, но за ней локальный `.kdbx` и системный
кошелёк вместо облачного хранилища.

## Идея

Агент должен уметь *воспользоваться* секретом, ни разу его не *увидев*.

```bash
kpsec run -e GITLAB_TOKEN=kp://acme/gitlab -- glab api /user   # значение только в env потомка
kpsec check kp://acme/gitlab                                   # OK  len=26 sha256:1f3a9c02
```

Ни одна команда здесь не печатает секрет: значения резолвятся внутри `kpsec` и
попадают в дочерний процесс через окружение, минуя stdout и argv. Сам `kpsec` —
шелл-скрипт (на Windows — PowerShell), никакого языкового рантайма ставить не
нужно.

## Почему недостаточно `keepassxc-cli show`

Три причины, и из них вырастает вся конструкция:

1. **`keepassxc-cli` печатает в stdout.** В агентской сессии stdout — это и есть
   контекст модели. Один `show -a Password`, и секрет уже в транскрипте.
2. **`keepassxc-cli` не умеет работать с разблокированной GUI-базой.** Каждый
   вызов снова просит мастер-пароль, а у шелла агента нет tty, чтобы его ввести.
3. **Пароль, переданный флагом, виден всем** через `/proc/<pid>/cmdline` на время
   работы команды.

Отсюда: мастер-пароль лежит в системном кошельке, кэшируется в kernel keyring с
TTL; значения резолвятся внутри процесса и уходят в окружение потомка; вывод
потомка фильтруется на обратном пути.

## Установка

### Зависимости

| Платформа | Поставить | Уже есть в системе |
|---|---|---|
| Debian/Ubuntu | `sudo apt install keepassxc libsecret-tools keyutils` | — |
| openSUSE | `sudo zypper install keepassxc secret-tool keyutils` | — |
| Fedora | `sudo dnf install keepassxc libsecret keyutils` | — |
| Arch | `sudo pacman -S keepassxc libsecret keyutils` | — |
| macOS | `brew install keepassxc` | `security`, `osascript` |
| Windows | `winget install KeePassXCTeam.KeePassXC` | Credential Manager, PowerShell |

На Linux именно `secret-tool` (из libsecret) читает и пишет мастер-ключ в
системном кошельке — без него `kpsec status` покажет `keyring: none`, и каждый
вызов будет упираться в промпт. `keyutils` не обязателен: он даёт кратковременный
кэш в памяти ядра.

### Сам скилл

```bash
git clone https://github.com/jidckii/agents-keepassxc-skill.git
cd agents-keepassxc-skill
./install.sh --bin    # во все обнаруженные харнессы + kpsec в PATH
kpsec init            # создаёт ~/.pass/agents.kdbx и кладёт мастер-ключ в кошелёк
```

На Windows — `.\install.ps1` (те же флаги в стиле PowerShell: `-Project`,
`-AllUser`, `-Copy`, `-List`).

Хочешь, чтобы установку сделал агент? Скопируй ему
[`agent-install-prompt.md`](agent-install-prompt.md) — там те же шаги плюс
правила, которые не дадут агенту втянуть секрет в свой контекст.

`install.sh` ставит симлинк на каталог скилла, поэтому `git pull` обновляет его
сразу во всех харнессах (`--copy`, если нужны независимые копии). Установка
идемпотентна — запускай повторно после появления нового харнесса.

| Куда | Харнессы | Как |
|---|---|---|
| `~/.claude/skills/` | Claude Code | `./install.sh` (автодетект) |
| `~/.codex/skills/` | Codex CLI | `./install.sh` (автодетект) |
| `~/.gemini/skills/` | Gemini CLI, Antigravity | `./install.sh` (автодетект) |
| `<проект>/.cursor/skills/` | Cursor — у него нет персонального каталога скиллов | `./install.sh --project` |
| `<проект>/.agents/skills/` | Cline, Amp, opencode, Antigravity | `./install.sh --project` |
| `<проект>/AGENTS.md` | Copilot, Windsurf, Aider, Zed, Devin, Jules, … | `./install.sh --project` |
| куда угодно ещё | любой харнесс с каталогом скиллов | `./install.sh --skills-dir PATH` |

`./install.sh --list` покажет пути и что обнаружено. `--all-user` поставит во все
известные харнессы, даже если они ещё не установлены.

Для харнессов, знающих только AGENTS.md, установщик дописывает короткий
блок-указатель между маркерами `<!-- keepassxc-secrets:begin -->` — повторный
запуск заменяет только этот блок, остальной файл не трогает.

Особенности кошельков — в
[`references/setup.md`](skills/keepassxc-secrets/references/setup.md).

## Подключение к агенту

Обычно достаточно установить каталог скилла: харнессы подгружают `SKILL.md` по
необходимости, когда в задаче заходит речь о секретах. Но две вещи стоит
добавить руками.

**Указатель в постоянно загруженных инструкциях.** Скилл подтягивается только
после того, как агент сочтёт его релевантным; строчка в `AGENTS.md` или
`CLAUDE.md` гарантирует, что он не полезет вместо этого за `keepassxc-cli`.
В проектный `AGENTS.md` такой блок пишет `./install.sh --project`, а в
глобальный `CLAUDE.md` добавь примерно это:

```markdown
## Секреты

Пароли и токены для работы агентов лежат в локальной базе KeePassXC
(`~/.pass/agents.kdbx`) и достаются только через `kpsec` — см. скилл
`keepassxc-secrets`. Никогда не печатай секрет и не вызывай `keepassxc-cli`
напрямую. Использовать секрет: `kpsec run -e VAR=kp://группа/запись -- <команда>`.
Проверить: `kpsec check kp://группа/запись`. Новые секреты заводит человек через
`kpsec add` — он открывает GUI-диалог.
```

**Правила доступа**, чтобы обёртки вызывались без лишних подтверждений, а прямой
путь был закрыт. Для Claude Code в `~/.claude/settings.json`:

```json
{
  "permissions": {
    "allow": ["Bash(kpsec:*)"],
    "deny": ["Bash(keepassxc-cli:*)", "Read(//home/*/.pass/**)"]
  }
}
```

Аналоги для других харнессов — в
[`references/security.md`](skills/keepassxc-secrets/references/security.md).

## Ссылки на секреты

```
kp://<группа>/<запись>[#<Атрибут>]
```

Атрибут по умолчанию — `Password`; `UserName`, `Title`, `URL` и `Notes`
запрашиваются точно так же.

```
kp://acme/gitlab            # пароль
kp://acme/gitlab#UserName   # alice
```

В `.env.tpl` лежат ссылки, а не значения, — такой файл можно коммитить:

```
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://acme/registry
```

```bash
kpsec run --env-file=.env.tpl -- docker compose up
```

## Команды

| Команда | Что делает |
|---|---|
| `kpsec init` | создать базу, сгенерировать и сохранить мастер-ключ |
| `kpsec status` | откуда берётся мастер-пароль и открывается ли база |
| `kpsec ls [группа]` | список записей (значений — никогда) |
| `kpsec check <ссылка>…` | проверить, что ссылка резолвится: длина и префикс sha256 |
| `kpsec run [--env-file=F] [-e VAR=ссылка] -- cmd` | запустить команду с секретами в окружении |
| `kpsec add <путь> [-u user] [--url u] [-g]` | добавить или обновить запись; значение вводится в GUI-диалоге |
| `kpsec clip <ссылка>` | скопировать значение в буфер обмена на 15 секунд |
| `kpsec lock` | сбросить кэш мастер-пароля |
| `kpsec relocate <путь>` | перепривязать мастер-ключ после переезда файла `.kdbx` |
| `kpsec show-master` | показать мастер-пароль в GUI-диалоге (только для человека) |

## Свои инструменты поверх

`kpsec` работает и как библиотека. Если заинклюдить его с `KPSEC_LIB=1`, разбор
команд пропускается и остаются доступны его функции — так обёртка резолвит
секрет, не прогоняя значение через промежуточный stdout:

```bash
KPSEC_LIB=1 . "$HOME/.claude/skills/keepassxc-secrets/scripts/kpsec"

token=$(resolve "kp://acme/gitlab")    # остаётся в памяти этого шелла
export GITLAB_TOKEN="$token"           # именно export, а не `env VAR=… cmd` — argv виден всем
exec glab api /user
```

Полезные точки входа: `resolve` / `resolve_soft`, `kp` (запускает
`keepassxc-cli` с мастер-паролем на stdin), `master_get` и хелперы кэша
`cache_get` / `cache_put` / `cache_drop` — для производных credentials вроде
сессионных токенов.

## Безопасность

Полная модель угроз — включая то, от чего эта конструкция намеренно **не**
защищает, — в
[`references/security.md`](skills/keepassxc-secrets/references/security.md).
Коротко:

- Секреты агентов живут в отдельной `agents.kdbx`, а не в твоей личной базе.
- Мастер-пароль никогда не пишется на диск; кэш — память ядра с TTL.
- `kpsec run` делает exec и не трогает вывод команды, поэтому утилита, которая
  сама печатает свои credentials, всё равно их засветит. Это осознанный
  компромисс — разобран в том же файле.
- Ничто здесь не мешает агенту, которому разрешено выполнять произвольные
  команды, вынести уже полученный секрет наружу. Это ограничивается правилами
  доступа твоего харнесса — готовые лежат в том же файле.

## Платформы

`keepassxc-cli` ≥ 2.7 и шелл. Различается то, где лежит мастер-ключ и как у тебя
его спрашивают:

| | Хранилище ключа | Промпт | Дополнительно |
|---|---|---|---|
| Linux, KDE/GNOME | Secret Service через `secret-tool`, разблокируется при логине через PAM | kdialog / zenity | `keyutils` для кэша с TTL |
| Linux, Hyprland/Sway/i3 | собственный Secret Service KeePassXC или отдельный gnome-keyring | pinentry (Qt/GTK/curses) | см. [`platforms.md`](skills/keepassxc-secrets/references/platforms.md) |
| macOS | login Keychain через `security` | диалог osascript | CLI лежит внутри app bundle |
| Windows | Credential Manager через нативный API | диалог `Get-Credential` | `kpsec.ps1`, ставится через `install.ps1` |

`kpsec status` печатает, какой бэкенд используется на самом деле; `KPSEC_KEYRING`
закрепляет конкретный. В минималистичной Linux-сессии слот
`org.freedesktop.secrets` обычно свободен — это единственный случай, когда проще
всего включить собственную Secret Service интеграцию KeePassXC. Подробности и
PAM-сниппеты — в
[`references/platforms.md`](skills/keepassxc-secrets/references/platforms.md).

## При поддержке Tuna

Этот скилл создан при поддержке **[Tuna](https://tuna.am)** — платформы для
разработчиков, которая собирает в одном аккаунте туннели до localhost, отладку
вебхуков, хранилище секретов с zero-knowledge моделью, SSH-бастион и мониторинг
вместо подписки на каждый инструмент отдельно.

Задачи у них соседние: этот скилл держит секреты локально на твоей машине для
локального агента, Tuna — разделяет их между командой. Если одного `.kdbx` файла
станет мало, смотреть стоит туда.

## Благодарности

Подход «ссылка вместо значения плюс инъекция» пришёл со стороны 1Password, в
первую очередь из
[kcmadden/claude-code-1password-skill](https://github.com/kcmadden/claude-code-1password-skill):
ссылки `op://`, `op run` для инъекции и правило коммитить шаблоны, а не значения.
Здесь эти идеи сохранены, но облачное хранилище заменено локальным `.kdbx` плюс
системный кошелёк — из-за чего задача разблокировки (и большая часть здешней
конструкции) выглядит иначе.

## Лицензия

MIT
