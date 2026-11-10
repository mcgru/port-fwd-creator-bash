# port-fwd-creator.sh

A single self-contained bash script that sets up a persistent SSH tunnel
between two hosts. Run it from your control machine (laptop): it connects to
both endpoints over SSH, prepares the key and `authorized_keys`, fills
`known_hosts`, creates a systemd --user unit or openrc service files, verifies
the forwarded port and prints a copy-paste memo for root.

The script never runs privileged commands: no sudo, no writes to `/etc`, no
`loginctl enable-linger`, no `sshd_config` edits. Everything that needs root is
printed as ready-to-paste commands at the end.

## Requirements

- Control machine: bash 4+, OpenSSH client (`ssh`, `ssh-keygen`), coreutils,
  util-linux `getopt`.
- SSH access from the control machine to both hosts (keys, agent or
  `~/.ssh/config` aliases).
- host1: a user account and systemd --user (default) or openrc.
- host2: sshd.

The script does not parse `~/.ssh/config` itself: it asks `ssh -G`, so aliases,
ports, users and ProxyJump work as usual for the controller. The generated
service uses canonical hostname/port, because host1 does not have your laptop's
SSH config.

## Address format

```
[user@]host[:ip]:port
```

- `ip1:port1` describes the host1 side, `ip2:port2` the host2 side.
- Empty IP means `127.0.0.1`: `host2::8080`.
- IPv6 goes in brackets: `host1:[::1]:8080`.
- The SSH connection is always initiated from host1 to host2. The direction
  only decides which side listens:

| Direction | Tokens | Listens on |
|---|---|---|
| `-L`, `-l`, `--local` (default) | `>`, `>>`, `>>>`, `}`, `}}`, `}}}` | host1 |
| `-R`, `-r`, `--remote` | `<`, `<<`, `<<<`, `{`, `{{`, `{{{` | host2 |

Quote tokens containing `>` in the shell, otherwise it is a redirect.

## Quick start

```bash
git clone https://github.com/mcgru/port-fwd-creator-bash.git
cd port-fwd-creator-bash
chmod +x port-fwd-creator.sh

# listen on host1 at 127.0.0.1:18080, forward to host2's sshd
./port-fwd-creator.sh sss:127.0.0.1:18080 -L ttt:127.0.0.1:22

# the same with a direction token
./port-fwd-creator.sh sss:127.0.0.1:18080 '}}}' ttt:127.0.0.1:22

# listen on host2 at 172.17.0.1:3333, forward to host1's sshd
./port-fwd-creator.sh sss:172.17.0.1:22 '{{' ttt:172.17.0.1:3333

# explicit users, empty IP means loopback
./port-fwd-creator.sh smelov@sss::8080 '>>>' tun-user@ttt::22

# host1 runs openrc instead of systemd
./port-fwd-creator.sh ggg::18080 '}}}' hhh::22 --openrc
```

After a successful run, the tunnel is an enabled service on host1 and the
script prints the root memo (linger for systemd, file installation for openrc)
and the exact ssh command it uses.

## Common tasks

```bash
# see what would happen without touching the hosts
./port-fwd-creator.sh sss::18080 -L ttt::22 --dry-run

# configure key, authorized_keys and known_hosts, but create no service
./port-fwd-creator.sh sss::18080 -L ttt::22 --no-persist

# check an existing tunnel without changing anything
./port-fwd-creator.sh sss::18080 -L ttt::22 --check

# remove the service (the key line in authorized_keys is kept)
./port-fwd-creator.sh sss::18080 -L ttt::22 --teardown

# list successful creations
./port-fwd-creator.sh --history

# too many keys in the agent -> pin the controller key
./port-fwd-creator.sh sss::18080 -L ttt::22 -K ~/.ssh/id_ed25519

# extra ssh options for the tunnel (each becomes its own -o)
./port-fwd-creator.sh sss::18080 -L ttt::22 -o 'Compression=yes ServerAliveInterval=15'

# custom service name and key on host1
./port-fwd-creator.sh sss::18080 -L ttt::22 -n my-tunnel -k ~/.ssh/id_tunnel
```

### Endpoints via options

`--from` and `--to` take the same `[user@]host[:ip]:port` value and are
stronger than positional arguments: if both are present, the option wins.

```bash
# no positional arguments at all
./port-fwd-creator.sh --from sss:127.0.0.1:18080 --to ttt:127.0.0.1:22 -L

# one missing side can stay positional
./port-fwd-creator.sh --from sss::18080 ttt::22 -L
./port-fwd-creator.sh sss::18080 --to ttt::22 -L

# the option overrides the argument: host2 here is ttt:22, not 9.9.9.9:22
./port-fwd-creator.sh sss::18080 -L ttt:9.9.9.9:22 --to ttt:127.0.0.1:22
```

### Replay a successful run: --run

