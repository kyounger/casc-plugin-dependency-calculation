#!/usr/bin/env bash

set -euo pipefail

# Using https://jfrog.com/getcli/
echo "Running with:
- PNAME=$PNAME
- PVERSION=$PVERSION
- PFILE=$PFILE
- PURL=$PURL
- PURL_OFFICIAL=$PURL_OFFICIAL
"
echo WOULD NOW RUN: jf rt u "$PFILE" "my-local-repo/plugins/$PNAME/$PVERSION/"