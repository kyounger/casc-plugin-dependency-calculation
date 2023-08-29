#!/usr/bin/env bash

set -euo pipefail

# echo to stderr and exit 1
function die() {
  errorMe "$@"
  exit 1
}
function errorMe() {
  cat <<< "ERROR: $*" 1>&2
}
export -f die

# tool vars
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_CMD="$(dirname "$SCRIPT_DIR")/run.sh"
export RUN_CMD
TARGET_BASE_DIR="$(dirname "$SCRIPT_DIR")/target"
export TARGET_BASE_DIR
CACHE_BASE_DIR="$(dirname "$SCRIPT_DIR")/.cache"
export CACHE_BASE_DIR

# test vars
ALL_TESTS=$(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d  -printf '%f\n')
TESTS="${1:-$ALL_TESTS}"
CORRECT_TESTS="${CORRECT_TESTS:-0}"

addSummary() {
  TEST_SUMMARY="${TEST_SUMMARY:-Test Summary:\n}$*\n"
}

for testName in $TESTS; do
  testDir="${SCRIPT_DIR}/$testName"
  testName=$(basename "$testDir")
  echo "====================================================="
  echo "TEST INFO: Testing $testName..."
  echo "====================================================="
  expectedDir="${testDir}/expected"
  expectedPluginsYaml="${expectedDir}/plugins.yaml"
  expectedPluginsYamlMinimal="${expectedDir}/plugins-minimal.yaml"
  expectedPluginsYamlMinimalGen="${expectedDir}/plugins-minimal-for-generation-only.yaml"
  expectedPluginCatalog="${expectedDir}/plugin-catalog.yaml"
  expectedPluginCatalogOffline="${expectedDir}/plugin-catalog-offline.yaml"
  actualDir="${testDir}/actual"
  actualPluginsYaml="${actualDir}/plugins.yaml"
  actualPluginsYamlMinimal="${actualDir}/plugins-minimal.yaml"
  actualPluginsYamlMinimalGen="${actualDir}/plugins-minimal-for-generation-only.yaml"
  actualPluginCatalog="${actualDir}/plugin-catalog.yaml"
  actualPluginCatalogOffline="${actualDir}/plugin-catalog-offline.yaml"

  # ensure files exist
  rm -rf "${actualDir}"
  mkdir -p "${actualDir}"
  mkdir -p "${expectedDir}"
  touch \
    "${expectedPluginsYaml}" \
    "${expectedPluginsYamlMinimal}" \
    "${expectedPluginsYamlMinimalGen}" \
    "${expectedPluginCatalog}" \
    "${expectedPluginCatalogOffline}"

  # run command
  "${testDir}/command.sh"

  # resulting files exist?
  [ -f "${actualPluginsYaml}" ] || die "Resulting file '$actualPluginsYaml' doesn't exist."
  [ -f "${actualPluginsYamlMinimal}" ] || die "Resulting file '$actualPluginsYamlMinimal' doesn't exist."
  [ -f "${actualPluginsYamlMinimalGen}" ] || die "Resulting file '$actualPluginsYamlMinimalGen' doesn't exist."
  [ -f "${actualPluginCatalog}" ] || die "Resulting file '$actualPluginCatalog' doesn't exist."
  [ -f "${actualPluginCatalogOffline}" ] || die "Resulting file '$actualPluginCatalogOffline' doesn't exist."

  # compare
  echo "Running diff -s ${expectedDir} ${actualDir}"
  diff -s "${expectedDir}" "${actualDir}" || DIFF_FOUND="y"
  if [ -n "${DIFF_FOUND:-}" ]; then
    if [[ $CORRECT_TESTS -eq 1 ]]; then
      echo "Diff found. Correcting the expected files..."
      cp -v "${actualDir}/"* "${expectedDir}"
      addSummary "Test '$testName' corrected"
    else
      addSummary "Test '$testName' failed (diff -s ${expectedDir} ${actualDir})"
      echo "====================================================="
      echo "Using: diff -s ${expectedPluginsYaml} ${actualPluginsYaml}"
      errorMe "TEST ERROR: Test $testName failed. See above."
    fi
  else
  addSummary "Test '$testName' successful"
  echo "====================================================="
  echo "TEST INFO: Test $testName was SUCCESSFUL."
  echo "====================================================="
  fi
done
echo -e "$TEST_SUMMARY"