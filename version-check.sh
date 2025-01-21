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

# Compare versions
output_all=""
while IFS=: read -r plugin dependency dep_version; do
    if [[ -n "${plugin_versions[$dependency]:-}" ]]; then
        installed_version="${plugin_versions[$dependency]}"
        # echo "Checking $plugin -> $dependency ($installed_version vs $dep_version)"
        if [[ "$(printf '%s\n%s' "$installed_version" "$dep_version" | sort -V | tail -n1)" != "$installed_version" ]]; then
            output="Dependency: $dependency (required version $installed_version != $dep_version in the update center) - from plugin $plugin"
            [ -z "$output_all" ] && output_all="$output" || output_all="$output_all\n$output"
        fi
    fi
done <<< "$dependencies"
# sort the output
[ -z "$output_all" ] || { echo -e "$output_all" | sort -u; }