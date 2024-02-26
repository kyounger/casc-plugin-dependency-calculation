#!/usr/bin/env bash

set -euo pipefail

# Setting LC_ALL=C to avoid sorting issues with yq and locales
export LC_ALL=C

# load .env if present
loadDotenv() {
    local dotEnvFile="${1:-"${WORKSPACE}"}/.env"
    if [ -f "${dotEnvFile}" ]; then
        debug "INFO: Found .env sourcing the file: ${dotEnvFile}"
        # check for allexport...
        if [ "$-" = "${-%a*}" ]; then
            # allexport is not set
            set -a
            # shellcheck source=/dev/null
            . "${dotEnvFile}"
            set +a
        else
            # shellcheck source=/dev/null
            . "${dotEnvFile}"
        fi
    fi
}

setDirs() {
    local bundleFilter="${1:-}"
    BUNDLE_FILTER=''
    if [ -n "${bundleFilter}" ]; then
        if [[ "$bundleFilter" =~ ^raw-bundles\/.* ]]; then
            BUNDLE_FILTER="${bundleFilter#raw-bundles/}"
            BUNDLE_FILTER="${BUNDLE_FILTER//\//}"
            debug "INFO: Filtering - BUNDLE_FILTER set to '$BUNDLE_FILTER' (from '$bundleFilter')"
        elif [[ "$bundleFilter" =~ .*\/raw-bundles\/.* ]]; then
            BUNDLE_SUB_DIR="${bundleFilter//\/raw-bundles*/}"
            BUNDLE_FILTER="${bundleFilter#*raw-bundles/}"
            BUNDLE_FILTER="${BUNDLE_FILTER//\//}"
            debug "INFO: Filtering - BUNDLE_FILTER set to '$BUNDLE_FILTER' (from '$bundleFilter')"
            debug "INFO: Filtering - BUNDLE_SUB_DIR set to '$BUNDLE_SUB_DIR' (from '$bundleFilter')"
        elif [ -d "${bundleFilter}/raw-bundles" ]; then
            BUNDLE_SUB_DIR="${bundleFilter}"
            debug "INFO: Filtering - BUNDLE_SUB_DIR set to '$BUNDLE_SUB_DIR' (from '$bundleFilter')"
        else
            BUNDLE_FILTER="${bundleFilter}"
        fi
    fi

    loadDotenv
    VALIDATIONS_BUNDLE_PREFIX="${VALIDATIONS_BUNDLE_PREFIX_ORIG}"
    # set the bundle sub dir detected from the current workspace
    if [ "${WORKSPACE}" != "${GIT_ROOT}" ]; then
        BUNDLE_SUB_DIR="${WORKSPACE#"${GIT_ROOT}"/}"
        debug "INFO: Setting BUNDLE_SUB_DIR to ${BUNDLE_SUB_DIR}"
    fi
    [ "${BUNDLE_SUB_DIR:-}" != '.' ] || BUNDLE_SUB_DIR=''
    if [ -n "${BUNDLE_SUB_DIR:-}" ]; then
        # set the prefix to include the bundle sub dir
        VALIDATIONS_BUNDLE_PREFIX="${VALIDATIONS_BUNDLE_PREFIX}${BUNDLE_SUB_DIR}-"
        # check to see the workspace already includes the bundle sub dir
        if [[ $(basename "${WORKSPACE}") == "${BUNDLE_SUB_DIR}" ]]; then
            debug "INFO: BUNDLE_SUB_DIR already part of WORKSPACE: ${WORKSPACE}"
        else
            debug "INFO: Setting WORKSPACE to BUNDLE_SUB_DIR: ${WORKSPACE}/${BUNDLE_SUB_DIR}"
            TEST_RESOURCES_DIR_RELATIVE="${BUNDLE_SUB_DIR}/test-resources"
            EFFECTIVE_DIR_RELATIVE="${BUNDLE_SUB_DIR}/effective-bundles"
            VALIDATIONS_DIR_RELATIVE="${BUNDLE_SUB_DIR}/validation-bundles"
            RAW_DIR_RELATIVE="${BUNDLE_SUB_DIR}/raw-bundles"
        fi
        # load .env in the bundle sub dir
        loadDotenv "${WORKSPACE}/${BUNDLE_SUB_DIR}"
    fi

    # assuming some variables - can be overwritten
    TEST_RESOURCES_DIR="${WORKSPACE}/${TEST_RESOURCES_DIR_RELATIVE}"
    EFFECTIVE_DIR="${WORKSPACE}/${EFFECTIVE_DIR_RELATIVE}"
    VALIDATIONS_DIR="${WORKSPACE}/${VALIDATIONS_DIR_RELATIVE}"
    RAW_DIR="${WORKSPACE}/${RAW_DIR_RELATIVE}"

    TEST_RESOURCES_CI_VERSIONS="${TEST_RESOURCES_DIR}/.ci-versions"
    TEST_RESOURCES_CHANGED_FILES="${TEST_RESOURCES_DIR}/.changed-files"
    TEST_RESOURCES_CHANGED_BUNDLES="${TEST_RESOURCES_DIR}/.changed-effective-bundles"

    VALIDATIONS_TEMPLATE="${VALIDATIONS_TEMPLATE:-template}"
    CHECKSUM_PLUGIN_FILES_KEY='CHECKSUM_PLUGIN_FILES'
    export TARGET_BASE_DIR="${TARGET_BASE_DIR:-"${GIT_ROOT}/target"}"
    export CACHE_BASE_DIR="${CACHE_BASE_DIR:-"${GIT_ROOT}/.cache"}"

    # optional kustomization.yaml creation
    KUSTOMIZATION_YAML="${EFFECTIVE_DIR}/kustomization.yaml"
}

toolCheck() {
    local tools="${1:-}"
    for tool in $tools; do
        command -v "${tool}" &> /dev/null || die "You need to install ${tool}"
        if [ "$tool" == "yq" ]; then
            local yqVersion=''
            yqVersion=$(yq --version | grep -oE "([0-9]+\.[0-9]+\.[0-9]+)")
            [ "$(ver "${MIN_VER_YQ}")" -lt "$(ver "$yqVersion")" ] || die "Please upgrade yq to at least '$MIN_VER_YQ' (currently '$yqVersion')"
        fi
    done
}

# util function to test versions
ver() {
    echo "$@" | awk -F. '{ printf("%d%03d%03d", $1,$2,$3); }'
}

die() { echo "$*"  >&2; exit 1; }

debug() { if [ "$DEBUG" -eq 1 ]; then echo "$*" >&2; fi; }

# minimal tool versions
MIN_VER_YQ="4.35.2"

# set the root of the git repo and the workspace
GIT_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
WORKSPACE="${WORKSPACE:-$(pwd)}"
if [ -z "${GIT_ROOT}" ]; then
    debug "WARN: Could not determine GIT_ROOT. Using WORKSPACE as root."
    GIT_ROOT="${WORKSPACE}"
fi
CONFIGMAP_INCLUDE_VERSION_IN_NAME="${CONFIGMAP_INCLUDE_VERSION_IN_NAME:-"true"}"
TEST_RESOURCES_DIR_RELATIVE="test-resources"
EFFECTIVE_DIR_RELATIVE="effective-bundles"
VALIDATIONS_DIR_RELATIVE="validation-bundles"
RAW_DIR_RELATIVE="raw-bundles"
VALIDATIONS_BUNDLE_PREFIX_ORIG="val-"

MD5SUM_EMPTY_STR=$(echo -n | md5sum | cut -d' ' -f 1)
CI_TYPE="${CI_TYPE:-mm}"
MINIMUM_PLUGINS_CASC_CONTROLLER="cloudbees-casc-items-controller"
MINIMUM_PLUGINS_CASC_OC="cloudbees-casc-items-server cloudbees-casc-items-commons"
MINIMUM_PLUGINS_CASC_ERR="Minimum plugins error - you need at a minimum cloudbees-casc-client and, if using items, "
BUNDLE_SECTIONS='jcasc items plugins catalog variables rbac'
DRY_RUN="${DRY_RUN:-1}"
# automatically update catalog if plugin yamls have changed. supercedes DRY_RUN
AUTO_UPDATE_CATALOG="${AUTO_UPDATE_CATALOG:-1}"
DEBUG="${DEBUG:-0}"
TREE_CMD=$(command -v tree || true)
CASCGEN_TOOL="${BASH_SOURCE[0]}"
SCRIPT_DIR="$(cd "$(dirname "${CASCGEN_TOOL}")" >/dev/null && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"

# CI_VERSION env var set, no detection necessary. Otherwise,
# version detection (detected in the following order):
# - name of parent directory of RAW_DIR
# - name of current git branch (if git on PATH)
CI_DETECTION_PATTERN_DEFAULT="v([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"
CI_DETECTION_PATTERN="${CI_DETECTION_PATTERN:-"${CI_DETECTION_PATTERN_DEFAULT}"}"
CI_TEST_PATTERN="([0-9]+\.[0-9]+\.[0-9]+\.[0-9])"

# find the CASCDEPS_TOOL location (found as cascdeps in the docker image)
export CASCDEPS_TOOL
if command -v cascdeps &> /dev/null; then
    CASCDEPS_TOOL=$(command -v cascdeps)
