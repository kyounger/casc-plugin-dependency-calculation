#!/usr/bin/env bash

cd "$(cd "$(dirname "$0")" && pwd)"

"${RUN_CMD}" \
    -v '2.387.3.5,2.401.2.3' \
    -t mm \
    -f "source-plugins-core.yaml" \
    -f "source-plugins-additional.yaml" \
    -s \
    -G "actual-plugins-minimal.yaml" \
    && die "TEST ERROR: Should have failed with a 'duplicate plugins' exception" \
    || echo "TEST INFO: the error above is expected. Now running with deduplication."

"${RUN_CMD}" \
    -v '2.387.3.5,2.401.2.3' \
    -t mm \
    -M \
    -f "source-plugins-core.yaml" \
    -f "source-plugins-additional.yaml" \
    -F "actual-plugins.yaml" \
    -c "actual-plugin-catalog.yaml" \
    -C "actual-plugin-catalog-offline.yaml" \
    -s \
    -G "actual-plugins-minimal.yaml"
