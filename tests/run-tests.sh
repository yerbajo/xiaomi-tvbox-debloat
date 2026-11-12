#!/usr/bin/env bash
# Exercises mibox-s-debloat.sh against a fake adb. Run from anywhere:
#   tests/run-tests.sh

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$ROOT/mibox-s-debloat.sh"
STUB="$ROOT/tests/stub"
FIXTURE="$ROOT/tests/fixture.tsv"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fails=0
ok() { printf '[ ok ] %s\n' "$1"; }
bad() { printf '[FAIL] %s\n' "$1"; fails=$((fails + 1)); }
check() { # description, exit status, expected status
	if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1 (exit $2, expected $3)"; fi
}

RUN="$WORK/run"
fresh() {
	rm -rf "$RUN"
	mkdir -p "$RUN"
	cp "$FIXTURE" "$RUN/state.tsv"
	: >"$RUN/log"
}

run() {
	(
		cd "$RUN" || exit 1
		PATH="$STUB:$PATH" \
			STUB_STATE="$RUN/state.tsv" \
			STUB_LOG="$RUN/log" \
			BACKUP_ROOT="$RUN/backups" \
			"$SCRIPT" "$@"
	)
}

state_of() {
	awk -F'\t' -v p="$1" '$2 == p { print $1 }' "$RUN/state.tsv"
}

expect_state() { # package, expected state
	if [ "$(state_of "$1")" = "$2" ]; then ok "$1 is $2"; else bad "$1 is $(state_of "$1"), expected $2"; fi
}

# --- T1: refuses to touch a device that is not there -------------------------
fresh
rm -f "$RUN/state.tsv"
out=$(run check 2>&1)
check "T1 check fails without a device" "$?" 1
case $out in
	*"no usable device"*) ok "T1 explains how to connect" ;;
	*) bad "T1 message missing: $out" ;;
esac

# --- T2: apply disables the default tiers only -------------------------------
fresh
out=$(run apply 2>&1)
check "T2 apply succeeds" "$?" 0
expect_state com.mitv.tvhome.michannel disabled
expect_state com.mitv.milinkservice disabled
expect_state com.mitv.videoplayer disabled
expect_state com.google.android.videos disabled
expect_state com.miui.tv.analytics disabled
expect_state tv.alphonso.alphonso_eula disabled
expect_state com.google.android.tvrecommendations disabled
expect_state com.mitv.tvhome.mitvplus disabled
expect_state com.google.android.tvlauncher enabled
expect_state com.mitv.tvhome.atv enabled
expect_state com.xiaomi.android.tvsetup.partnercustomizer enabled
expect_state com.xiaomi.mitv.updateservice enabled
case $out in
	*"not installed"*) ok "T2 skips absent packages" ;;
	*) bad "T2 no absent-package notice: $out" ;;
esac
if compgen -G "$RUN/backups/20*/managed.tsv" >/dev/null; then
	ok "T2 backup written before the change"
else
	bad "T2 no backup directory"
fi

# --- T3: apply is idempotent --------------------------------------------------
out=$(run apply 2>&1)
check "T3 second apply succeeds" "$?" 0
case $out in
	*"Changed 0, failed 0"*) ok "T3 nothing changed twice" ;;
	*) bad "T3 second apply was not a no-op: $out" ;;
esac

# --- T4: restore returns to the state before the first change ---------------
out=$(run restore 2>&1)
check "T4 restore succeeds" "$?" 0
expect_state com.mitv.tvhome.michannel enabled
expect_state com.mitv.milinkservice enabled
expect_state com.mitv.videoplayer enabled
expect_state com.google.android.videos enabled

# --- T5: --dry-run changes nothing -------------------------------------------
fresh
out=$(run apply --dry-run 2>&1)
check "T5 dry run succeeds" "$?" 0
case $out in
	*"[dry "*) ok "T5 prints the intended commands" ;;
	*) bad "T5 no dry-run output: $out" ;;
esac
expect_state com.mitv.tvhome.michannel enabled
if grep -q 'disable-user' "$RUN/log"; then
	bad "T5 dry run still sent a disable command"
else
	ok "T5 no disable command reached the device"
fi

# --- T6: launcher tier is opt-in ---------------------------------------------
fresh
run apply --tier launchers >/dev/null 2>&1
expect_state com.google.android.tvlauncher disabled
expect_state com.mitv.tvhome.michannel enabled

# --- T7: patchwall tier leaves the Google launcher as Home ------------------
fresh
out=$(run apply --tier patchwall 2>&1)
check "T7 patchwall apply succeeds" "$?" 0
expect_state com.mitv.tvhome.atv disabled
expect_state com.google.android.tvlauncher enabled
expect_state com.mitv.tvhome.michannel enabled

# --- T8: unknown tier is a usage error --------------------------------------
fresh
run apply --tier bogus >/dev/null 2>&1
check "T8 unknown tier is rejected" "$?" 2

# --- T9: restore also undoes packages the snapshot never knew about ---------
# The earliest snapshot is an exception list, not a work list: packages added
# to the tiers after it was taken must still be re-enabled.
fresh
run apply --tier core >/dev/null 2>&1
d1=$(ls -d "$RUN"/backups/20* | head -1)
awk -F'\t' '$2 !~ /miui\.tv\.analytics/' "$d1/managed.tsv" >"$WORK/m" && mv "$WORK/m" "$d1/managed.tsv"
run apply --tier ads >/dev/null 2>&1
expect_state com.miui.tv.analytics disabled
out=$(run restore 2>&1)
check "T9 restore succeeds" "$?" 0
expect_state com.miui.tv.analytics enabled
expect_state com.mitv.tvhome.michannel enabled

# --- T10: the guide exists in both languages and every image it shows ------
for doc in README.md README.es.md; do
	if [ -f "$ROOT/$doc" ]; then ok "T10 $doc present"; else bad "T10 $doc missing"; fi
done
if python3 "$ROOT/tests/check_docs.py" "$ROOT"; then
	ok "T10 every link and image resolves"
else
	bad "T10 broken reference in the guide"
fi

printf '\n%s\n' "$([ "$fails" -eq 0 ] && echo "all checks passed" || echo "$fails check(s) failed")"
[ "$fails" -eq 0 ]
