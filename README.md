# dokku-depl

A small [Dokku](https://dokku.com) plugin that is the state store for [depl](https://github.com/strateslabs/depl), a declarative CLI for Dokku servers. It records what depl owns on the host, keeps a few depl settings, and holds the lock that stops two depl runs from changing one host at once.

The plugin is a dumb, reliable store. It never runs other Dokku commands and has no plan logic: depl decides, the plugin remembers.

depl installs and updates the plugin itself, at a pinned tag, in the first phase of every run:

```bash
dokku plugin:install https://github.com/strateslabs/dokku-depl.git --committish v0.1.0 --name depl
```

You can also install it by hand with that command. Needs Dokku >= 0.38.32 (which depends on `jq` and `util-linux`, so `jq` and `flock` are always there).

Every command runs as the `dokku` user, locally as `dokku depl:<subcommand>` or remotely as `ssh dokku@host -- depl:<subcommand>`. Commands read no stdin and print JSON or nothing on stdout; messages for humans go to stderr, prefixed `depl:`.

## Commands

| Command | Stdout | What it does |
|---|---|---|
| `depl:version` | `{"plugin":"0.1.0","state_format":1}` | Plugin version and the state format it reads and writes |
| `depl:init [--force]` | none | Create an empty state. Exit 23 when state already exists. `--force` first moves an existing `state.json` to `state.json.bak-<UTC timestamp>` |
| `depl:state-status` | none | Exit 0 when state is present and readable, otherwise 20, 21 or 22 (see exit codes). Takes no lock |
| `depl:state-list` | `{"format":1,"records":[{...}]}` | Every record in one call, sorted by kind then name |
| `depl:state-get <kind> <name>` | one record, JSON | Exit 3 when there is no such record |
| `depl:state-set <kind> <name> <status>` | the record, JSON | Create or update a record; `created_at` is kept on update |
| `depl:state-rm <kind> <name>` | none | Remove a record; exit 0 when it was already gone |
| `depl:kv-get <key>` | the value | Exit 3 when the key is not set |
| `depl:kv-set <key> <value>` | none | Set a key. The value is non-empty; use `kv-rm` to drop one |
| `depl:kv-rm <key>` | none | Remove a key; exit 0 when it was already gone |
| `depl:lock-acquire <run-id> <user> <machine> <started-at> [<ttl-seconds>]` | the lock, JSON | Take the lock. Exit 30 when it is held and not expired |
| `depl:lock-refresh <run-id> [<ttl-seconds>]` | the lock, JSON | Push the expiry out. Exit 31 when `<run-id>` does not hold the lock |
| `depl:lock-release <run-id>` | none | Release the lock. Exit 0 when there is no lock, 31 when another run holds it |
| `depl:lock-show` | the lock, JSON | The current holder. Exit 3 when there is no lock |
| `depl:lock-force-release <run-id>` | none | Release a lock on behalf of its holder (the operator's `depl unlock <run-id>`). Exit 3 when there is no lock, 31 when `<run-id>` is not the holder |

`depl:help` lists the commands. Each `subcommands/<name>` file is a link to the one script, `depl-cmd`.

### Arguments

- `<kind>` is one of `app`, `postgres`, `redis`, `volume`, `network`, `plugin`.
- `<name>` matches `^[A-Za-z0-9][A-Za-z0-9_.-]*$`.
- `<status>` is `owned` or `retained`.
- `<key>` matches `^[A-Za-z_][A-Za-z0-9_.-]*$`. depl uses `global_managed_keys` (the comma-separated keys of its global `env:`).
- `<run-id>`, `<user>`, `<machine>` are non-empty strings of at most 200 characters; `<started-at>` is an ISO 8601 UTC time (`2026-11-01T10:00:00Z`) from the caller.
- `<ttl-seconds>` is a positive integer; the default is 600. A refresh without one keeps the lock's current ttl.

### Records

```json
{"kind":"app","name":"web","status":"owned","created_at":"2026-11-01T10:00:00Z","updated_at":"2026-11-01T10:05:00Z"}
```

Timestamps are server time, UTC.

### The lock

```json
{"run_id":"r-7f3a","user":"steve","machine":"laptop","started_at":"2026-11-01T10:00:00Z","refreshed_at":"2026-11-01T10:03:10Z","expires_at":"2026-11-01T10:13:10Z","ttl":600,"expired":false}
```

- `lock-acquire` succeeds when there is no lock, the lock has expired, or it is already held by the same `<run-id>` (then it acts as a refresh). Otherwise it exits 30, prints `depl: lock held by ...` with the holder's JSON on stderr, and changes nothing.
- A lock expires `ttl` seconds after `refreshed_at`. Expiry is judged on the server's clock, so client clock skew does not matter. An expired lock is replaced by the next acquire; `lock-show` still shows it, with `"expired":true`.
- Acquire, refresh and release run under `flock`, so two concurrent acquires never both win.
- The lock is a single file, independent of `state.json`: it works even when state is missing or corrupt.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 1 | Usage error (unknown command, bad argument) or an internal failure |
| 3 | Not found: a record, key or lock that does not exist |
| 20 | State missing: not initialised. Run `depl:init` |
| 21 | State unreadable: `state.json` is not valid JSON or has the wrong shape. Nothing is read or written |
| 22 | State is a newer format than this plugin reads. Update the plugin |
| 23 | `depl:init` found existing state |
| 30 | Lock held by another run and not expired |
| 31 | Lock not held by that run id |

The plugin never reads missing or unreadable state as empty. Dokku reserves exit 10, so it is not used.

## State layout

Everything lives in `$DOKKU_LIB_ROOT/data/depl/` (`/var/lib/dokku/data/depl/`), owned by the `dokku` user, mode 0700. It is under `data/`, not `config/`, because Dokku deletes `config/<plugin>/<app>` when an app named like the plugin is destroyed.

| File | Content |
|---|---|
| `state.json` | `{"format":1,"records":{"<kind>/<name>":{...}},"kv":{"<key>":"<value>"}}` |
| `lock.json` | The lock record shown above; absent when unlocked |
| `.flock` | Empty file `flock` is taken on; every write and every lock operation holds it |

- **Atomic writes.** Each change writes a temp file in the same directory, then `mv`s it over the target, under `flock`. A crash leaves the old file or the new one, never half of one.
- **Format version.** `format` is an integer, `1` today. A plugin reads formats up to its own and refuses a newer one (exit 22). A format change ships with a migration in a new plugin version.
- **Install.** The plugin's `install` trigger creates the directory and sets its owner and mode. It does not create `state.json`: that is `depl:init`, called by depl on the first run on a box, or by hand after state was lost.

## Development

```bash
bats tests          # needs bats-core, jq and flock (Linux)
shellcheck depl-cmd commands install
```

CI runs both on every push and pull request. Changes after the first commit go through pull requests; releases are git tags (`v0.1.0`), and `plugin.toml`'s `version` matches the tag without the `v`.
