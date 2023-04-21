#!/usr/bin/env bash

set -euo pipefail

# echo to stderr and exit 1
die() {
  cat <<< "ERROR: $@" 1>&2
  exit 1
}

[ -n "$GIT_USER" ] || die "GIT_USER environment variable expected"
[ -n "$GIT_TOKEN" ] || die "GIT_TOKEN environment variable expected"
[ -n "$GIT_REPO" ] || die "GIT_REPO environment variable expected"

cat secret.yaml | envsubst
cat deployment.yaml | envsubst
cat service.yaml | envsubst

