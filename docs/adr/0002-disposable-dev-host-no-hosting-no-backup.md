# The DigitalOcean host is a disposable dev box: no hosting, no backups

The droplet exists so agent work survives a powered-off desktop. It runs T3 Code
headless, the agent CLIs, and the dev stacks of `~/Projects/labs` and `~/Projects/o27`.
It **hosts nothing** — no public service, no custom project, no port on its public IP —
and its **data is not backed up**: no DO automatic backups, no disk snapshots. Everything
that matters is pushed to a forge; the host is recreated by `tools/provision-droplet.sh`.

A dev box and a hosting box are opposite machines. A dev box is closed (tailnet only)
and disposable; a hosting box has state you cannot lose, public ports, TLS, and a
lifecycle you respect. Merging them costs the right to destroy the machine on a whim —
and that right is what makes the rest of this design cheap. Vercel already covers the
hosting case, and a second droplet is 6 $/month when a real one comes along.

## Consequences

- **Unpushed work does not exist.** `tools/backup-projects.sh` already says so in its own
  usage text; here it becomes a rule rather than a caveat. An agent that works for three
  hours in a worktree nobody pushed loses three hours if the host goes.
- **Credentials are snapshotted; data never is.** "Everything that matters is pushed to a
  forge" was not true of the host's *identity*: its own SSH keypair, the two forge tokens,
  both agent OAuth logins and the Tailscale node identity are unique to the machine and on
  no forge — which is why rebuilding it took a ten-stage browser wizard. `dots droplet
  snapshot` saves exactly those (~20 KB, age-encrypted, riding the projects-backup repo)
  and `restore` puts them back. This is what makes "disposable" *cheap* rather than what
  reverses it: it buys back the wizard, not the disk. `~/.t3/userdata/state.sqlite` —
  sessions and history — is deliberately excluded, and that exclusion is the line this
  decision draws. A snapshot that grew to cover data would be the reversal.
- **Agents effectively have root.** `socle`'s dev stack needs Docker, and the `docker`
  group is root by another name. That is acceptable *because* the host is disposable and
  holds no unique **data** — the credentials above are all revocable in one click each, and
  are the reason it would not be otherwise. It is also why `~/.ssh` is never
  copied there and the host gets its own SSH key and forge tokens, revocable alone.
- Repos are cloned flat; worktrees are recreated on demand with `wt`. Replicating the
  desktop's worktrees would put two divergent copies of the same ticket on two machines.
- Resizing RAM/CPU is a reboot away, so starting at 8 GB commits to nothing.
