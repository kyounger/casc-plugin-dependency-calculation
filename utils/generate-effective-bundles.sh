#!/usr/bin/env bash

set -euo pipefail

BUNDLE_SECTIONS='jcasc items plugins catalog variables rbac'
DRY_RUN="${DRY_RUN:-1}"
DEBUG="${DEBUG:-0}"
TREE_CMD=$(command -v tree || true)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
PARENT_DIR="$(dirname "${SCRIPT_DIR}")"
# assuming some variables - can be overwritten
DEP_TOOL="${DEP_TOOL:-"$PARENT_DIR/run.sh"}"
EFFECTIVE_DIR="${EFFECTIVE_DIR:-"${PWD}/effective-bundles"}"
RAW_DIR="${RAW_DIR:-"${PWD}/raw-bundles"}"
export TARGET_BASE_DIR='' CACHE_BASE_DIR=''
TARGET_BASE_DIR="${TARGET_BASE_DIR:-"$(dirname "$DEP_TOOL")/target"}"
CACHE_BASE_DIR="${CACHE_BASE_DIR:-"$(dirname "$DEP_TOOL")/.cache"}"


die() { echo "$*"; exit 1; }

debug() { if [ "$DEBUG" -eq 1 ]; then echo "$*"; fi; }

processVars() {
    echo "Setting some vars..."
    [ "$DEBUG" -eq 1 ] && COPY_CMD=(cp -v) || COPY_CMD=(cp)
    [ -f "${DEP_TOOL}" ] || die "DEP_TOOL is not a file"
    [ -x "${DEP_TOOL}" ] || die "DEP_TOOL is not executable"
    [ -d "${RAW_DIR}" ] || die "RAW_DIR is not a directory"
    [ -d "${EFFECTIVE_DIR}" ] || die "EFFECTIVE_DIR is not a directory"
    echo "Running with:
    DEP_TOOL=$DEP_TOOL
    TARGET_BASE_DIR=$TARGET_BASE_DIR
    CACHE_BASE_DIR=$CACHE_BASE_DIR
    RAW_DIR=$RAW_DIR
    EFFECTIVE_DIR=$EFFECTIVE_DIR"
}

listFileXInY() {
    find -L "$1" -type f -name "$2" -print0
}

listBundleYamlsIn() {
    listFileXInY "$1" "bundle.yaml"
}

listPluginYamlsIn() {
    listFileXInY "$1" "*plugins*.yaml"
}

listPluginCatalogsIn() {
    listFileXInY "$1" "plugin-catalog*.yaml"
}

findBundleChain() {
    local bundleYaml="${1}/bundle.yaml"
    local currentParent=''
    currentParent=$(grep -oE "^parent: .*$" "$bundleYaml" | tr -d '"' | tr -d "'" | cut -d' ' -f 2 || true)
    if [ -n "$currentParent" ]; then
        BUNDLE_PARENTS="${currentParent} ${BUNDLE_PARENTS}"
        findBundleChain "${versionDir}/${currentParent}"
    fi
}

copyFiles() {
    while IFS= read -r -d '' bundleYaml; do
        bundleDir=$(dirname "$bundleYaml")
        versionDir=$(dirname "$bundleDir")
        versionDirName=$(basename "$versionDir")
        bundleDirName=$(basename "$bundleDir")
        targetDirName="${versionDirName}-${bundleDirName}"
        targetDir="$EFFECTIVE_DIR/${targetDirName}"
        targetBundleYaml="${targetDir}/bundle.yaml"
        # recreate effective bundle
        rm -rf "${targetDir}"
        BUNDLE_PARENTS="$bundleDirName"
        findBundleChain "${bundleDir}"
        i=0
        echo "INFO: Creating bundle '$targetDirName' using parents '$BUNDLE_PARENTS'"
        for parent in ${BUNDLE_PARENTS:-}; do
            parentDir="${versionDir}/${parent}"
            parentBundleYaml="${parentDir}/bundle.yaml"
            mkdir -p "${targetDir}"
            for bundleSection in $BUNDLE_SECTIONS; do
                targetSubDir="${targetDir}/${bundleSection}"
                mkdir -p "${targetSubDir}"
                for cascBundleEntry in $(bundleSection=$bundleSection yq '.[env(bundleSection)][]' "${parentBundleYaml}"); do
                    if [ -f "${parentDir}/${cascBundleEntry}" ]; then
                        srcFile="${parentDir}/${cascBundleEntry}"
                        debug "  Found file: ${srcFile}"
                        targetFileName="${i}.${parent}.${cascBundleEntry}"
                        if [ -s "${srcFile}" ]; then
                            "${COPY_CMD[@]}" "${srcFile}" "${targetSubDir}/${targetFileName}"
                        else
                            debug "Empty file - ignoring...${srcFile}"
                        fi
                    elif [ -d "${parentDir}/${cascBundleEntry}" ]; then
                        debug "  Found directory: ${parentDir}/${cascBundleEntry}"
                        local fileName=''
                        while IFS= read -r -d '' fullFileName; do
                            fileName=$(basename "$fullFileName")
                            srcFile="${parentDir}/${cascBundleEntry}/$fileName"
                            targetFileName=$(echo -n "${i}.${parent}.${cascBundleEntry}/$fileName" | tr '/' '.')
                            debug "  -> $targetFileName"
                            if [ -s "${srcFile}" ]; then
                                "${COPY_CMD[@]}" "${srcFile}" "${targetSubDir}/${targetFileName}"
                            else
                                debug "Empty file - ignoring... ${srcFile}"
                            fi
                        done < <(listFileXInY "${parentDir}/${cascBundleEntry}" "*.yaml")
                    else
                        debug "Entry not found: ${cascBundleEntry}"
                    fi
                done
            done
            "${COPY_CMD[@]}" "${parentDir}/bundle.yaml" "${targetBundleYaml}"
            i=$(( i + 1 ))
        done
        replacePluginCatalog "$targetDir" "$versionDirName"
        # reset sections to directories
        for bundleSection in $BUNDLE_SECTIONS; do
            sectionDir="${targetDir}/${bundleSection}"
            if [ "$(ls -A "${sectionDir}")" ]; then
                bs=$bundleSection yq -i '.[env(bs)] = [env(bs)]' "${targetBundleYaml}"
            else
                bs=$bundleSection yq -i 'del(.[env(bs)])' "${targetBundleYaml}"
                rm -r "${sectionDir}"
            fi
        done
        # remove the parent from the effective bundles
        bp=" (inheritance: $BUNDLE_PARENTS)" yq -i '.description += strenv(bp)' "${targetBundleYaml}"
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
}

