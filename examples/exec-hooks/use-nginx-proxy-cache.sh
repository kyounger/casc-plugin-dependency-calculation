#!/usr/bin/env bash

set -euo pipefail

echo "Running with:
- PNAME=$PNAME
- PVERSION=$PVERSION
- PFILE=$PFILE (this will be empty if you do not use '-d')
- PURL=$PURL
- PURL_OFFICIAL=$PURL_OFFICIAL
"
echo "WOULD NOW RUN #2 - curl HIT/MISS: kubectl exec my-artifact-caching-proxy-0 -c artifact-caching-proxy -- curl -I $PURL"
echo "WOULD NOW RUN #3 - curl BYPASS:   kubectl exec my-artifact-caching-proxy-0 -c artifact-caching-proxy -- curl -I -H 'Cache-Purge: true' $PURL"
