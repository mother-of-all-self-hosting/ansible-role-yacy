#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Exercises bin/compute-next-tag.sh against throwaway git repositories.
#
# Usage: bin/test-compute-next-tag.sh
#
# Every scenario creates a repository in a temporary directory, gives it role
# files and a release history, and then replays a series of merges through the
# real script, tagging as it goes just like the autotag workflow does. This
# repository is never touched and no network access is needed.

set -euo pipefail

script_under_test="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/compute-next-tag.sh"

failures=0
workdir=''

cleanup() {
	cd /
	if [ -n "$workdir" ]; then
		rm -rf "$workdir"
		workdir=''
	fi
}

trap cleanup EXIT

# Starts a scenario with a repository shaped like this one really is: a
# `yacy_version` pointing at the floating `latest` tag, because YaCy's upstream
# publishes no versioned image tags, and the release history this repository
# actually carries - two releases of `1.93` and nine of `1.93.2`, none of which
# `yacy_version` has ever named.
#
# The defaults file deliberately carries the traps the real one could grow: a
# commented-out example of the version variable, a Renovate annotation naming
# the image, and an image tag derived from the version. None of them may be
# mistaken for the version.
scenario() {
	echo "$1"

	cleanup
	workdir="$(mktemp -d)"

	mkdir -p "$workdir/bin" "$workdir/defaults" "$workdir/meta" "$workdir/tasks" "$workdir/templates"
	cp "$script_under_test" "$workdir/bin/"
	cd "$workdir"

	git init -q -b main .
	git config user.email 'test@example.com'
	git config user.name 'Test'
	git config commit.gpgsign false

	cat > defaults/main.yml <<-'YAML'
		# yacy_version: 9.9.9
		# renovate: datasource=docker depName=yacy/yacy_search_server
		yacy_version: latest
		yacy_container_image_tag: "{{ yacy_version }}"
		yacy_container_image: "{{ yacy_container_image_registry_prefix }}yacy/yacy_search_server:{{ yacy_container_image_tag }}"
	YAML
	printf 'placeholder\n' > meta/main.yml
	printf 'placeholder\n' > tasks/main.yml
	printf 'placeholder\n' > templates/env.j2
	printf 'placeholder\n' > README.md

	git add -A
	git commit -qm 'Initial commit'

	local tag
	for tag in v1.93-1 v1.93-2 v1.93.2-1 v1.93.2-2 v1.93.2-3 v1.93.2-4 v1.93.2-5 v1.93.2-6 v1.93.2-7 v1.93.2-8 v1.93.2-9; do
		git tag "$tag"
	done
}

# Applies a change, commits it, and tags whatever the script says it should be.
# Prints the tag, or nothing when the script decided against a release.
merge() {
	local change="$1" tag

	eval "$change"
	git add -A
	git commit -qm 'Merge'

	tag="$(bin/compute-next-tag.sh 2>/dev/null)"

	if [ -n "$tag" ]; then
		git tag "$tag"
	fi

	printf '%s' "$tag"
}

expect() {
	local description="$1" expected="$2" actual="$3"

	if [ "$actual" = "$expected" ]; then
		printf '  ok   | %s -> %s\n' "$description" "${actual:-no release}"
	else
		printf '  FAIL | %s -> expected %s, got %s\n' "$description" "${expected:-no release}" "${actual:-no release}"
		failures=$((failures + 1))
	fi
}

pin_version="sed -i 's|^yacy_version: latest|yacy_version: 1.95|' defaults/main.yml"
float_version="sed -i 's|^yacy_version: 1.95|yacy_version: latest|' defaults/main.yml"
edit_task="printf 'a task\n' >> tasks/main.yml"
edit_template="printf 'a line\n' >> templates/env.j2"
edit_meta="printf 'metadata\n' >> meta/main.yml"
edit_readme="printf 'documentation\n' >> README.md"
edit_script="printf '# a comment\n' >> bin/compute-next-tag.sh"

scenario 'Role changes while the version is a floating tag'
expect 'task edit'     v1.93.2-10 "$(merge "$edit_task")"
expect 'template edit' v1.93.2-11 "$(merge "$edit_template")"
expect 'meta edit'     v1.93.2-12 "$(merge "$edit_meta")"

# 1.93.2 is the newest release, but a lexicographic sort would rank the older
# 1.93 above it and the counter would restart from that stream instead.
scenario 'The older 1.93 stream is not mistaken for the newest one'
expect 'a task' v1.93.2-10 "$(merge "$edit_task")"

scenario 'Commits that do not affect the role'
expect 'README'   ''         "$(merge "$edit_readme")"
expect 'a script' ''         "$(merge "$edit_script")"
expect 'a task'   v1.93.2-10 "$(merge "$edit_task")"

scenario 'Release numbers past 9 are compared as numbers'
expect 'a task'         v1.93.2-10 "$(merge "$edit_task")"
expect 'another task'   v1.93.2-11 "$(merge "$edit_task")"
expect 'a third task'   v1.93.2-12 "$(merge "$edit_task")"

# Should YaCy's upstream start publishing versioned image tags again, the
# version stops being carried over and starts its own release counter.
scenario 'The version becoming a real version again'
expect 'pinning a version' v1.95-0 "$(merge "$pin_version")"
expect 'a task'            v1.95-1 "$(merge "$edit_task")"

scenario 'Going back to the floating tag after a pinned version'
merge "$pin_version" > /dev/null
expect 'floating again, with a change' v1.95-1 "$(merge "$float_version && $edit_task")"

# Reverting is a change to the role like any other. With the version half of the
# tag carried over rather than derived, there is no older stream for the revert
# to fall back into, so it gets a release of its own rather than silently
# republishing what an earlier tag already points at.
scenario 'Reverting a change that was already released'
expect 'a task'   v1.93.2-10 "$(merge "$edit_task")"
expect 'a revert' v1.93.2-11 "$(merge "sed -i '\$ d' tasks/main.yml")"

scenario 'A repository that has never released anything'
git tag | xargs -r git tag -d > /dev/null
expect 'a task' v0.0.0-0 "$(merge "$edit_task")"

if [ "$failures" -gt 0 ]; then
	echo >&2 "$failures scenario(s) behaved unexpectedly"
	exit 1
fi

echo 'All scenarios behaved as expected'
