#!/usr/bin/env bash
# Reversible debloat for Xiaomi Mi Box S (MIBOX4, Android TV 9) over ADB.
#
# Strategy: `pm disable-user --user 0` only. Nothing is uninstalled, so every
# change is undone by `restore`. A backup is always taken before any write.
#
# Package sets come from the community list for this exact box:
#   Gathin23/cleanyourtv -> examples/xiaomi-mi-box-s/debloat.txt
# plus jolan94/tidytv and ccavus/mibox-debloat (MDZ-22-AB specific).
# Verify anything you add yourself with `pm list packages -d` before / after.

set -uo pipefail

PROG=${0##*/}
BACKUP_ROOT=${BACKUP_ROOT:-backups}
ADB_SERIAL=${ADB_SERIAL:-}
DRY_RUN=0
TIERS=""
RESTORE_FROM=""

# Ads feed, telemetry and the Xiaomi video player. Safe on MIBOX4.
TIER_CORE="
com.mitv.tvhome.michannel
com.mitv.milinkservice
com.mitv.videoplayer
"

# Advertising, tracking and the promos Xiaomi pushes on top of the home screen.
TIER_ADS="
# Mi analytics: reads logs and app usage
com.miui.tv.analytics
# Alphonso automatic content recognition, an ad-tracking service
tv.alphonso.alphonso_eula
# Xiaomi web promos
com.xm.webcontent
# Google telemetry
com.google.android.tv.bugreportsender
# the recommendation rows on the home screen
com.google.android.tvrecommendations
# installs partner apps at setup; the "xioami" typo is in the real name
android.autoinstalls.config.xioami.mibox3
# Xiaomi content app; not in the upstream list for this box, seen running here
com.mitv.tvhome.mitvplus
"

# Preinstalled apps you may actually use. Disabled only if you ask for them.
# shortcut: this tier guesses at your habits rather than checking them; drop
# any entry you use before running `apply --tier junk`.
TIER_JUNK="
com.google.android.videos
com.google.android.play.games
com.google.android.feedback
com.android.printspooler
"

# Firmware updates. Disabling these stops the OTA that keeps pushing PatchWall.
TIER_OTA="
# firmware and PatchWall updates, installs apps; re-enable to check for an update
com.xiaomi.mitv.updateservice
# its download helper
com.mitv.download.service
"

# Setup customizer. Upstream says leave it alone: it receives the remote's
# shortcut buttons as GLOBAL_BUTTON and runs the remote-pairing steps.
TIER_SETUP="
com.xiaomi.android.tvsetup.partnercustomizer
"

# The Xiaomi ad launcher on its own. Safe: com.google.android.tvlauncher stays
# enabled and remains the home screen, so nothing is lost if this fails.
TIER_PATCHWALL="
com.mitv.tvhome.atv
"

# Stock launchers. Disabling these without a working replacement leaves the
# box with no home screen. Never included by default.
TIER_LAUNCHERS="
com.mitv.tvhome.atv
com.google.android.tvlauncher
"

usage() {
	cat <<EOF
$PROG - reversible debloat for Xiaomi Mi Box S (MIBOX4 / MDZ-22-AB)

Usage: $PROG <command> [options]

Commands:
  check                 Verify ADB sees the box and summarise its state
  list                  Show managed packages and their current state
  backup                Snapshot package state into $BACKUP_ROOT/
  apply                 Backup, then disable the selected tiers
  restore               Re-enable what the earliest snapshot recorded as enabled
  help                  This text

Options:
  --tier NAME           Package set for apply: core, ads, junk, ota, setup,
                        patchwall, launchers, all (repeatable). Default: core,ads,junk
  --from DIR            Snapshot to restore from (default: earliest in $BACKUP_ROOT)
  --serial SERIAL       Target this ADB serial (default: the only connected one)
  --dry-run             Print the intended commands, change nothing
  -h, --help            This text

Exit codes: 0 success, 1 failure, 2 usage error.
EOF
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '%s: %s\n' "$PROG" "$*" >&2; usage >&2; exit 2; }

say()  { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }

# --- adb plumbing ------------------------------------------------------------

adb_cmd() {
	if [ -n "$ADB_SERIAL" ]; then
		adb -s "$ADB_SERIAL" "$@"
	else
		adb "$@"
	fi
}

require_device() {
	command -v adb >/dev/null 2>&1 || die "adb is not on PATH"
	local state
	state=$(adb_cmd get-state 2>&1) || true
	[ "$state" = "device" ] || die "no usable device (adb get-state said: ${state:-empty}).
Enable developer options on the box, turn on USB debugging, then:
  - from an Android phone: install Bugjaeger, connect to <TV_IP>:5555, accept the prompt; or
  - over USB: attach the box, run 'adb tcpip 5555', unplug.
Then 'adb connect <TV_IP>:5555' and re-run this command."
}

# Prints one package name per line.
pm_list() {
	local flag=$1
	adb_cmd shell pm list packages "$flag" 2>/dev/null |
		tr -d '\r' | sed -e 's/^package://' -e '/^$/d' | sort -u
}

# Snapshot of both lists, cached for the current run.
ENABLED_PKGS=""
DISABLED_PKGS=""
load_package_lists() {
	ENABLED_PKGS=$(pm_list -e)
	DISABLED_PKGS=$(pm_list -d)
}

in_list() { printf '%s\n' "$2" | grep -Fxq "$1"; }

package_state() {
	if in_list "$1" "$DISABLED_PKGS"; then
		echo disabled
	elif in_list "$1" "$ENABLED_PKGS"; then
		echo enabled
	else
		echo absent
	fi
}

# --- package sets ------------------------------------------------------------

tier_packages() {
	case $1 in
	core)     printf '%s\n' "$TIER_CORE" ;;
	ads)      printf '%s\n' "$TIER_ADS" ;;
	junk)     printf '%s\n' "$TIER_JUNK" ;;
	ota)      printf '%s\n' "$TIER_OTA" ;;
	setup)    printf '%s\n' "$TIER_SETUP" ;;
	patchwall) printf '%s\n' "$TIER_PATCHWALL" ;;
	launchers) printf '%s\n' "$TIER_LAUNCHERS" ;;
	all)      tier_packages core; tier_packages ads; tier_packages junk; tier_packages ota; tier_packages setup; tier_packages patchwall; tier_packages launchers ;;
	*)        return 1 ;;
	esac | sed -e '/^$/d' -e '/^#/d'
}

