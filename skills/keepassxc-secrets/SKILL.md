---
name: keepassxc-secrets
description: Use when a command needs a password, token, API key, extra entry attribute (e.g. auth headers) or SSH key that lives in a local KeePassXC database — resolve it into the command's environment or a temp file without ever printing the value. Covers kp:// secret references and kpsec show/run/check/ls/add.
requires:
  bins: ["keepassxc-cli"]
---

# keepassxc-secrets — secrets from KeePassXC without leaking them

Agent-facing secrets live in a **separate database**, by default `~/.pass/agents.kdbx`.
Its master password is stored in the system keyring (Secret Service on Linux,
Keychain on macOS, Credential Manager on Windows) and, on Linux, cached in the
kernel keyring, so the commands run without prompting. The user's main database
stays out of reach — that is what bounds the blast radius.

`kpsec` is a shell script (`kpsec.ps1` on Windows). No runtime beyond the shell.

## The one rule

**Never print a secret and never call `keepassxc-cli` directly.** Its output goes
straight into the transcript. `kpsec` resolves values inside its own process and
hands them to the child through the environment — they never touch stdout or argv.

Never:

```bash
keepassxc-cli show ... -a Password         # the value lands in the model context
some-cli --password "$(...)"               # the password is visible in /proc/*/cmdline
export TOKEN=$(...)                        # the value sticks in history and logs
```

Instead:

```bash
kpsec run -e TOKEN=kp://acme/gitlab -- some-cli   # secret only in the child's env
kpsec check kp://acme/gitlab                     # verify without revealing
```

`kpsec run` does not filter what the child prints. If a command is known to echo
its credentials (debug output, verbose HTTP logs), do not run it under `kpsec run`
in an agent session.

## Reference format

```
kp://<group>/<entry>[#<Attribute>]      # Password, UserName, URL or any custom attribute
kp://<group>/<entry>#@<attachment>      # an attached file, e.g. an SSH key
```

Binary attachments (`.jks`, `.p12`, DER keys) only work through `run -f`, which
writes the exact bytes; `run -e` keeps text only.

The default attribute is `Password`.

## Read the entry first

Before using an entry for the first time in a session, run
`kpsec show <group>/<entry>`. It prints the title, user, URL, the **names** of
custom attributes and attachments, and the entry's Notes — never secret values.
Notes are the entry's instructions: which attribute goes where, which header,
host or flags to use. Follow them over your own guesses. Notes are printed as-is,
so they must not hold secrets themselves.

## Commands

```bash
kpsec status                              # database, keyring backend, unlock check
kpsec ls                                  # entries, without values
kpsec show acme/gitlab                    # fields, attribute names, notes
kpsec check kp://acme/gitlab              # OK + length and sha256 prefix
kpsec run -e TOKEN=kp://acme/gitlab -- glab api /user
kpsec run --env-file .env.tpl -- docker compose up
kpsec add acme/gitlab -u alice            # value typed by a human in a GUI dialog
kpsec add acme/gitlab -g -L 32            # generate a random value
kpsec attach acme/bastion ~/.ssh/id_ed25519   # attach a file as kp://acme/bastion#@id_ed25519
kpsec set acme/vault#cf-access-id        # extra protected attribute, value typed in a dialog
kpsec clip kp://acme/gitlab               # clipboard for 15 seconds
kpsec lock                                # drop the cached master password
```

## Extra attributes: headers and the like

Every custom attribute is addressable by name. To send them as HTTP headers,
keep them off argv — `curl -H @-` reads headers from stdin, and `printf` is a
shell builtin:

```bash
kpsec run -e CF_ID=kp://acme/vault#cf-access-id -e CF_SECRET=kp://acme/vault#cf-access-secret -- \
  sh -c 'printf "CF-Access-Client-Id: %s\nCF-Access-Client-Secret: %s\n" "$CF_ID" "$CF_SECRET" |
         curl -sf -H @- https://vault.acme.dev/v1/sys/health'
```

## Files: SSH keys, certificates, kubeconfigs

`-f VAR=ref` writes the value into a `0600` file in a private temp directory
(`$XDG_RUNTIME_DIR` when set), puts its path into `VAR`, and deletes the
directory when the command exits. Works with attributes and attachments alike:

```bash
kpsec run -f KEY=kp://acme/bastion#@id_ed25519 -- \
  sh -c 'ssh -i "$KEY" -o IdentitiesOnly=yes deploy@bastion.acme.dev uptime'

kpsec run -f KEY=kp://acme/deploy-key#@id_ed25519 -- \
  ssh-agent sh -c 'ssh-add -q "$KEY" && git push'    # throwaway agent, dies with the command
```

The `sh -c '...'` with single quotes matters: `$KEY` must expand inside the
child, where it is set, not in the agent's shell.

`.env.tpl` is a plain env file whose values are either literals or `kp://`
references. It is safe to commit — it holds no values:

```
REGISTRY_USER=deployer
REGISTRY_PASSWORD=kp://acme/registry
```

Commands an agent must **not** run: `kpsec add --stdin` (the value would land in
argv) and `kpsec show-master`. Those are for the human at the keyboard.

## Adding a secret

```bash
kpsec add <group>/<entry> -u <username> --url <url>
```

The value is typed into a GUI dialog, so it never passes through the agent's
command line. Verify with `kpsec check kp://<group>/<entry>`.

Lay the database out as `<project>/<service>` — `acme/argocd`, `acme/gitlab` —
because the same service usually has a different account in every project.
`keepassxc-cli` cannot set or filter by tags, so the group path is the only
structure and the reference mirrors it. Nested groups work too
(`kp://acme/dbaas/prod/api`); `kpsec add` creates missing intermediate groups.

## Building tools on top

`kpsec` doubles as a library. Sourcing it with `KPSEC_LIB=1` skips the command
dispatch and exposes `resolve`, `kp`, `master_get` and the keyring helpers, so a
wrapper can resolve a secret without it passing through an intermediate stdout:

```bash
KPSEC_LIB=1 . "$HOME/.claude/skills/keepassxc-secrets/scripts/kpsec"

token=$(resolve "kp://acme/gitlab")    # stays in this shell's memory
export GITLAB_TOKEN="$token"           # export, not `env VAR=… cmd` — argv is public
exec glab api /user
```

## Troubleshooting

- `kpsec status` shows the keyring backend in use, the resolved `keepassxc-cli`
  and whether the database opens.
- `unlock: FAILED` — the stored key does not match the database. After moving the
  `.kdbx`, re-point the key with `kpsec relocate <new-path>`.
- Prompts need a graphical session; without one they are skipped rather than
  blocking. For headless runs set `KPSEC_NO_GUI=1` — the commands then fail with
  exit code 4.
- Environment: `KPSEC_DB`, `KPSEC_TTL`, `KPSEC_CONFIG`, `KPSEC_KEYRING`
  (`secretservice` / `keychain` / `none`), `KPSEC_KEEPASSXC_CLI`,
  `KPSEC_PROMPT_TIMEOUT`.
- See `references/security.md` for the threat model, `references/setup.md` for
  installation and `references/platforms.md` for Linux/macOS/Windows specifics.