elif [ -z "${CASCDEPS_TOOL:-}" ]; then
    # find the cascdeps tool in the current directory or the parent directory
    for f in "${SCRIPT_DIR}/cascdeps" "${SCRIPT_DIR}/run.sh" "${PARENT_DIR}/cascdeps" "${PARENT_DIR}/run.sh"; do
        if [ -f "$f" ]; then
            CASCDEPS_TOOL="$f"
            break
        fi
    done
fi

determineCIVersion() {
    CI_VERSION="${CI_VERSION:-}"
    # determine CI_VERSION
    if [ -z "${CI_VERSION}" ]; then
        local versionDir='' versionDirName=''
        versionDir=$(dirname "$RAW_DIR")
        versionDirName=$(basename "$versionDir")
        # test parent dir
        debug "INFO: Testing CI_VERSION according to parent of RAW_DIR..."
        if [[ "$versionDirName" =~ $CI_DETECTION_PATTERN ]]; then
            CI_VERSION="${BASH_REMATCH[1]}"
            echo "INFO: Setting CI_VERSION according to parent of RAW_DIR (-> $CI_VERSION)."
        fi
        if [ -z "$CI_VERSION" ]; then
            debug "INFO: Testing CI_VERSION according to GIT_BRANCH or CHANGE_TARGET env var..."
            if [[ "${GIT_BRANCH:-}" =~ $CI_DETECTION_PATTERN ]]; then
                CI_VERSION="${BASH_REMATCH[1]}"
                echo "INFO: Setting CI_VERSION according to GIT_BRANCH env var (-> $CI_VERSION)."
            elif [[ "${CHANGE_TARGET:-}" =~ $CI_DETECTION_PATTERN ]]; then
                CI_VERSION="${BASH_REMATCH[1]}"
                echo "INFO: Setting CI_VERSION according to CHANGE_TARGET env var (-> $CI_VERSION)."
            fi
        fi
        if [ -z "$CI_VERSION" ]; then
            debug "INFO: Testing CI_VERSION according to git branch from command..."
            if command -v git &> /dev/null; then
                local gitBranch=''
                gitBranch=$(git rev-parse --abbrev-ref HEAD)
                if [[ "$gitBranch" =~ $CI_DETECTION_PATTERN ]]; then
                    CI_VERSION="${BASH_REMATCH[1]}"
                    echo "INFO: Setting CI_VERSION according to git branch from command (-> $CI_VERSION)."
                fi
            fi
        fi
        if [ -z "$CI_VERSION" ]; then
            debug "INFO: Testing CI_VERSION according to ${TEST_RESOURCES_CI_VERSIONS}..."
            if [ -f "${TEST_RESOURCES_CI_VERSIONS}" ]; then
                # Used in PR use cases where the CI_VERSION cannot be determined otherwise
                if [[ $(wc -l < "${TEST_RESOURCES_CI_VERSIONS}") -eq 1 ]]; then
                    local knownVersion=''
                    knownVersion=$(cat "${TEST_RESOURCES_CI_VERSIONS}")
                    if [[ "$knownVersion" =~ $CI_TEST_PATTERN ]]; then
                        CI_VERSION="${BASH_REMATCH[1]}"
                        echo "INFO: Setting CI_VERSION according to ${TEST_RESOURCES_CI_VERSIONS} (-> $CI_VERSION)."
                    fi
                else
                    echo "WARN: Multiple versions found in ${TEST_RESOURCES_CI_VERSIONS}. Not setting anything."
                fi
            fi
        fi
        if [ -z "$CI_VERSION" ]; then
            # we've got this without being able to find the CI_VERSION so...
            die "Could not determine a CI_VERSION."
        fi
    else
        echo "INFO: Setting CI_VERSION according to CI_VERSION env var (-> $CI_VERSION)."
    fi
    [[ "${CI_VERSION}" =~ $CI_TEST_PATTERN ]] || die "CI_VERSION '${CI_VERSION}' is not a valid version."
    # set the version with dashes for later use
    CI_VERSION_DASHES="${CI_VERSION//\./-}"
}

checkForMacGnuBinaries() {
    # GNU Date accepts '--version', BSD date does not
    DATECMD='date'
    if command -v gdate &> /dev/null; then
        DATECMD='gdate'
    fi
    $DATECMD -u +"%H:%M:%S " &> /dev/null || die "Looks like you are on MacOS. Please install GNU date (e.g. with brew install core-utils)"
    # GNU sed accepts '--version', BSD sed does not
    SEDCMD='sed'
    if command -v gsed &> /dev/null; then
        SEDCMD='gsed'
    fi
    $SEDCMD --version &> /dev/null || die "Looks like you are on MacOS. Please install GNU sed (e.g. with brew install gnu-sed)"
}

prereqs() {
    [[ "${BASH_VERSION:0:1}" -lt 4 ]] && die "Bash 3.x is not supported. Please use Bash 4.x or higher."
    checkForMacGnuBinaries
}

processVars() {
    setDirs "${1:-}"
    prereqs

    debug "Setting some vars..."
    [ "$DEBUG" -eq 1 ] && COPY_CMD=(cp -v) || COPY_CMD=(cp)
    [ -f "${CASCDEPS_TOOL}" ] || die "CASCDEPS_TOOL '${CASCDEPS_TOOL}' is not a file"
    [ -x "${CASCDEPS_TOOL}" ] || die "CASCDEPS_TOOL '${CASCDEPS_TOOL}' is not executable"
    [ -d "${RAW_DIR}" ] || die "RAW_DIR '${RAW_DIR}' is not a directory"
    [ -d "${EFFECTIVE_DIR}" ] || die "EFFECTIVE_DIR '${EFFECTIVE_DIR}'  is not a directory"
    determineCIVersion
    debug "INFO: Running with:
    CASCGEN_TOOL=$CASCGEN_TOOL
    CASCDEPS_TOOL=$CASCDEPS_TOOL
    TARGET_BASE_DIR=$TARGET_BASE_DIR
    CACHE_BASE_DIR=$CACHE_BASE_DIR
    RAW_DIR=$RAW_DIR
    EFFECTIVE_DIR=$EFFECTIVE_DIR
    BUNDLE_FILTER=$BUNDLE_FILTER
    CI_VERSION=$CI_VERSION
    GIT_COMMIT=${GIT_COMMIT:-}
    GIT_PREVIOUS_SUCCESSFUL_COMMIT=${GIT_PREVIOUS_SUCCESSFUL_COMMIT:-}
    GIT_BRANCH=${GIT_BRANCH:-}
    CHANGE_TARGET=${CHANGE_TARGET:-}"
}

listFileXInY() {
    find -L "$1" -type f -name "$2" -print0 | sort -z
}

listBundleYamlsIn() {
    # allow using something like raw.bundle.yaml instead of bundle.yaml for the raw bundles
    # - this is because the current OC does not allow setting a path to the bundles location entry :-(
    # - being able to set a path would make this whole raw.bundle.yaml thing reduntant, but heyho...
    listFileXInY "$1" "*bundle.yaml"
}

listPluginYamlsIn() {
    listFileXInY "$1" "*plugins*.yaml"
}

listPluginCatalogsIn() {
    listFileXInY "$1" "plugin-catalog*.yaml"
}

findBundleChain() {
    while IFS= read -r -d '' bundleYaml; do
        local currentParent=''
        currentParent=$(grep -oE "^parent: .*$" "$bundleYaml" | tr -d '"' | tr -d "'" | cut -d' ' -f 2 || true)
        if [ -n "$currentParent" ]; then
            BUNDLE_PARENTS="${currentParent} ${BUNDLE_PARENTS}"
            findBundleChain "${RAW_DIR}/${currentParent}"
        fi
    done < <(listBundleYamlsIn "$1")
}

