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
    echo "====================================================="
    echo "TEST INFO: Testing $(basename $testDir)..."
    echo "====================================================="
    expectedPluginsYaml="${testDir}/expected-plugins.yaml"
    expectedPluginsYamlMinimal="${testDir}/expected-plugins-minimal.yaml"
    expectedPluginCatalog="${testDir}/expected-plugin-catalog.yaml"
    expectedPluginCatalogOffline="${testDir}/expected-plugin-catalog-offline.yaml"
    actualPluginsYaml="${testDir}/actual-plugins.yaml"
    actualPluginsYamlMinimal="${testDir}/actual-plugins-minimal.yaml"
    actualPluginCatalog="${testDir}/actual-plugin-catalog.yaml"
    actualPluginCatalogOffline="${testDir}/actual-plugin-catalog-offline.yaml"

    # ensure files exist
    touch \
      "${expectedPluginsYaml}" \
      "${expectedPluginsYamlMinimal}" \
      "${expectedPluginCatalog}" \
      "${expectedPluginCatalogOffline}"

    # run command
    "${testDir}/command.sh"

    # resulting files exist?
    [ -f "${actualPluginsYaml}" ] || die "Resulting file '$actualPluginsYaml' doesn't exist."
    [ -f "${actualPluginsYamlMinimal}" ] || die "Resulting file '$actualPluginsYamlMinimal' doesn't exist."
    [ -f "${actualPluginCatalog}" ] || die "Resulting file '$actualPluginCatalog' doesn't exist."
    [ -f "${actualPluginCatalogOffline}" ] || die "Resulting file '$actualPluginCatalogOffline' doesn't exist."

    # compare
    echo "Running diff -s ${expectedPluginsYaml} ${actualPluginsYaml}"
    diff -s "${expectedPluginsYaml}" "${actualPluginsYaml}" || DIFF_FOUND="y"
    echo "Running diff -s ${expectedPluginsYamlMinimal} ${actualPluginsYamlMinimal}"
    diff -s "${expectedPluginsYamlMinimal}" "${actualPluginsYamlMinimal}" || DIFF_FOUND="y"
    echo "Running diff -s ${expectedPluginCatalog} ${actualPluginCatalog}"
    diff -s "${expectedPluginCatalog}" "${actualPluginCatalog}" || DIFF_FOUND="y"
    echo "Running diff -s ${expectedPluginCatalogOffline} ${actualPluginCatalogOffline}"
    diff -s "${expectedPluginCatalogOffline}" "${actualPluginCatalogOffline}" || DIFF_FOUND="y"
    if [ -n "${DIFF_FOUND:-}" ]; then
      if [[ $CORRECT_TESTS -eq 1 ]]; then
        echo "Diff found. Correcting the expected files..."
        cp -v "${actualPluginsYaml}" "${expectedPluginsYaml}"
        cp -v "${actualPluginsYamlMinimal}" "${expectedPluginsYamlMinimal}"
        cp -v "${actualPluginCatalog}" "${expectedPluginCatalog}"
        cp -v "${actualPluginCatalogOffline}" "${expectedPluginCatalogOffline}"
      else
        echo "====================================================="
        die "TEST ERROR: Test $(basename $testDir) failed. See above."
        echo "====================================================="
      fi
    else
    echo "====================================================="
    echo "TEST INFO: Test $(basename $testDir) was SUCCESSFUL."
    echo "====================================================="
    fi
done