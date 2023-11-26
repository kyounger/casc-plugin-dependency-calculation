#!/usr/bin/env bash

set -euo pipefail

BUNDLE_SECTIONS='jcasc items plugins catalog variables rbac'
DRY_RUN="${DRY_RUN:-1}"
# automatically update catalog if plugin yamls have changed. supercedes DRY_RUN
AUTO_UPDATE_CATALOG="${AUTO_UPDATE_CATALOG:-1}"
DEBUG="${DEBUG:-0}"
TREE_CMD=$(command -v tree || true)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"

# assuming some variables - can be overwritten
EFFECTIVE_DIR="${EFFECTIVE_DIR:-"${PWD}/effective-bundles"}"
RAW_DIR="${RAW_DIR:-"${PWD}/raw-bundles"}"
VALIDATIONS_DIR="${VALIDATIONS_DIR:-"${PWD}/validation-bundles"}"
VALIDATIONS_BUNDLE_PREFIX="${VALIDATIONS_BUNDLE_PREFIX:-val-}"
VALIDATIONS_TEMPLATE="${VALIDATIONS_TEMPLATE:-template}"
CHECKSUM_PLUGIN_FILES_KEY='CHECKSUM_PLUGIN_FILES'
export TARGET_BASE_DIR="${TARGET_BASE_DIR:-"${PWD}/target"}"
export CACHE_BASE_DIR="${CACHE_BASE_DIR:-"${PWD}/.cache"}"

# optional kustomization.yaml creation
KUSTOMIZATION_YAML="${EFFECTIVE_DIR}/kustomization.yaml"
if [ -f "${KUSTOMIZATION_YAML}" ]; then
    command -v kustomize &> /dev/null || die "Do need to install kustomize for this to work? Or remove the '${KUSTOMIZATION_YAML}'"
fi

# CI_VERSION env var set, no detection necessary. Otherwise,
# version detection (detected in the following order):
# - name of parent directory of RAW_DIR
# - name of current git branch (if git on PATH)
CI_DETECTION_PATTERN_DEFAULT="v([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)"
CI_DETECTION_PATTERN="${CI_DETECTION_PATTERN:-"${CI_DETECTION_PATTERN_DEFAULT}"}"
CI_TEST_PATTERN="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]"

# find the DEP_TOOL location (found as cascdeps in the docker image)
if command -v cascdeps &> /dev/null; then
    DEP_TOOL=$(command -v cascdeps)
elif [ -z "${DEP_TOOL:-}" ]; then
    DEP_TOOL="${PARENT_DIR}/run.sh"
fi

die() { echo "$*"; exit 1; }

debug() { if [ "$DEBUG" -eq 1 ]; then echo "$*"; fi; }

determineCIVersion() {
    CI_VERSION="${CI_VERSION:-}"
    # determine CI_VERSION
    if [ -z "${CI_VERSION}" ]; then
        local versionDir='' versionDirName=''
        versionDir=$(dirname "$RAW_DIR")
        versionDirName=$(basename "$versionDir")
        # test parent dir
        if [[ "$versionDirName" =~ $CI_DETECTION_PATTERN ]]; then
            echo "INFO: Setting CI_VERSION according to parent of RAW_DIR."
            CI_VERSION="${BASH_REMATCH[1]}"
        elif [[ "${GIT_BRANCH:-}" =~ $CI_DETECTION_PATTERN ]]; then
            echo "INFO: Setting CI_VERSION according to GIT_BRANCH env var."
            CI_VERSION="${BASH_REMATCH[1]}"
        elif command -v git &> /dev/null; then
            local gitBranch=''
            gitBranch=$(git rev-parse --abbrev-ref HEAD)
            if [[ "$gitBranch" =~ $CI_DETECTION_PATTERN ]]; then
                echo "INFO: Setting CI_VERSION according to git branch from command."
                CI_VERSION="${BASH_REMATCH[1]}"
            fi
        else
            # we've got this without being able to find the CI_VERSION so...
            die "Could not determine a CI_VERSION. Checked env var, RAW_DIR's parent dir, GIT_BRANCH env var, and git branch."
        fi
    else
        echo "INFO: Setting CI_VERSION according to CI_VERSION env var."
    fi
    [[ "${CI_VERSION}" =~ $CI_TEST_PATTERN ]] || die "CI_VERSION '${CI_VERSION}' is not a valid version."
    # set the version with dashes for later use
    CI_VERSION_DASHES="${CI_VERSION//\./-}"
}

