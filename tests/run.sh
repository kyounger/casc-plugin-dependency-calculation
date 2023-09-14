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
CURRENT_DIR=$(pwd)
BASE_DIR=$(dirname "$SCRIPT_DIR")
export RUN_CMD="$BASE_DIR/run.sh"
export TARGET_BASE_DIR="$BASE_DIR/target"
export CACHE_BASE_DIR="$BASE_DIR/.cache"

# test vars
ALL_TESTS=$(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type d  -printf '%f\n')
TESTS="${1:-$ALL_TESTS}"
CORRECT_TESTS="${CORRECT_TESTS:-0}"

addSummary() {
  TEST_SUMMARY="${TEST_SUMMARY:-Test Summary:\n}$*\n"
}

DIFF_FOUND_SOMEWHERE=''
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
  diff -s "${expectedDir}" "${actualDir}" && DIFF_FOUND='' || DIFF_FOUND="y"
  if [ -n "${DIFF_FOUND:-}" ]; then
    DIFF_FOUND_SOMEWHERE='y'
    if [[ $CORRECT_TESTS -eq 1 ]]; then
      echo "Diff found. Correcting the expected files..."
      cp -v "${actualDir}/"* "${expectedDir}"
      addSummary "Test '$testName' corrected"
    else
      addSummary "Test '$testName' failed."
      addSummary "    Analyze: diff -s ${expectedDir#"${CURRENT_DIR}"/} ${actualDir#"${CURRENT_DIR}"/}"
      addSummary "    Correct: cp ${actualDir#"${CURRENT_DIR}"/}/* ${expectedDir#"${CURRENT_DIR}"/}"
      echo "====================================================="
      echo "Using: diff -s ${expectedDir#"${CURRENT_DIR}"/} ${actualDir#"${CURRENT_DIR}"/}"
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
if [ -z "$DIFF_FOUND_SOMEWHERE" ]; then echo "TEST INFO: All tests successful."; else die "Some tests failed."; fi