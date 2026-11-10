Secrets (passwords, tokens, API keys) live in a local KeePassXC database and are
reached only through the `kpsec` CLI. Never print a secret and never call
`keepassxc-cli` directly — its output goes straight into the transcript.

- Reference form: `kp://<group>/<entry>[#<Attribute>]` (default attribute `Password`,
  any custom attribute works), `kp://<group>/<entry>#@<attachment>` for attached files.
- Before first use of an entry run `kpsec show <group>/<entry>`: it lists field and
  attribute names and prints the entry's Notes — follow the instructions there.
- Use a secret: `kpsec run -e VAR=kp://group/entry -- <command>` — the value is
  placed in the child process environment, never on the command line.
- Need a file (SSH key, certificate): `kpsec run -f VAR=kp://... -- sh -c 'ssh -i "$VAR" ...'`
  — a 0600 temp file, removed when the command exits.
- Verify a reference without revealing it: `kpsec check kp://group/entry`.
- List what exists: `kpsec ls`. Diagnose access: `kpsec status`.
- Adding a secret is a human action: `kpsec add <group>/<entry> -u <user>` opens a
  GUI dialog, so the value never passes through the command line. Never use
  `kpsec add --stdin` or `kpsec show-master`.
- The child's output is not filtered: do not run commands that echo their own
  credentials under `kpsec run`.

Full documentation: `skills/keepassxc-secrets/SKILL.md` in the agents-keepassxc-skill
installation (see `references/security.md` for the threat model).
