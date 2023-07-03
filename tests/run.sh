#!/usr/bin/env bash

set -euo pipefail

# echo to stderr and exit 1
function die() {
  cat <<< "ERROR: $@" 1>&2
  exit 1
}
export -f die

# tool vars
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export RUN_CMD="$(dirname $SCRIPT_DIR)/run.sh"
export TARGET_BASE_DIR="$(dirname $SCRIPT_DIR)/target"
export CACHE_BASE_DIR="$(dirname $SCRIPT_DIR)/.cache"

# test vars
RESULTS_DIR=$(mktemp -d)
ALL_TESTS=$(find $SCRIPT_DIR -mindepth 1 -maxdepth 1 -type d  -printf '%f\n')
TESTS="${1:-$ALL_TESTS}"
CORRECT_TESTS="${CORRECT_TESTS:-0}"

for testName in $TESTS; do
    testDir="${SCRIPT_DIR}/$testName"
    echo "TEST INFO: Testing $(basename $testDir)..."
    expectedPluginsYaml="${testDir}/expected-plugins.yaml"
    expectedPluginCatalog="${testDir}/expected-plugin-catalog.yaml"
    expectedPluginCatalogOffline="${testDir}/expected-plugin-catalog-offline.yaml"
    actualPluginsYaml="${testDir}/actual-plugins.yaml"
    actualPluginCatalog="${testDir}/actual-plugin-catalog.yaml"
    actualPluginCatalogOffline="${testDir}/actual-plugin-catalog-offline.yaml"

    # ensure files exist
    touch \
      "${expectedPluginsYaml}" \
      "${expectedPluginCatalog}" \
      "${expectedPluginCatalogOffline}"

    # run command
    "${testDir}/command.sh"

    # resulting files exist?
    [ -f "${actualPluginsYaml}" ] || die "Resulting file '$actualPluginsYaml' doesn't exist."
    [ -f "${actualPluginCatalog}" ] || die "Resulting file '$actualPluginCatalog' doesn't exist."
    [ -f "${actualPluginCatalogOffline}" ] || die "Resulting file '$actualPluginCatalogOffline' doesn't exist."

    # compare
    echo "Diff ${expectedPluginsYaml} vs ${actualPluginsYaml}"
    diff -s "${expectedPluginsYaml}" "${actualPluginsYaml}" || DIFF_FOUND="y"
    echo "Diff ${expectedPluginCatalog} vs ${actualPluginCatalog}"
    diff -s "${expectedPluginCatalog}" "${actualPluginCatalog}" || DIFF_FOUND="y"
    echo "Diff ${expectedPluginCatalogOffline} vs ${actualPluginCatalogOffline}"
    diff -s "${expectedPluginCatalogOffline}" "${actualPluginCatalogOffline}" || DIFF_FOUND="y"
    if [ -n "${DIFF_FOUND:-}" ]; then
      if [[ $CORRECT_TESTS -eq 1 ]]; then
        echo "Diff found. Correcting the expected files..."
        cp -v "${actualPluginsYaml}" "${expectedPluginsYaml}"
        cp -v "${actualPluginCatalog}" "${expectedPluginCatalog}"
        cp -v "${actualPluginCatalogOffline}" "${expectedPluginCatalogOffline}"
      else
        die "TEST ERROR: Test $(basename $testDir) failed. See above."
      fi
    else
    echo "TEST INFO: Test $(basename $testDir) was SUCCESSFUL."
    fi
done