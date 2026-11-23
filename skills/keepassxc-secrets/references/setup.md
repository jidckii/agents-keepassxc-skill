# Setup notes

## Requirements

The scripts are `bash` (Linux, macOS) and PowerShell (Windows). There is no
language runtime to install, except Python with `pykeepass` for
`kpsec set` (on Linux and macOS only).

| Component | Why | Required |
|---|---|---|
| `keepassxc-cli` ≥ 2.7 | reads the database | yes |
| `secret-tool` (libsecret) | master password in the desktop keyring | Linux |
| `security` | same, via the login Keychain | ships with macOS |
| Credential Manager | same, via the native API | ships with Windows |
| `keyctl` (keyutils) | in-memory cache with a TTL (Linux only) | optional |
| `kdialog`, `zenity` or `pinentry` | prompts and one-off displays | optional |
| `pykeepass` (or `uv` to fetch it) | `kpsec set` — `keepassxc-cli` cannot write custom attributes | optional |

```bash
# Debian/Ubuntu
sudo apt install keepassxc libsecret-tools keyutils

# openSUSE
sudo zypper install keepassxc secret-tool keyutils

# Fedora
sudo dnf install keepassxc libsecret keyutils

# macOS — Keychain and osascript are already there
brew install keepassxc

# Windows — Credential Manager and PowerShell are already there
winget install KeePassXCTeam.KeePassXC
```

macOS uses the login Keychain and Windows the Credential Manager — see
[`platforms.md`](platforms.md), which also covers tiling WMs without a keyring.

## First run

```bash
./install.sh --bin         # install for detected harnesses and put kpsec on PATH
kpsec init                 # creates the database, generates and stores the master key
kpsec status               # should print "unlock: ok"
```

Without `--bin` the commands live at `<skill>/scripts/kpsec`, where `<skill>` is
the install path for your harness (`~/.claude/skills/keepassxc-secrets`,
`~/.codex/skills/keepassxc-secrets`, `<project>/.cursor/skills/keepassxc-secrets`,
…). `./install.sh --list` prints them.

`init` shows the generated master password once, in a GUI dialog. Copy it into
your main password manager — it is your only way back into the database if the
desktop keyring is lost. To see it again: `kpsec show-master`.

To open the database by hand, point KeePassXC at `~/.pass/agents.kdbx`
and use that master password.

## Which keyring is actually used

The scripts talk to whatever owns `org.freedesktop.secrets`:

- **KDE Plasma 6** — `ksecretd`, exposing the `kdewallet` collection. Note that
  `kwallet-query` will not find these entries: it speaks the older
  `org.kde.kwalletd6` interface and reports "folder does not exist". This is
  expected, not a broken setup.
- **GNOME** — `gnome-keyring-daemon`, the `login` collection.
- **Anything else with libsecret** — works as long as a provider is registered.

Check what is running:

```bash
busctl --user list | grep secrets
secret-tool search --all application kpsec
```

If the collection is locked, the scripts fall back to a GUI password prompt.

## Headless use

Set `KPSEC_NO_GUI=1`. Without a keyring entry the scripts then exit with code 4
rather than trying to open a dialog. Provide the master password through the
Secret Service beforehand, or point `KPSEC_DB` at a database you unlock another
way.

## Moving the database

Keyring entries are keyed by the database path, so a moved `.kdbx` leaves its
master key pointing at a path that no longer exists. Re-point it after the move:

```bash
mv ~/.pass/agents.kdbx ~/vault/agents.kdbx
KPSEC_DB=~/.pass/agents.kdbx kpsec relocate ~/vault/agents.kdbx
```

`relocate` copies the key to the new path, verifies the database actually opens
with it, and only then removes the old entry — a wrong target leaves everything
untouched. If the new location is not the default, record it in
`~/.config/kpsec/config.json` (`{"db": "~/vault/agents.kdbx"}`) or export
`KPSEC_DB`.

## Multiple databases

```bash
KPSEC_DB=~/work/secrets.kdbx kpsec init
KPSEC_DB=~/work/secrets.kdbx kpsec ls
```

Keyring entries are keyed by database path, so several databases coexist without
stepping on each other.
