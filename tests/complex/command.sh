#!/usr/bin/env bash

cd "$(cd "$(dirname "$0")" && pwd)"

"${RUN_CMD}" \
    -v '2.387.3.5' \
    -t mm \
    -f "source-plugins.yaml" \
    -F "actual-plugins.yaml" \
    -c "actual-plugin-catalog.yaml" \
    -C "actual-plugin-catalog-offline.yaml" \
    -s \
    -G "actual-plugins-minimal.yaml"