processVars() {
    echo "Setting some vars..."
    [ "$DEBUG" -eq 1 ] && COPY_CMD=(cp -v) || COPY_CMD=(cp)
    [ -f "${DEP_TOOL}" ] || die "DEP_TOOL '${DEP_TOOL}' is not a file"
    [ -x "${DEP_TOOL}" ] || die "DEP_TOOL '${DEP_TOOL}' is not executable"
    [ -d "${RAW_DIR}" ] || die "RAW_DIR '${RAW_DIR}' is not a directory"
    [ -d "${EFFECTIVE_DIR}" ] || die "EFFECTIVE_DIR '${EFFECTIVE_DIR}'  is not a directory"
    determineCIVersion
    echo "Running with:
    DEP_TOOL=$DEP_TOOL
    TARGET_BASE_DIR=$TARGET_BASE_DIR
    CACHE_BASE_DIR=$CACHE_BASE_DIR
    RAW_DIR=$RAW_DIR
    EFFECTIVE_DIR=$EFFECTIVE_DIR
    CI_VERSION=$CI_VERSION"
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
    local bundleFilter="${1:-${BUNDLE_FILTER:-}}"
    while IFS= read -r -d '' bundleYaml; do
        bundleDir=$(dirname "$bundleYaml")
        bundleDirName=$(basename "$bundleDir")
        targetDirName="${bundleDirName}"
        targetDir="$EFFECTIVE_DIR/${targetDirName}"
        targetBundleYaml="${targetDir}/bundle.yaml"
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
        echo "INFO: Creating bundle '$targetDirName' using parents '$BUNDLE_PARENTS'"
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
        replacePluginCatalog "$targetDir" "$CI_VERSION" "$targetBundleYaml"
        # add description to the effective bundles
        bp=" (version: $CI_VERSION, inheritance: $BUNDLE_PARENTS)" yq -i '.description += strenv(bp)' "${targetBundleYaml}"
        # remove the parent and availabilityPattern from the effective bundles
        yq -i 'del(.parent)|del(.availabilityPattern)' "${targetBundleYaml}"
        # reinstate the checksum of bundle files to provide unique version which does change with git
        checkSum=$(cd "${targetDir}" && find . -type f -exec md5sum {} + | LC_ALL=C sort | md5sum | cut -d' ' -f 1)
        c=$checkSum yq -i '.version = env(c)' "${targetBundleYaml}"
        echo ""
        if [ -n "$TREE_CMD" ]; then
            echo "INFO: Resulting files created using tree..."
            tree "$targetDir"
        else
            echo "INFO: Resulting files created using poor man's tree..."
            echo "$(cd "${targetDir}"; find . | sed -e "s/[^-][^\/]*\// |/g" -e "s/|\([^ ]\)/|-\1/")"
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
    [ -d "${bundleDir:-}" ] || die "Please set bundleDir (i.e. raw-bundles/<BUNDLE_NAME>)"
    local pluginCatalogYamlFile="catalog.plugin-catalog.yaml"
    finalPluginCatalogYaml="${bundleDir}/${pluginCatalogYamlFile}"
    local DEP_TOOL_CMD=("$DEP_TOOL" -N -M -v "$ciVersion")
    local PLUGINS_LIST_CMD=("yq" "--no-doc" ".plugins")
    while IFS= read -r -d '' f; do
        PLUGINS_LIST_CMD+=("$f")
        DEP_TOOL_CMD+=(-f "$f")
    done < <(listPluginYamlsIn "$bundleDir")

    # do we even have plugins files?
    if [ "yq --no-doc .plugins" == "${PLUGINS_LIST_CMD[*]}" ]; then
        echo "No plugins yaml files found.}"
        echo "Removing any previous catalog files..."
        rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
        bs="catalog" yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
        return 0
    fi

    DEP_TOOL_CMD+=(-c "$finalPluginCatalogYaml")
    # this is a tricky one, but we want
    # - unique list of plugins from all files
    # - comments should be preserved so that last comment stays (important for custom tags)
    # - see the bottom of this script for an example
    local checkSumEffectivePlugins=''
    local checkSumPluginsExpected=''
    local checkSumFullActual=''
    local checkSumPluginsActual=''
    local effectivePluginsList=''
    effectivePluginsList=$("${PLUGINS_LIST_CMD[@]}" | yq '. |= (reverse | unique_by(.id) | sort_by(.id))' - --header-preprocess=false)
    checkSumEffectivePlugins=$(echo "$effectivePluginsList" | md5sum | cut -d' ' -f 1)
    if [ -f "${finalPluginCatalogYaml}" ]; then
        # check for checksum in catalog
        checkSumFullActual=$(yq '. | head_comment' "$finalPluginCatalogYaml" | xargs | cut -d'=' -f 2)
        checkSumPluginsActual="${checkSumFullActual%-*}"
    fi
    checkSumPluginsExpected="${CI_VERSION_DASHES}-${checkSumEffectivePlugins}"
    # check for AUTO_UPDATE_CATALOG
    local localDryRun="${DRY_RUN}"
    echo ""
    echo "AUTO_UPDATE_CATALOG - Plugin catalog version has the format <CI_VERSION_DASHES>-<EFFECTIVE_PLUGINS_MD5SUM>-<CATALOG_INCLUDE_PLUGINS_MD5SUM>"
    echo ""
    echo "AUTO_UPDATE_CATALOG - Checking effective plugins checksum 'actual: $checkSumPluginsActual' vs 'expected: $checkSumPluginsExpected'"
    if [ "$checkSumPluginsActual" != "$checkSumPluginsExpected" ]; then
        if [ -z "$checkSumPluginsActual" ]; then
            echo "AUTO_UPDATE_CATALOG - no current plugin catalog found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)..."
            localDryRun=0
        elif [ "$AUTO_UPDATE_CATALOG" -eq 0 ] && [ "$DRY_RUN" -eq 1 ]; then
            echo "WARNING: AUTO_UPDATE_CATALOG - differences in plugins checksum (found in head comment of plugin catalog) found but neither AUTO_UPDATE_CATALOG=1 nor is DRY_RUN=0"
        else
            echo "AUTO_UPDATE_CATALOG - differences in plugins found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)..."
            localDryRun=0
        fi
    fi
    echo ""
    echo "Running... ${DEP_TOOL_CMD[*]}"
    if [ "$localDryRun" -eq 0 ]; then
        echo "Removing any previous catalog files..."
        rm -rf "${bundleDir}/catalog" "${finalPluginCatalogYaml}"
        "${DEP_TOOL_CMD[@]}"
        # reset head_comment to new checksum
        local checkSumIncludePlugins=''
        local checkSumFullExpected=''
        checkSumIncludePlugins=$(yq '.configurations[0].includePlugins' "$finalPluginCatalogYaml" | md5sum | cut -d' ' -f 1)
        checkSumFullExpected="${checkSumPluginsExpected}-${checkSumIncludePlugins}"
        csum="${CHECKSUM_PLUGIN_FILES_KEY}=${checkSumFullExpected}" yq -i '. head_comment=env(csum)' "${finalPluginCatalogYaml}"
        createValidation "$checkSumFullExpected" "$effectivePluginsList"
    else
        echo "Set DRY_RUN=0 to execute, or AUTO_UPDATE_CATALOG=1 to execute automatically."
    fi
    # set the plugin catalog section if needed
    local pluginsInCatalog='0'
    if [ -f "$finalPluginCatalogYaml" ]; then
        pluginsInCatalog=$(yq '.configurations[0].includePlugins|length' "${finalPluginCatalogYaml}")
        if [ "$pluginsInCatalog" -gt 0 ]; then
            bs=catalog pc="${pluginCatalogYamlFile}" yq -i '.[env(bs)] = [env(pc)]' "${targetBundleYaml}"
        else
            echo "No plugins in catalog. No need to set it in bundle..."
        fi
    else
        echo "No plugin catalog file. No need to set it in bundle..."
    fi
}