generate() {
    local bundleFilter="${BUNDLE_FILTER:-}"
    toolCheck yq md5sum

    # one off rename of bundle.yaml to raw.bundle.yaml (otherwise the OC complains about the duplicate bundles :-()
    if [ -f "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}/bundle.yaml" ]; then
        echo "Renaming bundle.yaml to raw.bundle.yaml (this is a one-off)"
        mv "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}/bundle.yaml" "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}/raw.bundle.yaml"
    fi

    while IFS= read -r -d '' bundleYaml; do
        bundleDir=$(dirname "$bundleYaml")
        bundleDirName=$(basename "$bundleDir")
        targetDirName="${bundleDirName}"
        targetDir="$EFFECTIVE_DIR/${targetDirName}"
        targetBundleYaml="${targetDir}/bundle.yaml"
        # save the checksum of the current target bundle yaml
        local checkSumFullActual=''
        local checkSumPluginsActual=''
        if [ -f "${targetBundleYaml}" ]; then
            # check for checksum in bundle header
            checkSumFullActual=$(yq '. | head_comment' "$targetBundleYaml" | xargs | cut -d'=' -f 2)
            checkSumPluginsActual="${checkSumFullActual%-*}"
        fi
        BUNDLE_PARENTS="$bundleDirName"
        findBundleChain "${bundleDir}"
        if [ -n "${bundleFilter}" ]; then
            local skipBundle=1
            for b in ${BUNDLE_PARENTS}; do
                if [[ "$b" == "$bundleFilter" ]]; then skipBundle=0; fi
            done
            if [ "$skipBundle" -eq 1 ]; then continue; fi
        fi
        i=0
        debug "INFO: Creating bundle '$targetDirName' using parents '$BUNDLE_PARENTS'"
        for parent in ${BUNDLE_PARENTS:-}; do
            parentDir="${RAW_DIR}/${parent}"
            parentBundleYaml=$(find "${parentDir}/" -name "*bundle.yaml")
            mkdir -p "${targetDir}"
            "${COPY_CMD[@]}" "${parentBundleYaml}" "${targetBundleYaml}"
            for bundleSection in $BUNDLE_SECTIONS; do
                # special case for plugin catalog since you can only have one.
                if [[ "catalog" == "${bundleSection}" ]]; then
                    debug "  Ignoring plugin catalog files..."
                    continue
                fi
                # recreate effective bundle section directory on first loop
                [ "$i" -ne 0 ] || { rm -rf "${targetDir}/${bundleSection}."*; rm -rf "${targetDir}/${bundleSection:?}"; }
                bs=$bundleSection yq -i '.[env(bs)] = []' "${targetBundleYaml}"
                for cascBundleEntry in $(bundleSection=$bundleSection yq '.[env(bundleSection)][]' "${parentBundleYaml}"); do
                    if [ -f "${parentDir}/${cascBundleEntry}" ]; then
                        srcFile="${parentDir}/${cascBundleEntry}"
                        debug "  Found file: ${srcFile}"
                        targetFileName="${bundleSection}.${i}.${parent}.${cascBundleEntry}"
                        if [ -s "${srcFile}" ]; then
                            "${COPY_CMD[@]}" "${srcFile}" "${targetDir}/${targetFileName}"
                            bs=$bundleSection f=$targetFileName yq -i '.[env(bs)] += env(f)' "${targetBundleYaml}"
                        else
                            debug "Empty file - ignoring...${srcFile}"
                        fi
                    elif [ -d "${parentDir}/${cascBundleEntry}" ]; then
                        debug "  Found directory: ${parentDir}/${cascBundleEntry}"
                        local fileName=''
                        while IFS= read -r -d '' fullFileName; do
                            fileName=$(basename "$fullFileName")
                            srcFile="${parentDir}/${cascBundleEntry}/$fileName"
                            targetFileName=$(echo -n "${bundleSection}.${i}.${parent}.${cascBundleEntry}/$fileName" | tr '/' '.')
                            debug "  -> $targetFileName"
                            if [ -s "${srcFile}" ]; then
                                "${COPY_CMD[@]}" "${srcFile}" "${targetDir}/${targetFileName}"
                                bs=$bundleSection f=$targetFileName yq -i '.[env(bs)] += env(f)' "${targetBundleYaml}"
                            else
                                debug "Empty file - ignoring... ${srcFile}"
                            fi
                        done < <(listFileXInY "${parentDir}/${cascBundleEntry}" "*.yaml")
                    else
                        debug "Entry not found: ${cascBundleEntry}"
                    fi
                done
            done
            i=$(( i + 1 ))
        done
        # reset sections
        for bundleSection in $BUNDLE_SECTIONS; do
            # special case for plugin catalog since you can only have one.
            if [[ "catalog" == "${bundleSection}" ]]; then
                debug "Ignoring plugin catalog files. Handling afterwards..."
                continue
            fi
            debug "Resetting section ${bundleSection}..."
            if [ "$(ls -A "${targetDir}/${bundleSection}."* 2> /dev/null)" ]; then
                bs=$bundleSection yq -i '.[env(bs)] = []' "${targetBundleYaml}"
                # flatten file stucture
                local flatFile=''
                while IFS= read -r f; do
                    flatFile=$(basename "${f}")
                    bs=$bundleSection f=$flatFile yq -i '.[env(bs)] += env(f)' "${targetBundleYaml}"
                done < <(ls -A "${targetDir}/${bundleSection}."*)
            else
                bs=$bundleSection yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
            fi
        done
        # manage plugin catalog
        replacePluginCatalog "$targetDir" "$CI_VERSION" "$targetBundleYaml" "$checkSumPluginsActual"
        # add description to the effective bundles
        bp=" (version: $CI_VERSION, inheritance: $BUNDLE_PARENTS)" yq -i '.description += strenv(bp)' "${targetBundleYaml}"
        # remove the parent and availabilityPattern from the effective bundles
        yq -i 'del(.parent)|del(.availabilityPattern)' "${targetBundleYaml}"
        # reinstate the checksum of bundle files to provide unique version which does change with git
        checkSum=$(cd "${targetDir}" && find . -type f -exec md5sum {} + |  sort | md5sum | cut -d' ' -f 1)
        c=$checkSum yq -i '.version = env(c)' "${targetBundleYaml}"
        echo ""
        if [ -n "$TREE_CMD" ]; then
            echo "INFO: Resulting files created using tree..."
            tree --noreport "$targetDir"
        else
            echo "INFO: Resulting files created using poor man's tree..."
            echo "$(cd "${targetDir}"; find . | $SEDCMD -e "s/[^-][^\/]*\// |/g" -e "s/|\([^ ]\)/|-\1/")"
        fi
        echo ""
        echo "INFO: Resulting bundle.yaml"
        yq . "${targetBundleYaml}"
    done < <(listBundleYamlsIn "$RAW_DIR")
    cleanupUnusedBundles
}

replacePluginCatalog() {
    local bundleDir=$1
    local ciVersion=$2
    local targetBundleYaml=$3
    local checkSumPluginsActual=$4
    [ -d "${bundleDir:-}" ] || die "Please set bundleDir (i.e. raw-bundles/<BUNDLE_NAME>)"
    local pluginCatalogYamlFile="catalog.plugin-catalog.yaml"
    local finalPluginCatalogYaml="${bundleDir}/${pluginCatalogYamlFile}"
    local CASCDEPS_TOOL_CMD=("$CASCDEPS_TOOL" -N -M -v "$ciVersion")
    local PLUGINS_LIST_CMD=("yq" "--no-doc" ".plugins")
    while IFS= read -r -d '' f; do
        PLUGINS_LIST_CMD+=("$f")
        CASCDEPS_TOOL_CMD+=(-f "$f")
    done < <(listPluginYamlsIn "$bundleDir")

    # do we even have plugins files?
    if [ "yq --no-doc .plugins" == "${PLUGINS_LIST_CMD[*]}" ]; then
        debug "No plugins yaml files found."
        debug "Removing any previous catalog files..."
        rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
        bs="catalog" yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
        return 0
    fi

    if [ -n "${PLUGIN_CATALOG_OFFLINE_URL_BASE:-}" ]; then
        echo "INFO: Detected the PLUGIN_CATALOG_OFFLINE_URL_BASE variable. Using the offline catalog."
        CASCDEPS_TOOL_CMD+=(-C "$finalPluginCatalogYaml")
    else
        CASCDEPS_TOOL_CMD+=(-c "$finalPluginCatalogYaml")
    fi
    # this is a tricky one, but we want
    # - unique list of plugins from all files
    # - comments should be preserved so that last comment stays (important for custom tags)
    # - see the bottom of this script for an example
    local checkSumEffectivePlugins=''
    local checkSumPluginsExpected=''
    local effectivePluginsList=''
    effectivePluginsList=$("${PLUGINS_LIST_CMD[@]}" | yq '. |= (reverse | unique_by(.id) | sort_by(.id))' - --header-preprocess=false)
    checkSumEffectivePlugins=$(echo "$effectivePluginsList" | md5sum | cut -d' ' -f 1)
    checkSumPluginsExpected="${CI_VERSION_DASHES}-${checkSumEffectivePlugins}"
    # check for AUTO_UPDATE_CATALOG
    local localDryRun="${DRY_RUN}"
    debug ""
    debug "AUTO_UPDATE_CATALOG - Plugin catalog version has the format <CI_VERSION_DASHES>-<EFFECTIVE_PLUGINS_MD5SUM>-<CATALOG_INCLUDE_PLUGINS_MD5SUM>"
    echo ""
    echo "INFO: AUTO_UPDATE_CATALOG - Checking effective plugins checksum 'actual: $checkSumPluginsActual' vs 'expected: $checkSumPluginsExpected'"
    if [ "$checkSumPluginsActual" != "$checkSumPluginsExpected" ]; then
        if [ -z "$checkSumPluginsActual" ]; then
            echo "INFO: AUTO_UPDATE_CATALOG - no current plugin catalog found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)..."
            localDryRun=0
        elif [ "$AUTO_UPDATE_CATALOG" -eq 0 ] && [ "$DRY_RUN" -eq 1 ]; then
            echo "WARNING: AUTO_UPDATE_CATALOG - differences in plugins checksum (found in head comment of plugin catalog) found but neither AUTO_UPDATE_CATALOG=1 nor is DRY_RUN=0"
        else
            echo "INFO: AUTO_UPDATE_CATALOG - differences in plugins found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)..."
            localDryRun=0
        fi
    fi
    echo ""
    echo "Running... ${CASCDEPS_TOOL_CMD[*]}"
    if [ "$localDryRun" -eq 0 ]; then
        debug "Removing any previous catalog files..."
        rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
        local bundleDirName=''
        bundleDirName=$(basename "$bundleDir")
        export PLUGIN_CATALOG_NAME="${bundleDirName}-plugin-catalog"
        export PLUGIN_CATALOG_DISPLAY_NAME=''
        # Replace non-alphanumeric characters with spaces
        PLUGIN_CATALOG_DISPLAY_NAME=$(echo "$PLUGIN_CATALOG_NAME" | tr -c '[:alnum:]' ' ')
        # Capitalize each word
        local str=''
        for w in $PLUGIN_CATALOG_DISPLAY_NAME; do
            str+=" ${w^}"
        done
        PLUGIN_CATALOG_DISPLAY_NAME="${str:1}" # Remove leading space
        export PLUGIN_CATALOG_DISPLAY_NAME_OFFLINE="${PLUGIN_CATALOG_DISPLAY_NAME} (offline)"
        "${CASCDEPS_TOOL_CMD[@]}"
        unset PLUGIN_CATALOG_NAME PLUGIN_CATALOG_DISPLAY_NAME PLUGIN_CATALOG_DISPLAY_NAME_OFFLINE
    else
        echo "INFO: Set DRY_RUN=0 to execute, or AUTO_UPDATE_CATALOG=1 to execute automatically."
    fi
    # set the plugin catalog header and section if needed
    local pluginsInCatalog='0'
    # default to empty string. it's changed if plugins are included in catalog
    local checkSumIncludePlugins="${MD5SUM_EMPTY_STR}"
    local checkSumFullExpected="${checkSumPluginsExpected}-${checkSumIncludePlugins}"
    if [ -f "$finalPluginCatalogYaml" ]; then
        pluginsInCatalog=$(yq '.configurations[0].includePlugins|length' "${finalPluginCatalogYaml}")
        if [ "$pluginsInCatalog" -gt 0 ]; then
            # set plugin catalog
            bs=catalog pc="${pluginCatalogYamlFile}" yq -i '.[env(bs)] = [env(pc)]' "${targetBundleYaml}"
            # update the checkSumFullExpected header
            checkSumIncludePlugins=$(yq '.configurations[0].includePlugins' "$finalPluginCatalogYaml" | md5sum | cut -d' ' -f 1)
            checkSumFullExpected="${checkSumPluginsExpected}-${checkSumIncludePlugins}"
        else
            echo "INFO: No plugins in catalog. No need to set it in bundle..."
            rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
            bs="catalog" yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
        fi
    else
        echo "INFO: No plugin catalog file. No need to set it in bundle..."
        rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
        bs="catalog" yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
    fi
    # update the unique checksum header
    csum="${CHECKSUM_PLUGIN_FILES_KEY}=${checkSumFullExpected}" yq -i '. head_comment=env(csum)' "${targetBundleYaml}"
    sanityCheckMinimumPlugins "$effectivePluginsList"  "$targetBundleYaml"
    createValidation "$checkSumFullExpected" "$effectivePluginsList" "$finalPluginCatalogYaml"
}

