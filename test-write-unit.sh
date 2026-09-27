#!/usr/bin/env bash
# Self-check for write_unit's ownership guards. Run: bash test-write-unit.sh
set -uo pipefail

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/laya"
printf '#!/bin/sh\n' > "$WORK/laya/laya-serve"; chmod +x "$WORK/laya/laya-serve"

# shellcheck disable=SC1090
source <(sed '/^case /,$d' "$(dirname "$0")/bin/omarchy-local-laya")
systemctl() { :; }                      # stub: no systemd in the harness
write_config cpu "$WORK/laya" false     # folder(), mode(), autostart() read this
UNITDIR="$HOME/.config/systemd/user"

pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $1"; }
expect_ok()  { ( write_unit ) >/dev/null 2>"$WORK/err" && ok || { bad "$1"; cat "$WORK/err"; }; }
expect_die() { # expect_die <label> <stderr pattern>
  if ( write_unit ) >/dev/null 2>"$WORK/err"; then bad "$1"
  elif grep -q "$2" "$WORK/err"; then ok
  else bad "$1 (msg: $(cat "$WORK/err"))"; fi
}

# fresh write lands and self-verifies
expect_ok "fresh write"
[[ -f $UNIT ]] && grep -q '^X-Omarchy-Gen=' "$UNIT" || bad "gen line missing"
gen=$(sed -n 's/^X-Omarchy-Gen=//p' "$UNIT")
[[ $(unit_hash "$UNIT") == "$gen" ]] || bad "self-hash mismatch"

# regeneration of an untouched generated unit is allowed
expect_ok "regen"

# a hand edit is refused, not silently lost
echo "Restart=always" >> "$UNIT"
expect_die "edited unit" "modified outside"

# legacy unit (pre-hash, exact Description) still regenerates
rm -f "$UNIT"
cat > "$UNIT" <<'EOF'
[Unit]
Description=Laya decision daemon (omarchy-local-laya)
[Service]
ExecStart=/old/path
EOF
expect_ok "legacy unit"
grep -q 'ExecStart=/old/path' "$UNIT" && bad "legacy unit not regenerated" || ok

# foreign unit merely mentioning the plugin name is refused
cat > "$UNIT" <<'EOF'
[Unit]
Description=User unit for omarchy-local-laya stuff
EOF
expect_die "foreign unit" "not generated"

# symlink is refused rather than written through
rm -f "$UNIT"; ln -s "$WORK/target" "$UNIT"
expect_die "symlink" "symlink"
[[ -e $WORK/target ]] && bad "write followed symlink" || ok

# non-regular file is refused
rm -f "$UNIT"; mkdir "$UNIT"
expect_die "directory" "not a regular file"

echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