selected_packages() {
	local tier
	for tier in ${TIERS//,/ }; do
		tier_packages "$tier" || die "unknown tier: $tier"
	done | sort -u
}

# Every package this script knows about, regardless of tier.
all_managed_packages() {
	tier_packages all | sort -u
}

# --- backup ------------------------------------------------------------------

# The earliest snapshot is the state before this script first touched the box.
# Restoring from it is what "undo" means, even after several apply runs, each
# of which snapshots the already-debloated state.
initial_backup() {
	[ -d "$BACKUP_ROOT" ] || return 1
	find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' 2>/dev/null |
		sort | head -n 1
}

cmd_backup() {
	require_device
	local stamp dir
	stamp=$(date +%Y%m%d-%H%M%S%N) # nanoseconds: two runs in one second must not share a dir
	dir="$BACKUP_ROOT/$stamp"
	mkdir -p "$dir" || die "cannot create $dir"

	load_package_lists
	{
		printf '# state\tpackage\n'
		local pkg
		while IFS= read -r pkg; do
			[ -n "$pkg" ] || continue
			printf '%s\t%s\n' "$(package_state "$pkg")" "$pkg"
		done < <(all_managed_packages)
	} >"$dir/managed.tsv" || die "cannot write $dir/managed.tsv"

	printf '%s\n' "$ENABLED_PKGS" >"$dir/enabled.txt"
	printf '%s\n' "$DISABLED_PKGS" >"$dir/disabled.txt"
	adb_cmd shell getprop ro.build.fingerprint 2>/dev/null | tr -d '\r' >"$dir/build.txt"

	say "Backup written to $dir"
	note "$(wc -l <"$dir/managed.tsv") managed packages recorded"
	note "enabled: $(wc -l <"$dir/enabled.txt"), disabled: $(wc -l <"$dir/disabled.txt")"
	BACKUP_DIR=$dir
}

# --- commands ----------------------------------------------------------------

cmd_check() {
	require_device
	local model build
	model=$(adb_cmd shell getprop ro.product.model 2>/dev/null | tr -d '\r')
	build=$(adb_cmd shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')
	say "Device:  ${model:-unknown} (Android ${build:-unknown})"
	load_package_lists
	say "Packages: $(printf '%s\n' "$ENABLED_PKGS" | grep -c .) enabled, $(printf '%s\n' "$DISABLED_PKGS" | grep -c .) disabled by user"
	if [ "$model" != "MIBOX4" ]; then
		say "Warning: expected model MIBOX4 (Mi Box S 1st gen). The package list is tuned for it."
	fi
}

cmd_list() {
	require_device
	load_package_lists
	local pkg state
	while IFS= read -r pkg; do
		[ -n "$pkg" ] || continue
		state=$(package_state "$pkg")
		printf '%-12s %s\n' "$state" "$pkg"
	done < <(all_managed_packages)
}

cmd_apply() {
	[ -n "$TIERS" ] || TIERS="core,ads,junk"
	require_device
	cmd_backup >/dev/null || die "backup failed, refusing to change anything"

	local -a wanted
	mapfile -t wanted < <(selected_packages)
	[ "${#wanted[@]}" -gt 0 ] || die "no packages selected"

	say "Backup: $BACKUP_DIR"
	say "Disabling ${#wanted[@]} package(s) [tiers: $TIERS]"

	local pkg state failed=0 changed=0
	local -a applied=()
	for pkg in "${wanted[@]}"; do
		state=$(package_state "$pkg")
		case $state in
			absent)
				printf '[skip] %-45s not installed\n' "$pkg"
				;;
			disabled)
				printf '[skip] %-45s already disabled\n' "$pkg"
				;;
			enabled)
				if [ "$DRY_RUN" = 1 ]; then
					printf '[dry ] %-45s would be disabled\n' "$pkg"
					changed=$((changed + 1))
				elif adb_cmd shell pm disable-user --user 0 "$pkg" >/dev/null; then
					printf '[ ok ] %-45s disabled\n' "$pkg"
					applied+=("$pkg")
					changed=$((changed + 1))
				else
					printf '[fail] %-45s disable rejected\n' "$pkg"
					failed=$((failed + 1))
				fi
				;;
		esac
	done

	printf '%s\t%s\n' "$(date -Is)" "apply tiers=$TIERS changed=$changed failed=$failed" \
		>>"$BACKUP_DIR/actions.log"

	if [ "$DRY_RUN" = 1 ]; then
		say "Dry run: nothing was changed."
		return 0
	fi

	# Confirm against the device instead of trusting the disable loop.
	if [ "${#applied[@]}" -gt 0 ]; then
		load_package_lists
		for pkg in "${applied[@]}"; do
			[ "$(package_state "$pkg")" = "disabled" ] ||
				{ printf '[fail] %-45s still enabled after disable\n' "$pkg"; failed=$((failed + 1)); }
		done
	fi

	say "Changed $changed, failed $failed. Undo with: $PROG restore --from $BACKUP_DIR"
	[ "$failed" -eq 0 ] || return 1
}