sanityCheckMinimumPlugins() {
    local effectivePluginsList=$1
    local targetBundleYaml=$2
    # sanity check - need...
    # - "cloudbees-casc-client" at a bare minimum
    # - "cloudbees-casc-items-controller" if the items
    debug "Sanity checking minimum plugins..."
    local minimumPlugins="${MINIMUM_PLUGINS_CASC_CONTROLLER}"
    if [ "oc" == "$CI_TYPE" ]; then
        minimumPlugins="${MINIMUM_PLUGINS_CASC_OC}"
    fi
    local minimumPluginsErr=''
    minimumPluginsErr="ERROR: Bundle '$(basename "${bundleDir}")' - ${MINIMUM_PLUGINS_CASC_ERR}${minimumPlugins}"
    testForEffectivePlugin "cloudbees-casc-client" "${effectivePluginsList}" || die "$minimumPluginsErr"
    if yq -e '.|has("items")' "${targetBundleYaml}" &>/dev/null; then
        for minPlugin in $minimumPlugins; do
            testForEffectivePlugin "$minPlugin" "${effectivePluginsList}" || die "$minimumPluginsErr"
        done
    fi
}

## create plugin commands
plugins() {
    local bundleFilter="${BUNDLE_FILTER:-}"
    toolCheck yq md5sum
    while IFS= read -r -d '' bundleYaml; do
        bundleDir=$(dirname "$bundleYaml")
        bundleDirName=$(basename "$bundleDir")
        BUNDLE_PARENTS="$bundleDirName"
        findBundleChain "${bundleDir}"
        if [ -n "${bundleFilter}" ]; then
            local skipBundle=1
            for b in ${BUNDLE_PARENTS}; do
                if [[ "$b" == "$bundleFilter" ]]; then skipBundle=0; fi
            done
            if [ "$skipBundle" -eq 1 ]; then continue; fi
        fi
        while IFS= read -r -d '' f; do
            local CASCDEPS_TOOL_CMD=("$CASCDEPS_TOOL" -v "$CI_VERSION" -sAf "$f" -G "$f")
            echo "Running... ${CASCDEPS_TOOL_CMD[*]}"
            if [ "$DRY_RUN" -eq 0 ] || [ "$AUTO_UPDATE_CATALOG" -eq 1 ]; then
                "${CASCDEPS_TOOL_CMD[@]}"
                # if we run the 'force' command, we still only want to download the UC once per call
                REFRESH_UC=0
            else
                echo "Set DRY_RUN=0 or AUTO_UPDATE_CATALOG=1 to execute."
            fi
        done < <(listPluginYamlsIn "$bundleDir")
    done < <(listBundleYamlsIn "$RAW_DIR")
}