## create plugin commands
plugins() {
    local bundleFilter="${1:-${BUNDLE_FILTER:-}}"
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
            local DEP_TOOL_CMD=("$DEP_TOOL" -v "$CI_VERSION" -sAf "$f" -G "$f")
            echo "Running... ${DEP_TOOL_CMD[*]}"
            if [ "$DRY_RUN" -eq 0 ] || [ "$AUTO_UPDATE_CATALOG" -eq 1 ]; then
                "${DEP_TOOL_CMD[@]}"
                # if we run the 'force' command, we still only want to download the UC once per call
                REFRESH_UC=0
            else
                echo "Set DRY_RUN=0 or AUTO_UPDATE_CATALOG=1 to execute."
            fi
        done < <(listPluginYamlsIn "$bundleDir")
    done < <(listBundleYamlsIn "$RAW_DIR")
}

cleanupUnusedBundles() {
    echo "Running clean up effective bundles..."
    # Effective
    for d in $(find "${EFFECTIVE_DIR}" -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort); do
        [[ -e "$d" ]] || break
        local bundleName=''
        bundleName=$(basename "$d")
        if [ ! -d "${RAW_DIR}/$bundleName" ]; then
            echo "CLEANUP - Removing unused effective bundle '${bundleName}'"
            rm -rf "${EFFECTIVE_DIR}/${bundleName:?}"
        fi
    done
    echo "Running clean up validation bundles if present..."
    if [ -d "$VALIDATIONS_DIR" ]; then
        # Validations
        for d in "${VALIDATIONS_DIR}/${VALIDATIONS_BUNDLE_PREFIX}"*; do
            [[ -e "$d" ]] || break # break if empty
            local bundleName=''
            bundleName=$(basename "$d")
            [[ "$bundleName" != "${VALIDATIONS_TEMPLATE}" ]] || continue # # skip the VALIDATIONS_TEMPLATE
            local validationCheckSum="${bundleName//"${VALIDATIONS_BUNDLE_PREFIX}"/}"
            echo "CLEANUP - Looking for validation checksum '$validationCheckSum'"
            if ! grep -rq "$validationCheckSum" "${EFFECTIVE_DIR}"; then
                echo "CLEANUP - Removing unused validation bundle '${bundleName}'"
                rm -rf "${VALIDATIONS_DIR}/${bundleName:?}"
            else
                # Exists so let's add all associated effective bundles as a head comment for
                # easier processing afterwards
                local headerStr=''
                while IFS= read -r f; do
                    [[ -e "$f" ]] || break
                    local associatedBundleName=''
                    associatedBundleName=$(basename "$(dirname "$f")")
                    echo "Adding associated bundle '$associatedBundleName'"
                    if [ -z "$headerStr" ]; then
                        headerStr="$associatedBundleName"
                    else
                        headerStr=$(printf '%s\n%s' "$headerStr" "$associatedBundleName")
                    fi
                done < <(grep -rl "${CHECKSUM_PLUGIN_FILES_KEY}=${validationCheckSum}" "${EFFECTIVE_DIR}")
                headerStr="${headerStr}" yq -i '. head_comment=strenv(headerStr)' "${d}/plugins.yaml"
            fi
        done
    fi
    echo "Recreating the kustomisation.yaml if found at root of effective-bundles directory..."
    if [ -f "${KUSTOMIZATION_YAML}" ]; then
        echo -n > "${KUSTOMIZATION_YAML}"
        (cd "$EFFECTIVE_DIR" && {
            for d in $(find . -mindepth 1 -maxdepth 1 -type d -printf '%P\n' | sort); do
                kustomize edit add configmap "${CI_VERSION_DASHES}-${d}" --behavior=create --disableNameSuffixHash --from-file="$d/*";
            done
        };)
        echo "Recreated the kustomisation.yaml"
    fi
}

