#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Slavi Pantaleev
#
# SPDX-License-Identifier: AGPL-3.0-or-later

# Prints the tag that the currently checked out commit should be released as,
# or nothing at all if it does not warrant a release.
#
# Usage: bin/compute-next-tag.sh
#
# Tags look like `v<YaCy version>-<release>`, which is what this repository has
# always published (v1.93-1 ... v1.93.2-9).
#
# The version half is a problem here, and the reason this script has a branch
# that its counterparts in other roles do not need. YaCy's upstream has not
# published a versioned container image tag since `1.93` in May 2024: docker.io
# only carries `latest`, `latest-ubuntu`, `latest-alpine`, a couple of
# `sha-<commit>-<flavour>` tags and the ancient per-architecture ones. The role
# therefore points `yacy_version` at the floating `latest`, and no amount of
# annotation would give Renovate a version to bump.
#
# So:
#
# - if `yacy_version` ever names an actual version again, that version is used,
#   and a version that has never been released starts its release counter at 0
#   (the usual behaviour of this script across the fleet)
# - while it names a floating tag, the version half is carried over from the
#   newest version this repository has already released, and only the release
#   counter moves
#
# Either way the tag is derived from defaults/main.yml plus the tags that
# already exist, never from the commit message of whatever pull request got
# merged. That makes the result independent of the order in which pull requests
# land, and lets any change to the role - a bugfix, a feature, a dependency
# bump - release itself without a human tagging it. The commit-message
# workflow this replaced looked for a Renovate subject saying "docker tag to
# ..." and, since Renovate has never had a version here to bump, had never once
# fired in this repository: every one of the tags above was cut by hand.

set -euo pipefail

repository_path="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd -- "$repository_path"

defaults_path='defaults/main.yml'

# Paths that shape the behavior of the role for its consumers. A commit
# touching only other paths (a README fix, CI configuration, Molecule tests)
# does not change what a playbook run does, and releasing it would only create
# churn in the repositories that consume this role.
role_defining_paths=(
	'defaults'
	'meta'
	'tasks'
	'templates'
)

# Anchored on `yacy_version:` so that neither a commented-out example nor
# `yacy_container_image_tag`, which is derived from it, can be mistaken for it.
version="$(sed -nE 's|^yacy_version:[[:space:]]*"?([^"[:space:]]+)"?.*$|\1|p' "$defaults_path" | head -n1)"

if [ -z "$version" ]; then
	echo >&2 "Could not determine the YaCy version from $defaults_path"
	exit 1
fi

# Every version this repository has ever released, newest last. `sort -V` is
# what tells 1.93.2 from 1.93, which a lexicographic sort would get backwards.
released_versions="$(git tag --list 'v*-*' | sed -nE 's|^v(.+)-[0-9]+$|\1|p' | sort -u -V)"

if printf '%s' "$version" | grep -qE '^v?[0-9]+(\.[0-9]+)*$'; then
	# `yacy_version` names an actual version. The `v` lives in the tags rather
	# than in the value, but tolerate one so that a future change of convention
	# cannot produce a doubled prefix.
	version="${version#v}"
	restart_counter='yes'
else
	# `yacy_version` names a floating tag (`latest`), so it says nothing about
	# which version of YaCy is being installed and cannot name a release. The
	# version half of the tag is carried over unchanged from the newest release,
	# and only the counter moves.
	echo >&2 "yacy_version is '$version', which is not a version"

	version="$(printf '%s\n' "$released_versions" | tail -n1)"
	restart_counter='no'

	if [ -z "$version" ]; then
		# Nothing has ever been released and there is no version to carry over.
		# Start a stream that sorts below any real version, the way other roles
		# in this fleet without an upstream version number do.
		version='0.0.0'
	fi

	echo >&2 "Carrying the version of the newest release ($version) over"
fi

tag_prefix="v${version}-"

# Of all releases of this version, the highest release number. Sorted
# numerically, so that -10 is recognized as newer than -9.
last_release="$(git tag --list "${tag_prefix}*" | sed -e "s|^${tag_prefix}||" | grep -E '^[0-9]+$' | sort -n | tail -n1 || true)"

if [ -z "$last_release" ]; then
	if [ "$restart_counter" = 'yes' ]; then
		echo >&2 "Version $version has never been released"
		echo "${tag_prefix}0"
		exit 0
	fi

	# Only reachable when nothing has ever been released at all.
	echo >&2 'Nothing has ever been released'
	echo "${tag_prefix}0"
	exit 0
fi

previous_tag="${tag_prefix}${last_release}"

if git diff --quiet "$previous_tag" HEAD -- "${role_defining_paths[@]}"; then
	echo >&2 "Nothing affecting the role has changed since $previous_tag"
	exit 0
fi

echo >&2 "The role has changed since $previous_tag"
echo "${tag_prefix}$((last_release + 1))"