cmd_restore() {
	require_device
	local dir=${RESTORE_FROM:-$(initial_backup)}
	[ -n "$dir" ] && [ -f "$dir/managed.tsv" ] || die "no snapshot found (looked in $BACKUP_ROOT)"

	load_package_lists
	say "Restoring from $dir"

	# The snapshot is the exception list, not the work list: a package it
	# recorded as disabled was already off before this script ran. Everything
	# else that is disabled now is ours to undo, including packages added to
	# the tiers after that snapshot was taken.
	local pkg state recorded restored=0 failed=0
	while IFS= read -r pkg; do
		[ -n "$pkg" ] || continue
		state=$(package_state "$pkg")
		if [ "$state" != "disabled" ]; then
			continue
		fi
		recorded=$(awk -F'\t' -v p="$pkg" '$2 == p { print $1 }' "$dir/managed.tsv")
		if [ "$recorded" = "disabled" ]; then
			printf '[skip] %-45s was already disabled before this script\n' "$pkg"
			continue
		fi
		if [ "$DRY_RUN" = 1 ]; then
			printf '[dry ] %-45s would be re-enabled\n' "$pkg"
			restored=$((restored + 1))
		elif adb_cmd shell pm enable "$pkg" >/dev/null; then
			printf '[ ok ] %-45s re-enabled\n' "$pkg"
			restored=$((restored + 1))
		else
			printf '[fail] %-45s enable rejected\n' "$pkg"
			failed=$((failed + 1))
		fi
	done < <(all_managed_packages)

	printf '%s\t%s\n' "$(date -Is)" "restore from=$dir restored=$restored failed=$failed" \
		>>"$dir/actions.log"

	say "Re-enabled $restored, failed $failed."
	[ "$failed" -eq 0 ] || return 1
}

# --- argument parsing --------------------------------------------------------

COMMAND=""
while [ $# -gt 0 ]; do
	case $1 in
		check|list|backup|apply|restore|help|-h|--help)
			COMMAND=$1
			shift
			;;
		--tier)
			[ $# -ge 2 ] || usage_error "--tier needs a value"
			case $2 in
				core|ads|junk|ota|setup|patchwall|launchers|all) ;;
				*) usage_error "unknown tier: $2 (core, ads, junk, ota, setup, patchwall, launchers, all)" ;;
			esac
			TIERS=${TIERS:+$TIERS,}$2
			shift 2
			;;
		--from)
			[ $# -ge 2 ] || usage_error "--from needs a value"
			RESTORE_FROM=$2
			shift 2
			;;
		--serial)
			[ $# -ge 2 ] || usage_error "--serial needs a value"
			ADB_SERIAL=$2
			shift 2
			;;
		--dry-run)
			DRY_RUN=1
			shift
			;;
		*)
			usage_error "unknown argument: $1"
			;;
	esac
done

case $COMMAND in
	check)   cmd_check ;;
	list)    cmd_list ;;
	backup)  cmd_backup ;;
	apply)   cmd_apply ;;
	restore) cmd_restore ;;
	''|help|-h|--help) usage ;;
esac