createValidation() {
    local checkSumFullExpected=$1
    local effectivePluginsList=$2
    # validation bundles - we are assuming there is only 1 x plugins.yaml, 1 x plugin-catalog.yaml
    local validationBundle="${VALIDATIONS_BUNDLE_PREFIX}${checkSumFullExpected}"
    local validationDir="${VALIDATIONS_DIR}/${validationBundle}"
    if [ -d "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}" ]; then
        echo "VALIDATION BUNDLES - Checking bundle '$validationBundle'"
        if [ ! -d "${validationDir}" ] || [ "$DRY_RUN" -eq 0 ]; then
            echo "VALIDATION BUNDLES - Creating bundle '$validationBundle'"
            rm -rf "${validationDir}"
            cp -r "${VALIDATIONS_DIR}/${VALIDATIONS_TEMPLATE}" "${validationDir}"
            touch "${validationDir}/plugins.yaml"
            pl="$effectivePluginsList" yq -i '.plugins = env(pl)' "${validationDir}/plugins.yaml"
            cp -r "${finalPluginCatalogYaml}" "${validationDir}/plugin-catalog.yaml"
        else
            echo "VALIDATION BUNDLES - Existing bundle '$validationBundle' found."
        fi
    else
        echo "VALIDATION BUNDLES - No validation template found so not creating for '$validationBundle'."
    fi
}

