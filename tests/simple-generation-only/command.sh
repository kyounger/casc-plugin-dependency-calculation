#!/usr/bin/env bash

set -eu
cd "$(cd "$(dirname "$0")" && pwd)"

"${RUN_CMD}" \
    -v '2.387.3.5' \
    -t mm \
    -f "source-plugins.yaml" \
    -F "actual/plugins.yaml" \
    -c "actual/plugin-catalog.yaml" \
    -C "actual/plugin-catalog-offline.yaml" \
    -s \
    -g "actual/plugins-minimal-for-generation-only.yaml" \
    -G "actual/plugins-minimal.yaml" \
    && die "TEST ERROR: Should have failed with a 'plugin not found' exception" \
    || echo "TEST INFO: the error above is expected. Now running with '-A' (generation only plugins)."


"${RUN_CMD}" \
    -v '2.387.3.5' \
    -t mm \
    -f "source-plugins.yaml" \
    -F "actual/plugins.yaml" \
    -c "actual/plugin-catalog.yaml" \
    -C "actual/plugin-catalog-offline.yaml" \
    -s \
    -A \
    -g "actual/plugins-minimal-for-generation-only.yaml" \
    -G "actual/plugins-minimal.yaml"