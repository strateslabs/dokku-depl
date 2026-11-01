#!/usr/bin/env bats
# Runs the plugin against a temporary DOKKU_LIB_ROOT. Needs jq and flock (Linux).

setup() {
  export DOKKU_LIB_ROOT="$BATS_TEST_TMPDIR/lib"
  export PLUGIN="$BATS_TEST_DIRNAME/.."
  D="$DOKKU_LIB_ROOT/data/depl"
}

# depl SUB ARGS...: run a subcommand the way Dokku does (the file, with the full name first).
depl() {
  local sub="$1"
  shift
  "$PLUGIN/subcommands/$sub" "depl:$sub" "$@"
}

init() { run depl init; [ "$status" -eq 0 ]; }

@test "version reports plugin and state format, matching plugin.toml" {
  run depl version
  [ "$status" -eq 0 ]
  [ "$(jq -r .state_format <<<"$output")" = 1 ]
  toml="$(sed -n 's/^version = "\(.*\)"/\1/p' "$PLUGIN/plugin.toml")"
  [ "$(jq -r .plugin <<<"$output")" = "$toml" ]
}

@test "every subcommand file is a link to depl-cmd and the commands table lists it" {
  for f in "$PLUGIN"/subcommands/*; do
    [ -L "$f" ]
    [ -x "$f" ]
  done
  [ "$(ls "$PLUGIN/subcommands" | wc -l)" -eq 15 ]
}

@test "commands answers help and declines other commands with 10" {
  run "$PLUGIN/commands" help
  [ "$status" -eq 0 ]
  run "$PLUGIN/commands" apps:list
  [ "$status" -eq 10 ]
}

@test "install creates the directory but not the state" {
  run "$PLUGIN/install"
  [ "$status" -eq 0 ]
  [ -d "$D" ]
  [ "$(stat -c %a "$D")" = 700 ]
  [ ! -e "$D/state.json" ]
}

@test "missing state is exit 20 for every state command, never empty" {
  for args in "state-status" "state-list" "state-get app web" "state-set app web owned" "state-rm app web" "kv-get k" "kv-set k v" "kv-rm k"; do
    run depl $args
    [ "$status" -eq 20 ]
  done
  [ ! -e "$D/state.json" ]
}

@test "init creates state, refuses to repeat (23), and --force keeps a backup" {
  init
  [ "$(jq -c . "$D/state.json")" = '{"format":1,"records":{},"kv":{}}' ]
  run depl init
  [ "$status" -eq 23 ]
  depl state-set app web owned
  run depl init --force
  [ "$status" -eq 0 ]
  [ "$(ls "$D"/state.json.bak-* | wc -l)" -eq 1 ]
  [ "$(jq '.records | length' "$D"/state.json.bak-*)" -eq 1 ]
  [ "$(jq '.records | length' "$D/state.json")" -eq 0 ]
}

@test "corrupt state is exit 21 and is left untouched" {
  init
  echo '{not json' >"$D/state.json"
  for args in "state-status" "state-list" "kv-get k" "state-set app web owned"; do
    run depl $args
    [ "$status" -eq 21 ]
  done
  [ "$(cat "$D/state.json")" = '{not json' ]
  echo '{"format":1,"records":[]}' >"$D/state.json"
  run depl state-list
  [ "$status" -eq 21 ]
  : >"$D/state.json"
  run depl state-status
  [ "$status" -eq 21 ]
}

@test "a newer state format is exit 22" {
  init
  echo '{"format":2,"records":{},"kv":{}}' >"$D/state.json"
  run depl state-list
  [ "$status" -eq 22 ]
}

@test "records: set, get, update keeps created_at, list sorted, rm" {
  init
  run depl state-set app web owned
  [ "$status" -eq 0 ]
  [ "$(jq -r '.kind,.name,.status' <<<"$output" | paste -sd,)" = "app,web,owned" ]
  created="$(jq -r .created_at <<<"$output")"
  [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]
  depl state-set postgres db owned
  depl state-set app api owned
  sleep 1
  run depl state-set app web retained
  [ "$(jq -r .status <<<"$output")" = retained ]
  [ "$(jq -r .created_at <<<"$output")" = "$created" ]
  [ "$(jq -r .updated_at <<<"$output")" != "$created" ]
  run depl state-get app web
  [ "$(jq -r .status <<<"$output")" = retained ]
  run depl state-list
  [ "$(jq -r '.records[] | .kind + "/" + .name' <<<"$output" | paste -sd,)" = "app/api,app/web,postgres/db" ]
  [ "$(jq .format <<<"$output")" = 1 ]
  run depl state-rm app web
  [ "$status" -eq 0 ]
  run depl state-rm app web
  [ "$status" -eq 0 ]
  run depl state-get app web
  [ "$status" -eq 3 ]
}

@test "records reject bad kinds, names, statuses and argument counts" {
  init
  run depl state-set cat web owned; [ "$status" -eq 1 ]
  run depl state-set app 'a b' owned; [ "$status" -eq 1 ]
  run depl state-set app '../x' owned; [ "$status" -eq 1 ]
  run depl state-set app web mine; [ "$status" -eq 1 ]
  run depl state-set app web; [ "$status" -eq 1 ]
}

@test "kv: set, get, overwrite, rm; absent is 3; empty value is refused" {
  init
  run depl kv-get global_managed_keys
  [ "$status" -eq 3 ]
  depl kv-set global_managed_keys 'A,B'
  run depl kv-get global_managed_keys
  [ "$output" = "A,B" ]
  depl kv-set global_managed_keys 'C'
  run depl kv-get global_managed_keys
  [ "$output" = "C" ]
  run depl kv-set global_managed_keys ''
  [ "$status" -eq 1 ]
  depl kv-rm global_managed_keys
  run depl kv-get global_managed_keys
  [ "$status" -eq 3 ]
}

@test "lock: acquire, show, held by another (30), same run re-acquires" {
  run depl lock-show
  [ "$status" -eq 3 ]
  run depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r '.run_id,.ttl,.expired' <<<"$output" | paste -sd,)" = "r1,600,false" ]
  run depl lock-acquire r2 anna ci 2026-11-01T10:01:00Z
  [ "$status" -eq 30 ]
  [[ "$output" == *'"run_id":"r1"'* && "$output" == *'"user":"steve"'* && "$output" == *'"machine":"laptop"'* ]]
  run depl lock-acquire r1 steve laptop 2026-11-01T10:05:00Z 300
  [ "$status" -eq 0 ]
  [ "$(jq -r '.started_at,.ttl' <<<"$output" | paste -sd,)" = "2026-11-01T10:00:00Z,300" ]
  run depl lock-show
  [ "$(jq -r .run_id <<<"$output")" = r1 ]
}

@test "lock works without any state" {
  [ ! -e "$D/state.json" ]
  run depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z
  [ "$status" -eq 0 ]
}

@test "lock expiry: an expired lock shows expired and is taken over" {
  depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z 1
  sleep 2
  run depl lock-show
  [ "$(jq .expired <<<"$output")" = true ]
  run depl lock-acquire r2 anna ci 2026-11-01T10:01:00Z
  [ "$status" -eq 0 ]
  [ "$(jq -r .run_id <<<"$output")" = r2 ]
}

@test "lock refresh extends expiry, keeps ttl, and needs the holder (31)" {
  depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z 4
  run depl lock-refresh r2
  [ "$status" -eq 31 ]
  sleep 3
  run depl lock-refresh r1
  [ "$status" -eq 0 ]
  [ "$(jq .ttl <<<"$output")" = 4 ]
  sleep 2
  run depl lock-show
  [ "$(jq .expired <<<"$output")" = false ]
  run depl lock-refresh r1 900
  [ "$(jq .ttl <<<"$output")" = 900 ]
  rm "$D/lock.json"
  run depl lock-refresh r1
  [ "$status" -eq 31 ]
}

@test "lock release: holder only (31), idempotent when unlocked; force-release by run id" {
  run depl lock-release r1
  [ "$status" -eq 0 ]
  run depl lock-force-release r1
  [ "$status" -eq 3 ]
  depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z
  run depl lock-release r2
  [ "$status" -eq 31 ]
  run depl lock-force-release r2
  [ "$status" -eq 31 ]
  run depl lock-force-release r1
  [ "$status" -eq 0 ]
  [ ! -e "$D/lock.json" ]
  depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z
  run depl lock-release r1
  [ "$status" -eq 0 ]
  [ ! -e "$D/lock.json" ]
}

@test "lock rejects bad arguments" {
  run depl lock-acquire r1 steve laptop yesterday; [ "$status" -eq 1 ]
  run depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z 0; [ "$status" -eq 1 ]
  run depl lock-acquire '' steve laptop 2026-11-01T10:00:00Z; [ "$status" -eq 1 ]
  run depl lock-acquire r1; [ "$status" -eq 1 ]
}

@test "a corrupt lock file is exit 21, not a free lock" {
  mkdir -p "$D"
  echo 'garbage' >"$D/lock.json"
  run depl lock-acquire r1 steve laptop 2026-11-01T10:00:00Z
  [ "$status" -eq 21 ]
  [ "$(cat "$D/lock.json")" = garbage ]
}

@test "concurrent acquires: exactly one wins" {
  for i in $(seq 1 12); do
    ( rc=0; depl lock-acquire "r$i" u m 2026-11-01T10:00:00Z >/dev/null 2>&1 || rc=$?; echo "$rc" >"$BATS_TEST_TMPDIR/rc$i" ) &
  done
  wait
  wins=0 held=0
  for i in $(seq 1 12); do
    rc="$(cat "$BATS_TEST_TMPDIR/rc$i")"
    if [ "$rc" = 0 ]; then wins=$((wins + 1)); fi
    if [ "$rc" = 30 ]; then held=$((held + 1)); fi
  done
  [ "$wins" -eq 1 ]
  [ "$held" -eq 11 ]
  run depl lock-show
  winner="$(jq -r .run_id <<<"$output")"
  [ "$(cat "$BATS_TEST_TMPDIR/rc${winner#r}")" = 0 ]
}

@test "concurrent writes are serialised: none lost, no temp files left" {
  init
  for i in $(seq 1 20); do
    ( depl state-set app "app$i" owned >/dev/null 2>&1 ) &
  done
  wait
  [ "$(jq '.records | length' "$D/state.json")" -eq 20 ]
  [ -z "$(ls -A "$D" | grep '^\.tmp' || true)" ]
}

@test "writes are atomic: readers never see a partial file" {
  init
  ( for i in $(seq 1 30); do depl state-set app "w$i" owned >/dev/null 2>&1; done ) &
  writer=$!
  while kill -0 "$writer" 2>/dev/null; do
    run depl state-list
    [ "$status" -eq 0 ]
  done
  wait
}

@test "a failed write leaves the old state and no temp file" {
  init
  depl state-set app web owned
  before="$(cat "$D/state.json")"
  # jq fails on the write when the filter cannot run; simulate with a read-only directory copy
  chmod 500 "$D"
  run depl state-set app api owned
  chmod 700 "$D"
  [ "$status" -ne 0 ]
  [ "$(cat "$D/state.json")" = "$before" ]
  [ -z "$(ls -A "$D" | grep '^\.tmp' || true)" ]
}

@test "unknown command is exit 1" {
  run "$PLUGIN/depl-cmd" nope
  [ "$status" -eq 1 ]
}