# main
ACTION="${1:-}"
echo "Looking for action '$ACTION'"
case $ACTION in
    pre-commit)
        processVars
        PRE_COMMIT_LOG=/tmp/pre-commit.check-effective-bundles.log
        $0 generate > "$PRE_COMMIT_LOG" 2>&1
        # if we:
        # - ran without recreating the plugin catalogs (DRY_RUN=1)
        # - find changes to effective plugins directories
        # then:
        # - we need to update the plugin catalogs before checking...
        CHANGED_PLUGINS_FILES=$(git ls-files --others --modified "${EFFECTIVE_DIR}"/**/plugins)
        CACHED_PLUGINS_FILES=$(git diff --name-only --cached "${EFFECTIVE_DIR}"/**/plugins)
        if [ "$DRY_RUN" -ne 0 ] && [ -n "$CHANGED_PLUGINS_FILES" ]; then
            die "Changes to plugins detected - please generate manually using DRY_RUN=0 to recreate the plugin catalog. !!!Pro Tip!!! use the filtering options to save time'. Execution log: $PRE_COMMIT_LOG"
        elif [ "$DRY_RUN" -ne 0 ] && [ -n "$CACHED_PLUGINS_FILES" ]; then
            echo ""
            echo "WARNING >>>> Cached plugin files found! Reminder to please ensure you recreated the plugin catalog using DRY_RUN=0"
            echo "WARNING >>>> Cached plugin files found! Ignore this if you have recreated the plugin catalog."
            echo ""
        fi
        # fail if non-cached diffs found in effective bundles
        [ -z "$(git --no-pager diff --stat "$EFFECTIVE_DIR")" ] || \
            die "Effective bundles changed - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        [ -z "$(git ls-files "$EFFECTIVE_DIR" --exclude-standard --others)" ] || \
            die "Effective bundles contains untracked files - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        # optional validation bundles
        if [ -d "validation-bundles" ]; then
            # fail if non-cached diffs found in effective bundles
            [ -z "$(git --no-pager diff --stat "$VALIDATIONS_DIR")" ] || \
                die "Effective bundles changed - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
            [ -z "$(git ls-files "$VALIDATIONS_DIR" --exclude-standard --others)" ] || \
                die "Effective bundles contains untracked files - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        fi
        ;;
    generate)
        processVars
        shift
        generate "${@}"
        ;;
    plugins)
        processVars
        shift
        plugins "${@}"
        ;;
    force)
        export DRY_RUN=0 REFRESH_UC=1
        processVars
        shift
        plugins "${@}"
        generate "${@}"
        ;;
    all)
        processVars
        shift
        plugins "${@}"
        generate "${@}"
        ;;
    *)
        die "Unknown action '$ACTION' (actions are: pre-commit, generate, plugins, all, force)
    - plugins: used to create the minimal set of plugins for your bundles
    - generate: used to create the effective bundles
    - all: running both plugins and then generate
    - force: running both plugins and then generate, but taking a fresh update center json (normally cached for 6 hours, and regenerating the plugin catalog regardless)
    - pre-commit: can be used in combination with https://pre-commit.com/ to avoid unwanted mistakes in commits"
        ;;
esac
echo "Done"

# Example: unique plugins
#
# 1. WE TAKE THE PLUGINS FROM ALL FILES
#
# ❯ yq --no-doc '.plugins' plugins.0.base.plugins.plugins.yaml plugins.1.bundle-a.plugins.plugins.yaml plugins.2.controller-c.plugins.plugins.yaml
# # base comment
# - id: beer # 3rd src
# - id: cloudbees-casc-client # cap src
# - id: cloudbees-casc-items-controller # cap src
# - id: cloudbees-prometheus # 3rd src
# - id: configuration-as-code # cap src
# - id: github # cap src
# - id: infradna-backup # cap src
# - id: managed-master-hibernation # cap src
# - id: pipeline-model-definition # cap src
# - id: pipeline-stage-view # cap src
# - id: sshd # cap src

# # bundle-a comment
# - id: beer # 3rd src
# - id: branch-api # cap dep
# - id: job-dsl # 3rd src

# # controller-c comment
# - id: beer # 3rd src
# - id: git # cap dep
# - id: jfrog # 3rd src
# - id: pipeline-model-definition # cap dep
#
# 2. WE PIPE INTO REVERSE, UNIQUE_BY_ID, SORT_BY_ID (the controller-c comment is preserved)
#
# .... | yq '. |= (reverse | unique_by(.id) | sort_by(.id))' - --header-preprocess=false
#
# # controller-c comment
# - id: beer # 3rd src
# - id: branch-api # cap dep
# - id: cloudbees-casc-client # cap src
# - id: cloudbees-casc-items-controller # cap src
# - id: cloudbees-prometheus # 3rd src
# - id: configuration-as-code # cap src
# - id: git # cap dep
# - id: github # cap src
# - id: infradna-backup # cap src
# - id: jfrog # 3rd src
# - id: job-dsl # 3rd src
# - id: managed-master-hibernation # cap src
# - id: pipeline-model-definition # cap dep
# - id: pipeline-stage-view # cap src
# - id: sshd # cap src