cleanupUnusedBundles() {
    echo "INFO: Running clean up effective bundles..."
    # Effective
    local bundles=''
    bundles=$(find "${EFFECTIVE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort)
    for bundleName in $bundles; do
        debug "CLEANUP - Checking effective bundle '$bundleName'"
        if [ ! -d "${RAW_DIR}/$bundleName" ]; then
            debug "CLEANUP - Removing unused effective bundle '${bundleName}'"
            rm -rf "${EFFECTIVE_DIR}/${bundleName:?}"
        fi
    done
    echo "INFO: Running clean up validation bundles if present..."
    if [ -d "$VALIDATIONS_DIR" ]; then
        if [ -n "${BUNDLE_SUB_DIR:-}" ]; then
            # remove legacy validation bundles
            rm -rf "${VALIDATIONS_DIR:?}/${VALIDATIONS_BUNDLE_PREFIX_ORIG:?}${CI_VERSION_DASHES:?}"*
        fi
        # Validations
        for d in "${VALIDATIONS_DIR}/${VALIDATIONS_BUNDLE_PREFIX}"*; do
            [[ -d "$d" ]] || break
            local bundleName=''
            bundleName=$(basename "$d")
            [[ "$bundleName" != "${VALIDATIONS_TEMPLATE}" ]] || continue # # skip the VALIDATIONS_TEMPLATE
            local validationCheckSum="${bundleName//"${VALIDATIONS_BUNDLE_PREFIX}"/}"
            debug "CLEANUP - Looking for validation checksum '$validationCheckSum'"
            if ! grep -rq "$validationCheckSum" "${EFFECTIVE_DIR}"; then
                debug "CLEANUP - Removing unused validation bundle '${bundleName}'"
                rm -rf "${VALIDATIONS_DIR}/${bundleName:?}"
            else
                # Exists so let's add all associated effective bundles as a head comment for
                # easier processing afterwards
                local headerStr=''
                while IFS= read -r f; do
                    [[ -e "$f" ]] || break
                    local associatedBundleName=''
                    associatedBundleName=$(basename "$(dirname "$f")")
                    debug "Adding associated bundle '${EFFECTIVE_DIR_RELATIVE}/$associatedBundleName'"
                    if [ -z "$headerStr" ]; then
                        headerStr="${EFFECTIVE_DIR_RELATIVE}/$associatedBundleName"
                    else
                        headerStr=$(printf '%s\n%s' "$headerStr" "${EFFECTIVE_DIR_RELATIVE}/${associatedBundleName}")
                    fi
                done < <(grep -rl "${CHECKSUM_PLUGIN_FILES_KEY}=${validationCheckSum}" "${EFFECTIVE_DIR}")
                headerStr="$(sort <<< "${headerStr}")" yq -i '. head_comment=strenv(headerStr)' "${d}/plugins.yaml"
            fi
        done
    fi
    debug "INFO: Recreating the kustomisation.yaml if found at root of effective-bundles directory..."
    if [ -f "${KUSTOMIZATION_YAML}" ]; then
        toolCheck kustomize
        echo -n > "${KUSTOMIZATION_YAML}"
        (cd "$EFFECTIVE_DIR" && {
            local configmapName=''
            local bundles=''
            bundles=$(find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort)
            for d in $bundles; do
                configmapName="${CI_VERSION_DASHES}-${d}"
                [ "true" == "${CONFIGMAP_INCLUDE_VERSION_IN_NAME}" ] || configmapName="${d}"
                kustomize edit add configmap "${configmapName}" --behavior=create --disableNameSuffixHash --from-file="$d/*";
            done
        };)
        echo "INFO: Recreated the kustomisation.yaml"
    fi
}

createValidation() {
    local checkSumFullExpected=$1
    local effectivePluginsList=$2
    local finalPluginCatalogYaml=$3
    # validation bundles - we are assuming there is only 1 x plugins.yaml, 1 x plugin-catalog.yaml
    local validationBundle="${VALIDATIONS_BUNDLE_PREFIX}${checkSumFullExpected}"
    local validationDir="${VALIDATIONS_DIR}/${validationBundle}"
    if [ -d "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}" ]; then
        debug "VALIDATION BUNDLES - Checking bundle '$validationBundle'"
        if [ ! -d "${validationDir}" ] || [ "$DRY_RUN" -eq 0 ]; then
            debug "VALIDATION BUNDLES - Creating bundle '$validationBundle'"
            rm -rf "${validationDir}"
            cp -r "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}" "${validationDir}"
            mv "${validationDir}/"*bundle.yaml "${validationDir}/bundle.yaml"
            local valPluginsYaml="${validationDir}/plugins.yaml"
            touch "${valPluginsYaml}"
            pl="$effectivePluginsList" yq -i '.plugins = env(pl)' "${valPluginsYaml}"
            if [ -f "${finalPluginCatalogYaml}" ]; then
                cp -r "${finalPluginCatalogYaml}" "${validationDir}/plugin-catalog.yaml"
            else
                rm -f "${validationDir}/plugin-catalog.yaml"
                bs="catalog" yq -i 'del(.[env(bs)])' "${validationDir}/bundle.yaml"
            fi
        else
            debug "VALIDATION BUNDLES - Existing bundle '$validationBundle' found."
        fi
    else
        debug "VALIDATION BUNDLES - No validation template found so not creating for '$validationBundle'."
    fi
}

testForEffectivePlugin() {
    echo "$2" | p="$1" yq -e '.[]|select(.id == strenv(p))' - &>/dev/null
}

# TEST UTILS - FOR USE IN CI PIPELINES
# TEST UTILS - FOR USE IN CI PIPELINES
# TEST UTILS - FOR USE IN CI PIPELINES

# Options which can be set as environment variables or place in the .env file
# The summary title can be set to be an html header
SUMMARY_HTML="${SUMMARY_HTML:-"false"}"
# Whether to actually apply the config maps or just do a dry run
CONFIGMAP_APPLY_DRY_RUN="${CONFIGMAP_APPLY_DRY_RUN:-"false"}"
# Whether to actually delete unknown config maps or just add a warning to the log
DELETE_UNKNOWN_BUNDLES="${DELETE_UNKNOWN_BUNDLES:-"true"}"
# Give it 4 mins to connect to the jenkins server
CONNECT_MAX_WAIT="${CONNECT_MAX_WAIT:-240}"
# Used to allow for additional java opts to be added to the jenkins startup. e.g. -Djenkins.security.SystemReadPermission=true
TEST_UTILS_STARTUP_JAVA_OPTS="${TEST_UTILS_STARTUP_JAVA_OPTS:-}"

# Set dry run for kubectl
KUBERNETES_DRY_RUN=()
if [ "true" == "${CONFIGMAP_APPLY_DRY_RUN:-}" ]; then
    KUBERNETES_DRY_RUN=('--dry-run=client')
fi

# Test jenkins server variables
JENKINS_LOG_TMP_FILE="/tmp/jenkins-process.log"
TOKEN_SCRIPT="\
import hudson.model.User
import jenkins.security.ApiTokenProperty
def jenkinsTokenName = 'token-for-test'
def user = User.get('admin', false)
def apiTokenProperty = user.getProperty(ApiTokenProperty.class)
apiTokenProperty.tokenStore.getTokenListSortedByName().findAll {it.name==jenkinsTokenName}.each {
    apiTokenProperty.tokenStore.revokeToken(it.getUuid())
}
def result = apiTokenProperty.tokenStore.generateNewToken(jenkinsTokenName).plainValue
user.save()
new File('/var/jenkins_home/secrets/initialAdminToken').text = result
"

## Takes 1 arg (validation) - starts a server with that particular validation bundle
startServer()
{
    local validationBundle=$1
    # stopping any previously started servers
    stopServer
    # Account for the case where the license is base64 encoded
    if [ -n "${CASC_VALIDATION_LICENSE_KEY_B64:-}" ]; then
        echo "Decoding the license key and cert..."
        export CASC_VALIDATION_LICENSE_KEY=''
        export CASC_VALIDATION_LICENSE_CERT=''
        CASC_VALIDATION_LICENSE_KEY=$(echo "${CASC_VALIDATION_LICENSE_KEY_B64}" | base64 -d)
        CASC_VALIDATION_LICENSE_CERT=$(echo "${CASC_VALIDATION_LICENSE_CERT_B64}" | base64 -d)
    fi
    # fail if either CASC_VALIDATION_LICENSE_KEY or CASC_VALIDATION_LICENSE_CERT are not set
    [ -n "${CASC_VALIDATION_LICENSE_KEY:-}" ] || die "CASC_VALIDATION_LICENSE_KEY is not set."
    [ -n "${CASC_VALIDATION_LICENSE_CERT:-}" ] || die "CASC_VALIDATION_LICENSE_CERT is not set."
    # add token script to init.groovy.d
    echo "${TOKEN_SCRIPT}" > /usr/share/jenkins/ref/init.groovy.d/init_02_admin_token.groovy
    export JAVA_OPTS="${TEST_UTILS_STARTUP_JAVA_OPTS} -Dcore.casc.config.bundle=${VALIDATIONS_DIR}/${validationBundle}"
    echo "Cleaning plugins directory..."
    rm -rf /var/jenkins_home/plugins /var/jenkins_home/envelope-extension-plugins
    echo "Starting server with bundle '$validationBundle'"
    if [ -f /usr/local/bin/launch.sh ]; then
        nohup /usr/local/bin/launch.sh &> "${JENKINS_LOG_TMP_FILE}" &
    elif [ -f /usr/local/bin/jenkins.sh ]; then
        nohup /usr/local/bin/jenkins.sh &> "${JENKINS_LOG_TMP_FILE}" &
    else
        die "Neither launch.sh nor jenkins.sh exist."
    fi
    SERVER_PID=$!
    echo "Started server with pid $SERVER_PID"
    echo "$SERVER_PID" > "/tmp/jenkins-pid.${SERVER_PID}"
    local serverStarted=''
    ENDTIME=$(( $(date +%s) + CONNECT_MAX_WAIT )) # Calculate end time.
    while [ "$(date +%s)" -lt $ENDTIME ]; do
        echo "$(date): $(date +%s) -lt $ENDTIME"
        if [[ "200" == $(curl -o /dev/null -sw "%{http_code}" "http://localhost:8080/whoAmI/api/json") ]]; then
            serverStarted='y'
            sleep 5 # just a little respite
            echo "Server started" && break
        else
            sleep 5
            echo "Waiting for server to start"
        fi
    done
    if [ -z "$serverStarted" ]; then
        echo "$(date): $(date +%s) -lt $ENDTIME"
        echo "ERROR: Server not started in time. Printing the jenkins log...."
        cat "${JENKINS_LOG_TMP_FILE}"
        stopServer
        exit 1
    fi
}

## Takes 1 arg (bundleZipLocation) - validates bundle and places result in the "${bundleZipLocation}.json"
runCurlValidation() {
    local zipLocation="$1"
    local jsonLocation="${zipLocation//zip/json}"
    local summaryLocation="${zipLocation//zip/txt}" # placeholder to put the summary afterwards
    local curlExitCode=''

    touch "$summaryLocation"
    echo "Running validation with '$zipLocation', writing to '$jsonLocation"
    set +e
    curl -sL -X POST -u "admin:$(cat /var/jenkins_home/secrets/initialAdminToken)" \
        "http://localhost:8080/casc-bundle-mgnt/casc-bundle-validate" \
        --header "Content-type: application/zip" \
        --data-binary "@${zipLocation}" \
        > "${jsonLocation}"
    set -e
    curlExitCode=$?
    # sanity check
    [ "${curlExitCode}" -eq 0 ] || die "Curl command failed with exit code ${curlExitCode}. See logs above."
    echo "Curl command successful. Printing resulting json '${jsonLocation}'."
    cat "${jsonLocation}"
    grep -qE "^[ ]*\{.*" "${jsonLocation}" || die "ERROR: File does not start with '{' '${jsonLocation}'"
}

## Takes 0 args - uses SERVER_PID file from startServer to stop the server
stopServer()
{
    echo "Stopping server/s if necessary..."
    for pidFile in /tmp/jenkins-pid*; do
        [ -f "$pidFile" ] || break # nothing found
        local pid=''
        pid=$(cat "${pidFile}")
        local logFile="${JENKINS_LOG_TMP_FILE}.${pid}"
        if [ -f "$JENKINS_LOG_TMP_FILE" ]; then
            echo "Copying jenkins log file with pid to '$logFile'"
            cp "$JENKINS_LOG_TMP_FILE" "$logFile"
        else
            echo "No log file found at '$JENKINS_LOG_TMP_FILE'"
        fi
        echo "Stopping server with pid '$pid'"
        kill "$pid" || true
    done
    rm -f "/tmp/jenkins-pid."*
}

## Finds changes between the branch and the target and runs validations for those bundles
runValidationsChangedOnly()
{
    local bundles=''
    getChangedSources
    if [ -f "${TEST_RESOURCES_CHANGED_BUNDLES}" ]; then
        bundles=$(cat "${TEST_RESOURCES_CHANGED_BUNDLES}")
    fi
    if [ -n "$bundles" ]; then
        echo "Changed effective bundles detected '$bundles'. Running validations..."
        runValidations "$bundles"
    else
        echo "No changed effective bundles detected. Not doing anything..."
    fi
}

## Takes 2 optional args (bundles and validationBundlePrefix) - if set run only those, otherwise run all validations (assumes the 'test-resources' directory has been created by the 'cascgen testResources')
runValidations()
{
    local bundles="${1:-}"
    local validationBundlePrefix="${2:-}"
    for validationBundleTestResource in "${TEST_RESOURCES_DIR}/${validationBundlePrefix}"*; do
        local validationBundle='' bundlesFound=''
        validationBundle=$(basename "$validationBundleTestResource")
        for b in $bundles; do
            local bZip="${validationBundleTestResource}/${b//*\/}.zip"
            [ ! -f "${bZip}" ] || bundlesFound="${bundlesFound} ${bZip}"
        done
        if [ -z "${bundles}" ] || [ -n "$bundlesFound" ]; then
            echo "Analysing validation bundle '${validationBundle}'..."
            startServer "$validationBundle"
            if [ -n "$bundlesFound" ]; then
                for bundleZipPath in $bundlesFound; do
                    runCurlValidation "${bundleZipPath}"
                done
            else
                for bundleZipPath in "${validationBundleTestResource}/"*.zip; do
                    runCurlValidation "${bundleZipPath}"
                done
            fi
            stopServer
            sleep 2
        else
            echo "Skipping validation bundle '${validationBundle}' since no matching bundles found."
        fi
    done
}

changedSourcesAction() {
    local fromSha=$1 toSha=$2 headSha=$3
    echo "INFO: CHANGED RESOURCES - Looking for changes between branch and base..."
    if ! git diff --exit-code --name-only "${fromSha}..${toSha}" > /dev/null; then
        echo "INFO: CHANGED RESOURCES - Found the changed resources below."
        git diff --name-only "${fromSha}..${toSha}" | tee "${TEST_RESOURCES_CHANGED_FILES}"
    fi
    if grep -qoE "${EFFECTIVE_DIR_RELATIVE}/.*/" "${TEST_RESOURCES_CHANGED_FILES}"; then
        grep -oE "${EFFECTIVE_DIR_RELATIVE}/.*/" "${TEST_RESOURCES_CHANGED_FILES}" | grep -o '^.*[^/]' | sort -u > "${TEST_RESOURCES_CHANGED_BUNDLES}"
    fi
    echo "INFO: CHANGED RESOURCES - Found the following changed bundles:"
    cat "${TEST_RESOURCES_CHANGED_BUNDLES}"
    echo "INFO: CHANGED RESOURCES - Checking to ensure branch is up to date..."
    if [[ "$headSha" != "$toSha" ]]; then
        die "PR requires merge commit. Please rebase or otherwise update your branch. Not accepting."
    fi
}

## Adds metadata above test-resources
## Assumes the 'test-resources' directory has been created by the 'cascgen createTestResources'
## Creates:
## - .changed-files: all the from the PR
## - .changed-effective-bundles: space separated list of changed bundles from the PR
getChangedSources() {
    local fromSha='' toSha='' headSha=''
    headSha=$(git rev-parse HEAD)
    # we are on a PR
    if [ -n "${CHANGE_TARGET:-}" ] && [ -n "${BRANCH_NAME:-}" ]; then
        fromSha=$(git rev-parse "origin/${CHANGE_TARGET}")
        toSha=$(git rev-parse "origin/${BRANCH_NAME}")
        changedSourcesAction "$fromSha" "$toSha" "$headSha"
    # we are on a release branch
    elif [ -n "${GIT_COMMIT:-}" ]; then
        if [ -n "${GIT_PREVIOUS_SUCCESSFUL_COMMIT:-}" ]; then
            changedSourcesAction "$GIT_PREVIOUS_SUCCESSFUL_COMMIT" "$GIT_COMMIT" "$headSha"
        else
            echo "Adding all bundles to the changed list since we are on a release branch for the first time."
            git ls-files | grep -oE "${EFFECTIVE_DIR_RELATIVE}/.*/" | grep -o '^.*[^/]' | sort -u > "${TEST_RESOURCES_CHANGED_BUNDLES}"
        fi
    else
        die "We need CHANGE_TARGET and BRANCH_NAME, or a GIT_COMMIT and optionally GIT_PREVIOUS_SUCCESSFUL_COMMIT."
    fi
}

## Prints a summary (assumes createTestResources has been run, and that some validation results in the form of <bundeName>.json next to <bundeName>.zip)
getTestResultReport() {
    local resultsOnlyWithBundleSubDirPrefix="${1:-}"
    local bundleDir=''
    local bundleName=''
    local bundleNamePrefix=''
    local bundleStatus=''
    local bundleJson=''
    local bundleTxt='' # marker file to say we expect a resulting json
    local problemFound=''
    local msg=''

    SUMMARY_TITLE="Analysis Summary:"
    [ -z "${BUNDLE_SUB_DIR:-}" ] || SUMMARY_TITLE="Analysis Summary for ${BUNDLE_SUB_DIR}:" # add sub dir to summary title

    if [ "true" == "${SUMMARY_HTML}" ]; then
        msg=$(printf "<b>%s</b>" "${SUMMARY_TITLE}")
        SUMMARY_EOL="<br>"
    else
        msg=$(printf "%s" "${SUMMARY_TITLE}")
        SUMMARY_EOL="\n"
    fi

    # remove any previous summary
    if [ "true" == "${resultsOnlyWithBundleSubDirPrefix}" ]; then
        msg=''
        if [ -n "${BUNDLE_SUB_DIR:-}" ]; then
            bundleNamePrefix="${BUNDLE_SUB_DIR:-}/"
        fi
    fi
    echo "$msg: starting analysis. If you see this, there was a problem during the analysis." > "${TEST_RESOURCES_DIR}/test-summary.txt"
    echo "INFO: Analysing bundles..."
    while IFS= read -r -d '' bundleDir; do
        bundleName=$(basename "$bundleDir")
        echo "INFO: Looking at bundle: ${bundleNamePrefix}${bundleName}"
        bundleTxt=$(find "${TEST_RESOURCES_DIR}" -type f -name "${bundleName}.txt")
        if [ -f "${bundleTxt}" ]; then
            # result json expected at least
            bundleJson=$(find "${TEST_RESOURCES_DIR}" -type f -name "${bundleName}.json")
            if [ -f "${bundleJson}" ]; then
                jq . "${bundleJson}"
                if [[ "true" == $(jq '.valid' "${bundleJson}") ]]; then
                    bundleStatus='OK  - VALID WITHOUT WARNINGS'
                    if jq -r '."validation-messages"[]' "${bundleJson}" | grep -qvE "^INFO"; then
                        bundleStatus='NOK - CONTAINS NON-INFO MESSAGES'
                    fi
                else
                    bundleStatus='NOK - INVALID'
                fi
            else
                bundleStatus='NOK - VALIDATION JSON EXPECTED BUT MISSING'
            fi
        else
            bundleStatus='N/A  - NOT TESTED'
        fi
        if [[ "${bundleStatus}" =~ NOK ]]; then
            problemFound='y'
        fi
        msg=$(printf "%s${SUMMARY_EOL}%s: %s" "$msg" "${bundleNamePrefix}${bundleName}" "$bundleStatus")
        echo "INFO: ${bundleNamePrefix}${bundleName}" "$bundleStatus"
    done < <(find "${EFFECTIVE_DIR}" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)
    debug ""
    debug "$msg"
    printf "%s${SUMMARY_EOL}${SUMMARY_EOL}" "${msg}" > "${TEST_RESOURCES_DIR}/test-summary.txt"
    [ -z "$problemFound" ] || die "Problems found. Dying, alas 'twas so nice..."
}

## Uses kubectl and kustomize to add two labels (CI_VERSION and CURRENT_GIT_SHA) and  apply the bundle config maps. Assumes env vars NAMESPACE and DELETE_UNKNOWN_BUNDLES (Removes any bundles which are no longer in the list for this release)
applyBundleConfigMaps()
{
    local headSha='' configMaps=''
    toolCheck kustomize
    headSha=$(git rev-parse HEAD)
    echo "Adding current git sha and CI_VERSION to the kustomize configuration..."
    [ -n "$headSha" ] || die "The current git sha is empty."
    [ -n "$CI_VERSION" ] || die "The env CI_VERSION is empty."
    cd "${EFFECTIVE_DIR}"
    local labelVersion='' labelSha='' labelSubDir=''
    labelVersion="bundle-mgr/version:$CI_VERSION"
    labelSha="bundle-mgr/sha:$headSha"
    labelSubDir="bundle-mgr/subdir:${BUNDLE_SUB_DIR:-"root"}"
    kustomize edit set label "$labelVersion" "$labelSha" "$labelSubDir"
    echo "Applying the kustomize configuration..."
    kubectl kustomize | kubectl -n "$NAMESPACE" apply -f - "${KUBERNETES_DRY_RUN[@]}"
    configMaps=$(kubectl -n "$NAMESPACE" get cm --selector "${labelVersion//\:/=},${labelSubDir//\:/=}" -o jsonpath="{.items[*].metadata.name}")
    for cm in $configMaps; do
        if grep -qE "name: ${cm}$" kustomization.yaml; then
            echo "ConfigMap '$cm' in current list."
        else
            echo "ConfigMap '$cm' NOT in current list."
            if [ "true" == "${DELETE_UNKNOWN_BUNDLES}" ]; then
                echo "ConfigMap '$cm' will be deleted."
                kubectl -n "$NAMESPACE" delete cm "$cm" "${KUBERNETES_DRY_RUN[@]}"
            else
                echo "ConfigMap '$cm' unknown but will be ignored (set DELETE_UNKNOWN_BUNDLES to true to delete)."
            fi
        fi
    done
    cd - &>/dev/null
}

createTestResources() {
    mkdir -p "${TEST_RESOURCES_DIR}"
    rm -r "${TEST_RESOURCES_DIR:?}/*" 2>/dev/null || true
    touch "${TEST_RESOURCES_CHANGED_FILES}" "${TEST_RESOURCES_CHANGED_BUNDLES}"
    for d in "${VALIDATIONS_DIR}/${VALIDATIONS_BUNDLE_PREFIX}"*; do
        for bundlePath in $(yq '. | head_comment' "${d}/plugins.yaml"); do
            local testValidationDir=''
            local bundle="${bundlePath//*\//}"
            testValidationDir="${TEST_RESOURCES_DIR}/$(basename "$d")"
            mkdir -p "$testValidationDir"
            cd "${EFFECTIVE_DIR}/${bundle}"
            rm -f "${testValidationDir}/${bundle}.zip"
            zip -r "${testValidationDir}/${bundle}.zip" .
            echo "Created '${testValidationDir}/${bundle}.zip'"
        done
    done

    # Add a unique list of detected CI_VERSION values
    # - need to use the directory because the plugin-catalog.yaml may not exist
    find "${VALIDATIONS_DIR}" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -name "${VALIDATIONS_BUNDLE_PREFIX}*" \
        | grep -oE '([0-9]+\-[0-9]+\-[0-9]+\-[0-9])' \
        | tr '-' '.' \
        | sort -u > "${TEST_RESOURCES_CI_VERSIONS}"
    # sanity check
    if [[ $(wc -l < "${TEST_RESOURCES_CI_VERSIONS}") -ne 1 ]]; then
        die "ERROR: Multiple or zero versions found in ${TEST_RESOURCES_CI_VERSIONS}. See below:
        $(cat "${TEST_RESOURCES_CI_VERSIONS}")"
    fi
}

runPrecommit() {
    PRE_COMMIT_LOG=/tmp/pre-commit.check-effective-bundles.log
    $0 generate "${@}" > "$PRE_COMMIT_LOG" 2>&1
    # if we:
    # - ran without recreating the plugin catalogs (DRY_RUN=1)
    # - find changes to effective plugins directories
    # then:
    # - we need to update the plugin catalogs before checking...
    ERROR_REPORT=''
    ERROR_MSGS=''
    CHANGED_PLUGINS_FILES=$(git ls-files --others --modified "${EFFECTIVE_DIR}"/**/plugins)
    CACHED_PLUGINS_FILES=$(git diff --name-only --cached "${EFFECTIVE_DIR}"/**/plugins)
    if [ "$DRY_RUN" -ne 0 ] && [ -n "$CHANGED_PLUGINS_FILES" ]; then
        echo ""
        errMsg="CHANGED_PLUGINS_FILES: Changes to plugins detected - please generate manually using DRY_RUN=0 to recreate the plugin catalog. !!!Pro Tip!!! use the filtering options to save time'. Execution log: $PRE_COMMIT_LOG"
        ERROR_MSGS="${ERROR_MSGS}\n${errMsg}"
        ERROR_REPORT=$(printf '%s\n\n%s\n\n%s\n\n' "${ERROR_REPORT}" "${errMsg}" "$CHANGED_PLUGINS_FILES")
    elif [ "$DRY_RUN" -ne 0 ] && [ -n "$CACHED_PLUGINS_FILES" ]; then
        echo ""
        echo "WARNING >>>> Cached plugin files found! Reminder to please ensure you recreated the plugin catalog using DRY_RUN=0"
        echo "WARNING >>>> Cached plugin files found! Ignore this if you have recreated the plugin catalog."
        echo ""
    fi
    # fail if non-cached diffs found in effective bundles
    CHANGED_EFFECTIVE_DIR=$(git --no-pager diff --stat "$EFFECTIVE_DIR")
    CHANGED_EFFECTIVE_DIR_FULL=$(git --no-pager diff "$EFFECTIVE_DIR")
    if [ -n "${CHANGED_EFFECTIVE_DIR}" ]; then
        errMsg="Effective bundles changed - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        ERROR_MSGS=$(printf '%s\n%s' "${ERROR_MSGS}" "${errMsg}")
        ERROR_REPORT=$(printf '%s\n\n%s\n\n%s\n\n' "${ERROR_REPORT}" "${errMsg}" "$CHANGED_EFFECTIVE_DIR_FULL")
    else
        echo "No changes in effective-bundles"
    fi
    UNTRACKED_EFFECTIVE_DIR=$(git ls-files "$EFFECTIVE_DIR" --exclude-standard --others)
    if [ -n "${UNTRACKED_EFFECTIVE_DIR}" ]; then
        errMsg="Effective bundles contains untracked files - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        ERROR_MSGS=$(printf '%s\n%s' "${ERROR_MSGS}" "${errMsg}")
        ERROR_REPORT=$(printf '%s\n\n%s\n\n%s\n\n' "${ERROR_REPORT}" "${errMsg}" "$UNTRACKED_EFFECTIVE_DIR")
    else
        echo "No unknown files in effective-bundles"
    fi
    # optional validation bundles
    if [ -d "$VALIDATIONS_DIR" ]; then
        CHANGED_VALIDATIONS_DIR=$(git --no-pager diff --stat "$VALIDATIONS_DIR")
        CHANGED_VALIDATIONS_DIR_FULL=$(git --no-pager diff "$VALIDATIONS_DIR")
        if [ -n "${CHANGED_VALIDATIONS_DIR}" ]; then
            errMsg="Validations bundles changed - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
            ERROR_MSGS=$(printf '%s\n%s' "${ERROR_MSGS}" "${errMsg}")
            ERROR_REPORT=$(printf '%s\n\n%s\n\n%s\n\n' "${ERROR_REPORT}" "${errMsg}" "$CHANGED_VALIDATIONS_DIR_FULL")
        else
            echo "No changes in validations"
        fi
        UNTRACKED_VALIDATIONS_DIR=$(git ls-files "$VALIDATIONS_DIR" --exclude-standard --others)
        if [ -n "${UNTRACKED_VALIDATIONS_DIR}" ]; then
            errMsg="Validations bundles contains untracked files - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
            ERROR_MSGS=$(printf '%s\n%s' "${ERROR_MSGS}" "${errMsg}")
            ERROR_REPORT=$(printf '%s\n\n%s\n\n%s\n\n' "${ERROR_REPORT}" "${errMsg}" "$UNTRACKED_VALIDATIONS_DIR")
        else
            echo "No unknown files in validations"
        fi
    fi
    if [ -n "${ERROR_MSGS}" ]; then
        if [ "$DEBUG" -eq 1 ]; then
            echo "SHOWING FULL $PRE_COMMIT_LOG"
            cat "$PRE_COMMIT_LOG"
            printf '\n\n%s\n\n%s\n\n' "SHOWING FULL ERROR_REPORT" "$ERROR_REPORT"
        fi;
        echo "ERROR: Differences found after pre-commit run - summary below. If DEBUG=1, the build log ($PRE_COMMIT_LOG) and full report can be seen above."
        printf '%s\n\n' "$ERROR_MSGS"
        die "Pre-commit run failed. See above."
    else
        echo "No error messages"
    fi
}

copyScriptsToAnotherDirectory() {
    local destDir="${1-}"
    if [ ! -d "$destDir" ]; then
        mkdir -p "${destDir}" || die "Destination directory '$destDir' does not exist and cound not create."
    fi
    for scriptName in "$CASCDEPS_TOOL" "$CASCGEN_TOOL"; do
        if [ -f "${scriptName}" ]; then
            echo "Copying script '${scriptName}' to '${destDir}'"
            cp "${scriptName}" "${destDir}"
        fi
    done
}

# This function is used to get the root directories of the raw-bundles
# passing a command will run that command on all the root directories
getBundleRoots() {
    local bundleRoots=''
    bundleRoots=$(git ls-files "**/*.bundle.yaml" | cut -d/ -f1 | grep -vE "(raw-bundles|validation-bundles)" | sort -u | xargs || true)
    bundleRoots="${bundleRoots:-.}"
    if [ -n "${*}" ]; then
        for root in $bundleRoots; do
            echo "INFO: < < < ROOT COMMAND > > > Running command '${*}' in root '$root'"
            BUNDLE_SUB_DIR="$root" $0 "${@}"
        done
    else
        echo "${bundleRoots}"
    fi
}

# To be run after createTestResources. Returns all known CI_VERSIONS
findAllKnownCiVersions() {
    local ciVersion=''
    ciVersion=$(find "${GIT_ROOT}" -name .ci-versions -exec cat {} \; | sort -u)
    if [ "$(wc -l <<< "$ciVersion")" -ne 1 ]; then
        find "${GIT_ROOT}" -name .ci-versions -exec tail -vn 10 {} \;
        die "Multiple or zero CI_VERSIONS in '.ci-versions' found. See above."
    else
        echo -n "$ciVersion"
    fi
}

# To be run after createTestResources. Returns all changed effective bundles, or tests if a given bundle sub dir has changed
getChangedEffectiveBundles() {
    local bundleSubDirToCheck="${1:-"${BUNDLE_SUB_DIR:-}"}"
    local changedEffectiveBundles=''
    changedEffectiveBundles=$(find "${GIT_ROOT}" -type f -name .changed-effective-bundles -exec cat {} \;)
    if [ -z "${bundleSubDirToCheck}" ]; then
        echo "${changedEffectiveBundles}"
    elif [ "." == "${bundleSubDirToCheck}" ]; then
        grep -E "^effective-bundles/" <<< "${changedEffectiveBundles}" || die "No changed effective bundles found in '${bundleSubDirToCheck}'"
    else
        grep -E "^${bundleSubDirToCheck}/" <<< "${changedEffectiveBundles}" || die "No changed effective bundles found in '${bundleSubDirToCheck}'"
    fi
}

# To be run after createTestResources. Returns all changed effective bundles by validation dir
getValidationDirs() {
    local bundleSubDirToCheck="${1:-"${BUNDLE_SUB_DIR:-}"}"
    local validationDirs=''
    validationDirs=$(find "${GIT_ROOT}" -type d -name "${VALIDATIONS_DIR_RELATIVE}" -print)
    if [ -z "${bundleSubDirToCheck}" ]; then
        for d in ${validationDirs}; do find "${d}" -mindepth 1 -maxdepth 1 -type d -name "${VALIDATIONS_BUNDLE_PREFIX_ORIG}*"; done
    elif [ "." == "${bundleSubDirToCheck}" ]; then
        validationDirs=$(grep -E "^${GIT_ROOT}/validation-bundles" <<< "${validationDirs}") || die "No changed effective bundles found in '${bundleSubDirToCheck}'"
        for d in ${validationDirs}; do find "${d}" -mindepth 1 -maxdepth 1 -type d -name "${VALIDATIONS_BUNDLE_PREFIX_ORIG}*"; done
    else
        validationDirs=$(grep -E "^${GIT_ROOT}/${bundleSubDirToCheck}/validation-bundles" <<< "${validationDirs}") || die "No changed effective bundles found in '${bundleSubDirToCheck}'"
        for d in ${validationDirs}; do find "${d}" -mindepth 1 -maxdepth 1 -type d -name "${VALIDATIONS_BUNDLE_PREFIX_ORIG}*"; done
    fi
}


# To be run after createTestResources. Returns all changed effective bundles by validation dir
getChangedEffectiveBundlesForValidationDir() {
    local validationBundleToTest="${1:-}"
    local changedEffectiveBundles="${2:-}"
    [ -n "$validationBundleToTest" ] || die "No validation bundle to test provided."
    [ -d "$validationBundleToTest" ] || validationBundleToTest=$(find "${GIT_ROOT}" -type d -name "${validationBundleToTest}" -print | grep -v test-resources)
    [ -d "$validationBundleToTest" ] || die "No validation bundle found for '$validationBundleToTest'."
    [ -n "$changedEffectiveBundles" ] || changedEffectiveBundles=$(getChangedEffectiveBundles)
    [ -f "${validationBundleToTest}/plugins.yaml" ] || die "No plugins.yaml in the validation bundle."
    [ -n "$changedEffectiveBundles" ] || changedEffectiveBundles=$(getChangedEffectiveBundles)
    for d in $changedEffectiveBundles; do
        if grep -qE "# ${d}$" "${validationBundleToTest}/plugins.yaml"; then
            echo "$d"
        fi
    done
}

getValidationDirToChangedBundles() {
    local includeEmpty="${INCLUDE_EMPTY:-}"
    for d in $(getValidationDirs "$@"); do
        local changedBundles=''
        changedBundles=$(getChangedEffectiveBundlesForValidationDir "$d" | xargs || true)
        if [ -n "$changedBundles" ]; then
            echo "$(basename "$d"):$changedBundles"
        elif [ "true" ==  "${includeEmpty}" ]; then
            echo "$(basename "$d"):$changedBundles"
        fi
    done
}

# This function is used to check if the current tag is the latest version
checkForLatestVersion() {
    local currentTag="${1-}"
    currentTag="${currentTag//*:/}"
    local latestVersion=''
    latestVersion=$(curl -s "https://api.github.com/repos/kyounger/casc-plugin-dependency-calculation/releases/latest" | grep -oE "tag_name\": \"v[0-9]+\.[0-9]+\.[0-9]+\"" | cut -d'"' -f 3)
    echo "Latest version of configuration-as-code-plugin is $latestVersion"
    if [ -n "$currentTag" ]; then
        if [ "$(ver "${latestVersion}")" -gt "$(ver "${currentTag}")" ]; then
            die "There is a newer version of casc-plugin-dependency-calculation available ($latestVersion). Please upgrade your version '$currentTag'."
        fi
    fi
}

unknownAction() {
        die "Unknown action '$ACTION' (permitted actions below)

    # management
    - plugins: used to create the minimal set of plugins for your bundles
    - generate: used to create the effective bundles
    - all: running both plugins and then generate
    - force: running both plugins and then generate, but taking a fresh update center json (normally cached for 6 hours, and regenerating the plugin catalog regardless)
    - pre-commit: can be used in combination with https://pre-commit.com/ to avoid unwanted mistakes in commits

    # test utils
    - vars: used to print out the current environment variables for a given (used to test BUNDLE_FILTER etc.)
    - versionCheck: used to check if given tag is the latest version

    # ci utils - for use in the Jenkinsfile (assumes some environment variables are set)
    - createTestResources: can be used in pipelines when validating bundles. creates bundle zips, list detected CI_VERSIONS, etc.
    - getChangedSources: can be used in pipelines when to get changed sources in PR or release branches
    - getTestResultReport: can be used in pipelines to get a summary of the test results
    - runValidations: can be used in pipelines to run validations for all bundles
    - runValidationsChangedOnly: can be used in pipelines to run validations for changed bundles only
    - applyBundleConfigMaps: can be used in pipelines to apply the bundle config maps

    # misc
    - roots: used to run the command on all bundle sub dirs. e.g. 'roots vars' will run 'vars' on all sub dirs

    NOTE: If your bundles are separated into groups through sub-directories, see the section on filtering and the BUNDLE_SUB_DIR environment variables in the repository.
"
}

# main
ACTION="${1:-}"

shift || true
debug "Looking for action '$ACTION'"
case $ACTION in
    versionCheck)
        checkForLatestVersion "$@"
        ;;
    pre-commit)
        processVars "${@}"
        runPrecommit "${@}"
        ;;
    generate)
        processVars "${@}"
        generate
        ;;
    plugins)
        processVars "${@}"
        plugins
        ;;
    force)
        export DRY_RUN=0 REFRESH_UC=1
        processVars "${@}"
        plugins
        generate
        ;;
    all)
        processVars "${@}"
        plugins
        generate
        ;;
    verify)
        processVars "${@}"
        MD5SUM_BEFORE=$(find "${EFFECTIVE_DIR}" "${RAW_DIR}" -type f -exec md5sum {} + | sort -k 2)
        echo "Effective dir checksum before: $MD5SUM_BEFORE"
        plugins
        generate
        echo "Checking MD5SUM values..."
        md5sum -c <(echo "$MD5SUM_BEFORE") || die "ERROR: The bundles have changed (see above). Please commit the changes."
        ;;
    stopServer)
        stopServer
        ;;
    vars)
        processVars "${@}"
        ;;
    createTestResources)
        setDirs "${@}"
        createTestResources
        ;;
    ciVersion)
        findAllKnownCiVersions
        ;;
    copyScripts)
        copyScriptsToAnotherDirectory "${@}"
        ;;
    getChangedSources)
        processVars "${@}"
        getChangedSources
        ;;
    getChangedEffectiveBundles)
        getChangedEffectiveBundles "${@}"
        ;;
    getChangedEffectiveBundlesForValidationDir)
        getChangedEffectiveBundlesForValidationDir "${@}"
        ;;
    getValidationDirToChangedBundles)
        getValidationDirToChangedBundles "${@}"
        ;;
    getValidationDirs)
        getValidationDirs "${@}"
        ;;
    getTestResultReport)
        processVars
        getTestResultReport "${@}"
        ;;
    applyBundleConfigMaps)
        processVars "${@}"
        applyBundleConfigMaps
        ;;
    runValidationsChangedOnly)
        processVars
        runValidationsChangedOnly "${@}"
        ;;
    runValidations)
        processVars
        runValidations "${@}"
        ;;
    roots)
        getBundleRoots "$@"
        ;;
    *)
        unknownAction
        ;;
esac
