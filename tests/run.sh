#!/usr/bin/env bash

set -euo pipefail

# echo to stderr and exit 1
die() {
  cat <<< "ERROR: $@" 1>&2
  exit 1
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUN_CMD="$(dirname $SCRIPT_DIR)/run.sh"
RESULTS_DIR=$(mktemp -d)

VERSION="${VERSION:-2.387.3.5}"
TYPE="${TYPE:-mm}"


for d in $(find $SCRIPT_DIR -mindepth 1 -maxdepth 1 -type d); do
    echo "Testing $(basename $d)..."
    sourceYaml="${d}/source-plugins.yaml"
    targetDir="$d/$VERSION/$TYPE"

    expectedPluginsYaml="${targetDir}/expected-plugins.yaml"
    expectedPluginCatalog="${targetDir}/expected-plugin-catalog.yaml"
    expectedPluginCatalogOffline="${targetDir}/expected-plugin-catalog-offline.yaml"
    actualPluginsYaml="${targetDir}/actual-plugins.yaml"
    actualPluginCatalog="${targetDir}/actual-plugin-catalog.yaml"
    actualPluginCatalogOffline="${targetDir}/actual-plugin-catalog-offline.yaml"

    # sanity checks
    [ -f "${sourceYaml}" ] || die "Expected file '$sourceYaml' doesn't exist."
    [ -d "${targetDir}" ] || die "Expected directory '$targetDir' doesn't exist."
    [ -f "${expectedPluginsYaml}" ] || die "Expected file '$expectedPluginsYaml' doesn't exist."
    [ -f "${expectedPluginCatalog}" ] || die "Expected file '$expectedPluginCatalog' doesn't exist."
    [ -f "${expectedPluginCatalogOffline}" ] || die "Expected file '$expectedPluginCatalogOffline' doesn't exist."

    $RUN_CMD -v "$VERSION" -t "$TYPE" -d \
         -f "${sourceYaml}" \
         -F "${actualPluginsYaml}" \
         -c "${actualPluginCatalog}" \
         -C "${actualPluginCatalogOffline}"

    # files exist?
    [ -f "${actualPluginsYaml}" ] || die "Expected file '$actualPluginsYaml' doesn't exist."
    [ -f "${actualPluginCatalog}" ] || die "Expected file '$actualPluginCatalog' doesn't exist."
    [ -f "${actualPluginCatalogOffline}" ] || die "Expected file '$actualPluginCatalogOffline' doesn't exist."

    # compare
    echo "Diff ${expectedPluginsYaml} vs ${actualPluginsYaml}"
    diff -s "${expectedPluginsYaml}" "${actualPluginsYaml}" || DIFF_FOUND="y"
    echo "Diff ${expectedPluginCatalog} vs ${actualPluginCatalog}"
    diff -s "${expectedPluginCatalog}" "${actualPluginCatalog}" || DIFF_FOUND="y"
    echo "Diff ${expectedPluginCatalogOffline} vs ${actualPluginCatalogOffline}"
    diff -s "${expectedPluginCatalogOffline}" "${actualPluginCatalogOffline}" || DIFF_FOUND="y"
    [ -z "${DIFF_FOUND:-}" ]
done