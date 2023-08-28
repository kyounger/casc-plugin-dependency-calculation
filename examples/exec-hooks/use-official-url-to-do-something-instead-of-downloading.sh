#!/usr/bin/env bash

set -euo pipefail

echo "Running with:
- PNAME=$PNAME
- PVERSION=$PVERSION
- PFILE=$PFILE (this will be empty if you do not use '-d')
- PURL=$PURL
- PURL_OFFICIAL=$PURL_OFFICIAL
"
echo "WOULD NOW RUN: curl $PURL -sO $PNAME && do something with the file (e.g. kubectl cp to my offline cache)"