replacePluginCatalog() {
    local bundleDir=$1
    local ciVersion=$2
    [ -d "${bundleDir:-}" ] || die "Please set bundleDir (i.e. raw-bundles/<CI_VERSION>)"
    echo "Removing any previous catalog files..."
    rm -f "${bundleDir}/catalog/"*
    finalPluginCatalogYaml="${bundleDir}/catalog/plugin-catalog.yaml"

    local DEP_TOOL_CMD=("$DEP_TOOL" -N -M -v "$ciVersion" -c "$finalPluginCatalogYaml")
    while IFS= read -r -d '' f; do
        DEP_TOOL_CMD+=(-f "$f")
    done < <(listPluginYamlsIn "$bundleDir")
    DEP_TOOL_CMD+=(-c "$finalPluginCatalogYaml")
    echo "Running... ${DEP_TOOL_CMD[*]}"
    if [ "$DRY_RUN" -eq 0 ]; then
        "${DEP_TOOL_CMD[@]}"
    else
        echo "Set DRY_RUN=0 to execute."
    fi
}

## create plugin commands
pluginCommands()
{
    local rootDir="${1:-"$RAW_DIR"}"
    while IFS= read -r -d '' bundleYaml; do
        bundleDir=$(dirname "$bundleYaml")
        versionDir=$(dirname "$bundleDir")
        versionDirName=$(basename "$versionDir")
        while IFS= read -r -d '' f; do
            local DEP_TOOL_CMD=("$DEP_TOOL" -v "$versionDirName" -s -f "$f" -G "$f")
            echo "Running... ${DEP_TOOL_CMD[*]}"
            if [ "$DRY_RUN" -eq 0 ]; then
                "${DEP_TOOL_CMD[@]}"
            else
                echo "Set DRY_RUN=0 to execute."
            fi
        done < <(listPluginYamlsIn "$bundleDir")
    done < <(listBundleYamlsIn "$rootDir")
}

generate() {
    copyFiles
}

commitAnyChangesInEffectiveBundles() {
    # check pristine
    git add "$EFFECTIVE_DIR"
    if [ -n "$(git --no-pager diff --cached --stat "$EFFECTIVE_DIR")" ]; then
        echo 'Diffs found. Checking in...'
        git commit -m "Applying changes to effective bundles" "$EFFECTIVE_DIR"
        git push origin
    else
        echo 'No diff found. Ignoring...'
    fi
}

# main
ACTION="${1:-generate}"
echo "Running action '$ACTION'..."
processVars
case $ACTION in
    pre-commit)
        PRE_COMMIT_LOG=/tmp/pre-commit.check-effective-bundles.log
        $0 generate > "$PRE_COMMIT_LOG" 2>&1
        # fail if non-cached diffs found in effective bundles
        [ -z "$(git --no-pager diff --stat "$EFFECTIVE_DIR")" ] || \
            die "Effective bundles changed - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        [ -z "$(git ls-files "$EFFECTIVE_DIR" --exclude-standard --others)" ] || \
            die "Effective bundles contains untracked files - please stage them before committing. Execution log: $PRE_COMMIT_LOG"
        ;;
    generate)
        generate
        ;;
    pluginCommands)
        shift
        pluginCommands "${@}"
        ;;
    *)
        die "Unknown action '$ACTION'"
        ;;
esac
echo "Done"