`--run MOMENT` looks up `history.success` from the end of the file and replays
the first record whose **time** (the date is ignored) matches. Colons are
removed and the timestamp becomes an integer; as many digits as there are in
MOMENT are cut from its end:

```text
--run 59      matches any run whose seconds are 59
--run 4459    minutes and seconds 44:59
--run 24459   hours, minutes and seconds 02:44:59
```

The historical command is restored and re-run with the current options
applied on top; the current options win:

```bash
# replay the newest successful run at xx:xx:59
./port-fwd-creator.sh --run 59

# replay it, but listen on another address/port on host2
./port-fwd-creator.sh --run 59 --to ttt:172.17.0.1:4444 --no-persist

# replay it with the opposite direction
./port-fwd-creator.sh --run 59 -L
```

Before anything real happens the script prints the matched timestamp and the
resulting command and asks:

```text
Запускаем? [Y/n]
```

Enter, `y` or `yes` starts it; `n`, any other answer or Ctrl+D cancels without
starting and without a history record; Ctrl+C interrupts. With `--dry-run` or
`--check` no confirmation is asked, because nothing is changed. Without a
terminal (stdin is not a tty) the replay is refused with exit code 1.

Positional addresses are not accepted together with `--run`; use `--from` /
`--to` for overrides.

## What the script does

1. Parses arguments with `getopt` and rejects conflicting directions or
   service managers.
2. Canonicalizes both hosts with `ssh -G`.
3. Detects the service manager on host1 before changing anything; on a
   mismatch it fails and prints the same command with the right flag appended.
4. host1: uses `~/.ssh/id_ed25519` or creates it (ed25519, no passphrase). The
   public key is kept in memory only.
5. host2: `whoami`, then finds the key in `authorized_keys` by its body. If the
   line is missing, it appends
   `restrict,port-forwarding,permitopen|permitlisten="ip2:port2"`. Its own line
   (comment `port-fwd-creator:...`) is updated when the rule changes; a foreign line
   with different options is an error unless `--force` is given.
6. host1: fills `known_hosts` with the first connection to host2.
7. Builds the ssh command: `-N -T`, BatchMode, ExitOnForwardFailure,
   StrictHostKeyChecking=yes, explicit key and known_hosts, IdentitiesOnly,
   keepalive every 30 s, user `-o` options first (so they can override).
8. Creates the service (unless `--no-persist`) and checks that the port is
   listening on the requested address, not just on the port.
9. Prints the root memo in copy-paste blocks.

## Persistence

### systemd --user (default)

- Unit: `~/.config/systemd/user/<name>.service`
- `systemctl --user enable` and `systemctl --user restart` are done as the
  host1 user.
- To survive logout and reboot, root must run `loginctl enable-linger <user>`.
  Without linger the unit stops when the last session closes and starts again
  with the next login.

### openrc

- The script only prepares files under `~/.local/share/<name>/init.d` and
  `conf.d`; it does not write to `/etc`.
- Root installs them and enables the service:

```bash
install -m 755 ~/.local/share/<name>/init.d/<name> /etc/init.d/<name>
install -m 644 ~/.local/share/<name>/conf.d/<name> /etc/conf.d/<name>
rc-update add <name> default
rc-service <name> start
```

## History

On the control machine, under `~/.local/share/port-fwd-creator/`
(or `$XDG_DATA_HOME/port-fwd-creator/`):

- `history.run` — every run, including failures and interrupts;
- `history.success` — only successful creations: `ok` when the systemd service
  is running and the port really listens, `prepared` when openrc files are
  ready and await root.

Both files store the full command line with the direction normalized to
`-L`/`-R`. `--history` prints `history.success`; `--run` reads it.

## Notes and limitations

- `-R` to a non-loopback address needs `GatewayPorts clientspecified` in
  host2's `sshd_config` (root). Without it sshd accepts the request but binds
  the port to `127.0.0.1`; the script reports the address mismatch and points
  to GatewayPorts.
- `permitopen` restricts only `-L`, `permitlisten` only `-R`. The generated
  line also enables `port-forwarding` in general, so a line written for one
  direction does not restrict the other.
- A passphrase-protected key on host1 is rejected: the service cannot unlock
  it without an agent.
- The default key is shared (`~/.ssh/id_ed25519`). Use `-k` for a dedicated
  key per tunnel.
- `--teardown` removes the service but keeps the `authorized_keys` line: the
  key may be shared.
- ProxyJump configured for host2 on the laptop will not apply on host1; the
  script warns about it.
- The script never installs packages, creates users or edits `sshd_config`.

## Repository layout

```text
port-fwd-creator.sh  the script
PRD.md               requirements, decisions, acceptance criteria, test log
DIALOGUE.md          the conversation that shaped the tool (Russian)
todo                 original task statement (Russian)
README.md            this file
README.ru.md         Russian version
```
