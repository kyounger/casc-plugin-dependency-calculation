#!/usr/bin/env bash

# This script checks the versions dependencies of plugins in the update center
# and compares them with the versions published by the update center.
# If the version of a dependency is lower than the required version, it will be printed.
#
# Usage: ./version-check.sh <version>
# Example: ./version-check.sh 2.289.1

set -euo pipefail

# Pre-requisites
command -v jq >/dev/null || { echo "jq is required but it's not installed. Aborting." >&2; exit 1; }
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <version>"
    exit 1
fi

echo "Checking dependencies for version $1"
# Online Extract dependencies with versions
UC_JSON=$(curl -sL "https://jenkins-updates.cloudbees.com/update-center/envelope-core-mm/update-center.json?version=${1}" | head -n-1 | tail -n+2)
versions=$(jq -r '.plugins[] | "\(.name):\(.version)"' <<< "$UC_JSON")
dependencies=$(jq -r '.plugins[] | .name as $plugin | .dependencies[] | "\($plugin):\(.name):\(.version)"' <<< "$UC_JSON")
# Offline Extract dependencies with versions
# DEPENDENCIES_JSON="target/${1}/mm/generated/update-center-online.json"
# versions=$(jq -r '.plugins[] | "\(.name):\(.version)"' "$DEPENDENCIES_JSON")
# dependencies=$(jq -r '.plugins[] | .name as $plugin | .dependencies[] | "\($plugin):\(.name):\(.version)"' "$DEPENDENCIES_JSON")

declare -A plugin_versions
while IFS=: read -r plugin version; do
    plugin_versions["$plugin"]="$version"
done <<< "$versions"

# Need to remove the .v from the version to compare since sort -V takes the .v* as a string
normalize_version() {
    sed -E "s/([0-9])\.v/\1-v/g" <<< "$1"
}
# Compare versions
output_all=""
while IFS=: read -r plugin dependency dep_version; do
    if [[ -n "${plugin_versions[$dependency]:-}" ]]; then
        provided_version="${plugin_versions[$dependency]}"
        # echo "Checking $plugin -> $dependency ($provided_version vs $dep_version)"
        provided_version_normalized=$(normalize_version "$provided_version")
        dep_version_normalized=$(normalize_version "$dep_version")
        if [[ "$(printf '%s\n%s' "${provided_version_normalized}" "${dep_version_normalized}" | sort -V | tail -n1)" != "${provided_version_normalized}" ]]; then
            output="Dependency: $dependency (offered version $provided_version < $dep_version from the dependency) - from plugin $plugin"
            [ -z "$output_all" ] && output_all="$output" || output_all="$output_all\n$output"
        fi
    fi
done <<< "$dependencies"
# sort the output
[ -z "$output_all" ] || echo -e "$output_all" | sort -u