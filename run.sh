#!/usr/bin/env bash

set -euo pipefail

# Initialize our own variables:
INDENT_SPACING='  '
ADD_TS="${ADD_TS:-0}"
STDERR_LOG_SUFFIX='.stderr.log'
CHECK_CVES=1
INCLUDE_BOOTSTRAP=0
INCLUDE_OPTIONAL=0
DOWNLOAD=0
VERBOSE_LOG=0
REFRESH_UC=0
MINIMAL_PLUGIN_LIST="${MINIMAL_PLUGIN_LIST:-0}"
DEDUPLICATE_PLUGINS="${DEDUPLICATE_PLUGINS:-0}"
CI_VERSION=
CI_TYPE=mm
PLUGIN_YAML_PATHS_FILES=()
PLUGIN_YAML_PATHS_IDX=0
PLUGIN_YAML_PATH="plugins.yaml"
PLUGIN_CATALOG_OFFLINE_EXEC_HOOK=''
PLUGIN_YAML_COMMENTS_STYLE=line
CURRENT_DIR=$(pwd)
TARGET_BASE_DIR="${TARGET_BASE_DIR:="${CURRENT_DIR}/target"}"
CACHE_BASE_DIR="${CACHE_BASE_DIR:="${CURRENT_DIR}/.cache"}"
CB_HELM_REPO_URL=https://public-charts.artifacts.cloudbees.com/repository/public/index.yaml
JENKINS_UC_ACTUAL_URL='https://updates.jenkins.io/update-center.actual.json'

show_help() {
cat << EOF
Usage: ${0##*/} -v <CI_VERSION> [OPTIONS]

    -h          display this help and exit
    -f FILE     path to the plugins.yaml file (can be set multiple times)
    -M          When processing multiple plugins files, DEDUPLICATE the list first
    -v          The version of CloudBees CI (e.g. 2.263.4.2)
    -t          The instance type (oc, oc-traditional, cm, mm)

    -F FILE     Final target of the resulting plugins.yaml
    -G FILE     Final target of the resulting plugins-minimal.yaml
    -c FILE     Final target of the resulting plugin-catalog.yaml
    -C FILE     Final target of the resulting plugin-catalog-offline.yaml

    -d          Download plugins to use later (e.g. PFILE in exec hooks)
    -D STRING   Offline pattern or set PLUGIN_CATALOG_OFFLINE_URL_BASE
                    This make use of the PNAME and PVERSION markers
                    e.g. -D 'http://plugin-catalog/plugins/PNAME/PVERSION/PNAME.hpi'
                    If not set, the URL defaults to the official url of the plugin
    -e FILE     Exec-hook - script to call when processing 3rd party plugins
                    script will have access env vars:
                    PNAME - the name of the plugin
                    PVERSION - the version of the plugin
                    PURL - the url as specified above
                    PURL_OFFICIAL - the official default url given in the update center
                    PFILE - the path to the downloaded plugin (NOTE: empty if '-d' not used)
                    can be used to automate the uploading of plugins to a repository manager
                    see examples under examples/exec-hooks

    -i          Include optional dependencies in the plugins.yaml
    -I          Include bootstrap dependencies in the plugins.yaml
    -m STYLE    Include plugin metadata as comment (line, header, footer, none)
                    defaults to '$PLUGIN_YAML_COMMENTS_STYLE'
    -s          Create a MINIMAL plugin list (auto-removing bootstrap and dependencies)
    -S          Disable CVE check against plugins (added to metadata)

    -R          Refresh the downloaded update center jsons (no-cache)
    -V          Verbose logging (for debugging purposes)

EOF
}

if [[ ${#} -eq 0 ]]; then
   show_help
   exit 0
fi

OPTIND=1
# Resetting OPTIND is necessary if getopts was used previously in the script.
# It is a good idea to make OPTIND local if you process options in a function.

while getopts iIhv:xf:F:G:c:C:m:MRsSt:VdD:e: opt; do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        v)  CI_VERSION=$OPTARG
            ;;
        t)  CI_TYPE=$OPTARG
            ;;
        V)  VERBOSE_LOG=1
            ;;
        d)  DOWNLOAD=1
            ;;
        D)  PLUGIN_CATALOG_OFFLINE_URL_BASE=$OPTARG
            ;;
        e)  PLUGIN_CATALOG_OFFLINE_EXEC_HOOK=$OPTARG
            ;;
        f)  PLUGIN_YAML_PATHS_FILES[$PLUGIN_YAML_PATHS_IDX]=$OPTARG
            PLUGIN_YAML_PATHS_IDX=$((PLUGIN_YAML_PATHS_IDX + 1))
            ;;
        F)  FINAL_TARGET_PLUGIN_YAML_PATH=$OPTARG
            ;;
        G)  FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL=$OPTARG
            ;;
        c)  FINAL_TARGET_PLUGIN_CATALOG=$OPTARG
            ;;
        C)  FINAL_TARGET_PLUGIN_CATALOG_OFFLINE=$OPTARG
            ;;
        i)  INCLUDE_OPTIONAL=1
            ;;
        I)  INCLUDE_BOOTSTRAP=1
            ;;
        m)  PLUGIN_YAML_COMMENTS_STYLE=$OPTARG
            ;;
        M)  DEDUPLICATE_PLUGINS=1
            ;;
        R)  REFRESH_UC=1
            ;;
        s)  MINIMAL_PLUGIN_LIST=1
            ;;
        S)  CHECK_CVES=0
            ;;
        *)
            show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"   # Discard the options and sentinel --

# debug
debug() {
  [ $VERBOSE_LOG -eq 0 ] || cat <<< "$(timestampMe)DEBUG: $@" 1>&2
}

timestampMe() {
  [ $ADD_TS -eq 0 ] || date -u +"%H:%M:%S "
}

# echo to stderr
info() {
  cat <<< "$(timestampMe)INFO: $@" 1>&2
}

# echo to stderr
warn() {
  cat <<< "$(timestampMe)WARN: $@" 1>&2
}

# echo to stderr and exit 1
die() {
  cat <<< "$(timestampMe)ERROR: $@" 1>&2
  exit 1
}

extractAndFormat() {
  cat "${1}" | sed 's/.*\post(//' | sed 's/);\w*$//' | jq .
}

cacheUpdateCenter() {
  #download update-center.json file and cache it
  if [[ -f "${CB_UPDATE_CENTER_CACHE_FILE}" ]] && [ $REFRESH_UC -eq 0 ]; then
    info "$(basename ${CB_UPDATE_CENTER_CACHE_FILE}) already exist, remove it or use the '-R' flag" >&2
  else
    info "Caching UC to '$CB_UPDATE_CENTER_CACHE_FILE'"
    mkdir -p $CB_UPDATE_CENTER_CACHE_DIR
    curl --fail -sSL -o "${CB_UPDATE_CENTER_CACHE_FILE}" "${CB_UPDATE_CENTER_URL_WITH_VERSION}"
  fi

  [ $CHECK_CVES -eq 1 ] || return 0
  #download update-center.actual.json file and cache it
  if [[ -f "${CB_UPDATE_CENTER_ACTUAL}" ]] && [ $REFRESH_UC -eq 0 ]; then
    info "$(basename ${CB_UPDATE_CENTER_ACTUAL}) already exist, remove it or use the '-R' flag" >&2
  else
    info "Caching UC actual.json to '$CB_UPDATE_CENTER_ACTUAL'"
    mkdir -p $CB_UPDATE_CENTER_ACTUAL_CACHE_DIR
    curl --fail -sSL -o "${CB_UPDATE_CENTER_ACTUAL}" "${JENKINS_UC_ACTUAL_URL}"
    jq '.warnings[]|select(.type == "plugin")' "${CB_UPDATE_CENTER_ACTUAL}" > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}"
    jq -r '.name' "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}" | sort -u > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}.txt"
    jq '.warnings[]|select(.type == "plugin")' "${CB_UPDATE_CENTER_ACTUAL}" > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}"
    rm -rf "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}."*.json
  fi
}

prereqs() {
  for tool in yq jq curl awk; do
    command -v $tool &> /dev/null || die "You need to install $tool"
  done
  # some general sanity checks
  if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK:-}" ]; then
    [ -f "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be a file"
    [ -x "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be executable"
  fi
  [[ "$CI_TYPE" =~ ^(mm|oc|cm|oc-traditional)$ ]] || die "CI_TYPE '${CI_TYPE}' not recognised"
}

setScriptVars() {
  #adjustable vars. Will inherit from shell, but default to what you see here.
  CB_UPDATE_CENTER=${CB_UPDATE_CENTER:="https://jenkins-updates.cloudbees.com/update-center/envelope-core-${CI_TYPE}"}
  PLUGIN_CATALOG_OFFLINE_URL_BASE="${PLUGIN_CATALOG_OFFLINE_URL_BASE:-}"
  #calculated vars
  CB_UPDATE_CENTER_URL="$CB_UPDATE_CENTER/update-center.json"
  CB_UPDATE_CENTER_URL_WITH_VERSION="$CB_UPDATE_CENTER/update-center.json?version=$CI_VERSION"

  #cache some stuff locally, sure cache directory exists
  info "Setting CACHE_BASE_DIR=$CACHE_BASE_DIR"
  CB_UPDATE_CENTER_CACHE_DIR="$CACHE_BASE_DIR/$CI_VERSION/$CI_TYPE/update-center"
  CB_UPDATE_CENTER_CACHE_FILE="${CB_UPDATE_CENTER_CACHE_DIR}/update-center.json"
  CB_UPDATE_CENTER_ACTUAL_CACHE_DIR="${CACHE_BASE_DIR}/update-center-actual"
  CB_UPDATE_CENTER_ACTUAL="${CB_UPDATE_CENTER_ACTUAL_CACHE_DIR}/update-center.actual.json"
  CB_UPDATE_CENTER_ACTUAL_WARNINGS="${CB_UPDATE_CENTER_ACTUAL}.plugins.warnings.json"

  PIMT_JAR_CACHE_DIR="$CACHE_BASE_DIR/pimt-jar"
  PLUGINS_CACHE_DIR="$CACHE_BASE_DIR/plugins"

  # final location stuff
  FINAL_TARGET_PLUGIN_YAML_PATH="${FINAL_TARGET_PLUGIN_YAML_PATH:-}"
  FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL="${FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL:-}"
  FINAL_TARGET_PLUGIN_CATALOG="${FINAL_TARGET_PLUGIN_CATALOG:-}"
  FINAL_TARGET_PLUGIN_CATALOG_OFFLINE="${FINAL_TARGET_PLUGIN_CATALOG_OFFLINE:-}"

  # check for multiple source files
  if [ ${#PLUGIN_YAML_PATHS_FILES[@]} -eq 0 ]; then
    info "Using the default file '$PLUGIN_YAML_PATH'."
  elif [ ${#PLUGIN_YAML_PATHS_FILES[@]} -eq 1 ]; then
    PLUGIN_YAML_PATH="${PLUGIN_YAML_PATHS_FILES[0]}"
    info "Using the single file '$PLUGIN_YAML_PATH'."
  elif [ ${#PLUGIN_YAML_PATHS_FILES[@]} -gt 1 ]; then
    PLUGIN_YAML_PATH=$(mktemp)
    info "Multiple source files passed. Creating temporary plugins.yaml file '$PLUGIN_YAML_PATH'."
    for i in $(echo ${!PLUGIN_YAML_PATHS_FILES[@]}); do
      tmpStr=$(yq eval-all '. as $item ireduce ({}; . *+ $item )' "$PLUGIN_YAML_PATH" "${PLUGIN_YAML_PATHS_FILES[$i]}")
      echo "$tmpStr" > "$PLUGIN_YAML_PATH"
    done
  fi
  # sanity checks
  [ -f "${PLUGIN_YAML_PATH}" ] || die "The plugins yaml '${PLUGIN_YAML_PATH}' is not a file."

  PLUGIN_CATALOG_PATH=$(dirname "$PLUGIN_YAML_PATH")/plugin-catalog.yaml
}

createTargetDirs() {
  # Set target files
  TARGET_DIR="${TARGET_BASE_DIR}/${CI_VERSION}/${CI_TYPE}"
  TARGET_GEN="${TARGET_DIR}/generated"

  TARGET_PLUGIN_LIST_ALL_EXPECTED="${TARGET_GEN}/list-all-expected-in-controller.txt"
  TARGET_PLUGIN_DEPS_PROCESSED="${TARGET_GEN}/deps-processed.txt"
  TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE="${TARGET_GEN}/deps-processed-tree-single.txt"
  TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL="${TARGET_GEN}/deps-processed-non-top-level.txt"
  TARGET_PLUGIN_DEPENDENCY_RESULTS="${TARGET_GEN}/deps-processed-results.yaml"
  TARGET_NONE="${TARGET_GEN}/pimt-without-plugins.yaml"
  TARGET_ALL="${TARGET_GEN}/pimt-with-plugins.yaml"
  TARGET_DIFF="${TARGET_GEN}/pimt-diff.yaml"
  TARGET_UC_ONLINE="${TARGET_GEN}/update-center-online.json"
  TARGET_UC_ONLINE_ALL="${TARGET_UC_ONLINE}.plugins.all.txt"
  TARGET_UC_ONLINE_ALL_WITH_URL="${TARGET_UC_ONLINE}.plugins.all-with-url.txt"
  TARGET_UC_ONLINE_ALL_WITH_VERSION="${TARGET_UC_ONLINE}.plugins.all-with-version.txt"
  TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS="${TARGET_UC_ONLINE}.tier.3rd-party.txt"
  TARGET_UC_ONLINE_DEPRECATED_PLUGINS="${TARGET_UC_ONLINE}.deprecated.txt"
  TARGET_OPTIONAL_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.optional.txt"
  TARGET_REQUIRED_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.required.txt"
  TARGET_PLATFORM_PLUGINS="${TARGET_GEN}/platform-plugins.json"
  TARGET_ENVELOPE="${TARGET_GEN}/envelope.json"
  TARGET_ENVELOPE_BOOTSTRAP="${TARGET_ENVELOPE}.bootstrap.txt"
  TARGET_ENVELOPE_NON_BOOTSTRAP="${TARGET_ENVELOPE}.non-bootstrap.txt"
  TARGET_ENVELOPE_ALL_CAP="${TARGET_ENVELOPE}.all.txt"
  TARGET_ENVELOPE_ALL_CAP_WITH_VERSION="${TARGET_ENVELOPE}.all-with-version.txt"
  TARGET_ENVELOPE_DIFF="${TARGET_GEN}/envelope.json.diff.txt"
  TARGET_PLUGIN_CATALOG="${TARGET_DIR}/plugin-catalog.yaml"
  TARGET_PLUGIN_CATALOG_OFFLINE="${TARGET_DIR}/plugin-catalog-offline.yaml"
  TARGET_PLUGINS_YAML="${TARGET_DIR}/plugins.yaml"
  TARGET_PLUGINS_YAML_MINIMAL="${TARGET_DIR}/plugins-minimal.yaml"
  # original files
  TARGET_PLUGINS_YAML_ORIG="${TARGET_PLUGINS_YAML}.orig.yaml"
  TARGET_PLUGIN_CATALOG_ORIG="${TARGET_PLUGIN_CATALOG}.orig.yaml"
  # sanitized files
  TARGET_PLUGINS_YAML_SANITIZED="${TARGET_PLUGINS_YAML}.sanitized.yaml"
  TARGET_PLUGINS_YAML_ORIG_SANITIZED="${TARGET_PLUGINS_YAML}.orig.sanitized.yaml"
  TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT="${TARGET_PLUGINS_YAML_ORIG_SANITIZED}.txt"
  TARGET_PLUGIN_CATALOG_ORIG_SANITIZED="${TARGET_PLUGIN_CATALOG}.orig.sanitized.yaml"

  info "Creating target dir (${TARGET_DIR})"
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_GEN}"
}

equalPlugins() {
  diff <(yq '.plugins|sort_by(.id)' "$PLUGIN_YAML_PATH") <(yq '.plugins|unique_by(.id)|sort_by(.id)' "$PLUGIN_YAML_PATH")
}

copyOrExtractMetaInformation() {
  #create a space-delimited list of plugins from plugins.yaml to pass to PIMT
  info "Sanity checking '$PLUGIN_YAML_PATH' for duplicates."
  if ! equalPlugins; then
    if [ $DEDUPLICATE_PLUGINS -eq 1 ]; then
      info "Found duplicates above - removing from '$PLUGIN_YAML_PATH'."
      deDupes=$(yq '.plugins|unique_by(.id)' "$PLUGIN_YAML_PATH") \
        yq -i '.plugins = env(deDupes)' "$PLUGIN_YAML_PATH"
      equalPlugins || die "Something went wrong with the deduplication. Please check the commands used..."
    else
      die "Please use '-M' or remove the duplicate plugin above before continuing."
    fi
  fi

  LIST_OF_PLUGINS_MULTILINE=$(yq '.plugins[].id ' "$PLUGIN_YAML_PATH")
  LIST_OF_PLUGINS=$(echo "$LIST_OF_PLUGINS_MULTILINE" | xargs)

  # save a copy of the original json files
  cp "${PLUGIN_YAML_PATH}" "${TARGET_PLUGINS_YAML_ORIG}"
  # copy again and sanitize (better for comparing later)
  cp "${PLUGIN_YAML_PATH}" "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}"
  yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}"
  yq '.plugins[].id' "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}" | sort > "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT}"
  # caching internally
  # using associative array everywhere for easy access and performance
  # if no value available. the key is used as the value
  unset TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT_ARR
  declare -g -A TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT_ARR
  while IFS=: read -r key value; do
      TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT_ARR["$key"]="${value:=$key}"
  done < "$TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT"


  # same for the plugin-catalog.yaml (if it exists)
  if [ -f "${PLUGIN_CATALOG_PATH}" ]; then
    cp "${PLUGIN_CATALOG_PATH}" "${TARGET_PLUGIN_CATALOG_ORIG}"
    cp "${PLUGIN_CATALOG_PATH}" "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED}"
    yq -i '.configurations[0].includePlugins|=sort_keys(..)|... comments=""' "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED}"
  fi

  # copy meta data json files
  cp "${PLUGIN_YAML_PATH}" "${TARGET_DIR}/"
  extractAndFormat "${CB_UPDATE_CENTER_CACHE_FILE}" > "${TARGET_UC_ONLINE}"

  # extract online envelope json
  jq '.envelope' "${TARGET_UC_ONLINE}" > "${TARGET_ENVELOPE}"

  # create some info lists from the envelope
  jq -r '.plugins[]|select(.scope|test("(bootstrap)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE_BOOTSTRAP}"
  jq -r '.plugins[]|select(.scope|test("(fat)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE_NON_BOOTSTRAP}"
  jq -r '.plugins[]|select(.scope|test("(bootstrap|fat)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE_ALL_CAP}"
  jq -r '.plugins[]|"\(.artifactId):\(.version)"' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE_ALL_CAP_WITH_VERSION}"

  # create some info lists from the online update-center
  jq -r '.plugins[]|.name' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_ALL}"
  jq -r '.plugins[]|"\(.name):\(.dependencies[]|select(.optional == false)|.name)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_REQUIRED_DEPS}"
  jq -r '.plugins[]|"\(.name):\(.dependencies[]|select(.optional == true)|.name)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_OPTIONAL_DEPS}"
  jq -r '.plugins[]|"\(.name):\(.version)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_ALL_WITH_VERSION}"
  jq -r '.plugins[]|"\(.name)|\(.url)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_ALL_WITH_URL}"
  jq -r '.envelope.plugins[]|select(.tier|test("(compatible)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.compatible.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(proprietary)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.proprietary.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(verified)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.verified.txt"
  jq -r '.plugins[]|select((.labels != null) and (.labels[]|index("deprecated")) != null).name' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_DEPRECATED_PLUGINS}"
  comm -13 "${TARGET_ENVELOPE_ALL_CAP}" "${TARGET_UC_ONLINE_ALL}" \
    > "${TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS}"

  # caching internally
  # using associative array everywhere for easy access and performance
  # if no value available. the key is used as the value
  unset TARGET_ENVELOPE_BOOTSTRAP_ARR
  declare -g -A TARGET_ENVELOPE_BOOTSTRAP_ARR
  while IFS=: read -r key value; do
      TARGET_ENVELOPE_BOOTSTRAP_ARR["$key"]="${value:=$key}"
  done < "$TARGET_ENVELOPE_BOOTSTRAP"

  unset TARGET_ENVELOPE_NON_BOOTSTRAP_ARR
  declare -g -A TARGET_ENVELOPE_NON_BOOTSTRAP_ARR
  while IFS=: read -r key value; do
      TARGET_ENVELOPE_NON_BOOTSTRAP_ARR["$key"]="${value:=$key}"
  done < "${TARGET_ENVELOPE_NON_BOOTSTRAP}"

  unset TARGET_ENVELOPE_ALL_CAP_ARR
  declare -g -A TARGET_ENVELOPE_ALL_CAP_ARR
  while IFS=: read -r key value; do
      TARGET_ENVELOPE_ALL_CAP_ARR["$key"]="${value:=$key}"
  done < "${TARGET_ENVELOPE_ALL_CAP}"

  unset TARGET_UC_ONLINE_ARR
  declare -g -A TARGET_UC_ONLINE_ARR
  while IFS=: read -r key value; do
      TARGET_UC_ONLINE_ARR["$key"]="${value:=$key}"
  done < "${TARGET_UC_ONLINE_ALL}"

  unset TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS_ARR
  declare -g -A TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS_ARR
  while IFS=: read -r key value; do
      TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS_ARR["$key"]="${value:=$key}"
  done < "${TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS}"

  unset TARGET_UC_ONLINE_DEPRECATED_PLUGINS_ARR
  declare -g -A TARGET_UC_ONLINE_DEPRECATED_PLUGINS_ARR
  while IFS=: read -r key value; do
      TARGET_UC_ONLINE_DEPRECATED_PLUGINS_ARR["$key"]="${value:=$key}"
  done < "${TARGET_UC_ONLINE_DEPRECATED_PLUGINS}"

  unset TARGET_ENVELOPE_ALL_CAP_WITH_VERSION_ARR
  declare -g -A TARGET_ENVELOPE_ALL_CAP_WITH_VERSION_ARR
  while IFS=: read -r key value; do
      TARGET_ENVELOPE_ALL_CAP_WITH_VERSION_ARR["$key"]=$value
  done < "$TARGET_ENVELOPE_ALL_CAP_WITH_VERSION"

  unset TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR
  declare -g -A TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR
  while IFS=: read -r key value; do
      TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR["$key"]=$value
  done < "$TARGET_UC_ONLINE_ALL_WITH_VERSION"

  unset TARGET_UC_ONLINE_ALL_WITH_URL_ARR
  declare -g -A TARGET_UC_ONLINE_ALL_WITH_URL_ARR
  while IFS=| read -r key value; do
      TARGET_UC_ONLINE_ALL_WITH_URL_ARR["$key"]=$value
  done < "$TARGET_UC_ONLINE_ALL_WITH_URL"

}

staticCheckOfRequiredPlugins() {
  # Static check: loop through plugins and ensure they exist in the downloaded update-center
  debug "Plugins in ${TARGET_UC_ONLINE}:"
  debug "${TARGET_UC_ONLINE_ALL}"
  PLUGINS_MISSING_ONLINE=$(comm -23 "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT}" "${TARGET_UC_ONLINE_ALL}" | xargs)
  [ -z "${PLUGINS_MISSING_ONLINE}" ] || die "PLUGINS_MISSING_ONLINE:${PLUGINS_MISSING_ONLINE}"
}

showSummaryResult() {
cat << EOF
======================= Summary ====================================

  See the new files:
    yq "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG_OFFLINE#${CURRENT_DIR}/}"

  Difference between current vs new plugins.yaml
    diff "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_SANITIZED#${CURRENT_DIR}/}"

  Dependency tree of processed plugins:
    cat "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE#${CURRENT_DIR}/}"

  List of all plugins to be expected on controller after startup:
    cat "${TARGET_PLUGIN_LIST_ALL_EXPECTED#${CURRENT_DIR}/}"

EOF

  if [ -f "$TARGET_PLUGIN_CATALOG_ORIG" ]; then
cat << EOF
  Difference between current vs new plugin-catalog.yaml (if existed)
    diff "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}"

EOF
  fi

  if [ -f "$TARGET_PLUGINS_YAML_MINIMAL" ]; then
cat << EOF
  Minimal plugins.yaml (if existed)
    yq "${TARGET_PLUGINS_YAML_MINIMAL#${CURRENT_DIR}/}"
    diff -y "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_MINIMAL#${CURRENT_DIR}/}"

EOF
  fi
}

isCapPlugin() {
  [[ -n "${TARGET_ENVELOPE_ALL_CAP_ARR[$1]-}" ]]
}

isListed() {
  [[ -n "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT_ARR[$1]-}" ]]
}

isBootstrapPlugin() {
  [[ -n "${TARGET_ENVELOPE_BOOTSTRAP_ARR[$1]-}" ]]
}

isDeprecatedPlugin() {
  [[ -n "${TARGET_UC_ONLINE_DEPRECATED_PLUGINS_ARR[$1]-}" ]]
}

isNotAffectedByCVE() {
  if [ $CHECK_CVES -eq 1 ]; then
    # if no CVEs at all for plugin, return 0
    if ! grep -qE "^${1}$" "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}.txt"; then
      return 0
    fi
    # create plugin specific warning json
    local pWarnings="${CB_UPDATE_CENTER_ACTUAL_WARNINGS}.${1}.json"
    if [ ! -f "$pWarnings" ]; then
      debug "Plugin '$1' - creating security json..."
      jq --arg p "$1" 'select(.name == $p)' "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}" > "${pWarnings}"
    fi
    # go through each security warning
    local pluginVersion=''
    pluginVersion="${TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR[$1]}"
    for w in $(jq -r '.id' "${pWarnings}"); do
      debug "Plugin '$1' - checking security issue '$w'"
      local isAffected=
      for pattern in $(jq --arg w "$w" 'select(.id == $w).versions[].pattern' "${pWarnings}"); do
        patternNoQuotes=${pattern//\"/}
        debug "Plugin '$1' - testing version '$pluginVersion' against pattern '$patternNoQuotes' from file '$pWarnings'"
        if [[ "$pluginVersion" =~ ^($patternNoQuotes)$ ]]; then
          info "Plugin '$1' - affected by '$w' according to pattern '$patternNoQuotes' from file '$(basename $pWarnings)'"
          isAffected=1
        fi
      done
      if [ -n "$isAffected" ]; then
        cp "${pWarnings}" "${TARGET_GEN}"
        return 1
      fi
    done
  fi
}

isDependency() {
  # assumption of dependency:
  # - non bootstrap
  # - found as a dependency of another listed plugin
  isBootstrapPlugin "$1" && return 1 \
    || grep -qE ".* -> $1($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}" && return 0 || return 1
}

isCandidateForRemoval() {
  # assumption: all direct parents are CAP plugins
  local possibleParents=
  possibleParents=$(grep -oE "([a-zA-Z0-9\-]*) -> $1($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}")
  for pp in $(echo "$possibleParents" | sed 's/ -> / /g' | cut -d ' ' -f 1 | sort -u); do
    if ! isCapPlugin "$pp"; then
      return 1
    fi
  done
  return 0
}


addToDeps() {
  local newEntry=$1
  local newKey="${1// */}"
  local curEntry="${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR[$newKey]-}"
  if [[ -n "$curEntry" ]]; then
    debug "Appending $newKey -> $newEntry"
    TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR["$newKey"]=$(printf "${curEntry}\n${newEntry}")
  else
    debug "First time $newKey -> $newEntry"
    TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR["$newKey"]="$newEntry"
  fi
}

processDepTree() {
  local p=$1
  local directPrefix="${2:-}"
  local parentPrefix="${3:-}"
  local depList=
  depList=$(awk -v pat="^${p}:.*" -F':' '$0 ~ pat { print $2 }' $DEPS_FILES | xargs)
  if [[ -n "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$p]-}" ]]; then
    debug "Already processed plugin '$p' ($directPrefix) ($parentPrefix) ($depList)"
    return 0
  fi
  debug "Processing plugin '$p' ($directPrefix) ($parentPrefix) ($depList)"
  if [ -n "$depList" ]; then
    if ! isBootstrapPlugin "$p"; then
      local dep=
      for dep in $depList; do
        if [[ -n "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$dep]-}" ]]; then
          debug "Reusing dep '$dep' ($p)"
          while IFS= read -r line; do
            addToDeps "${parentPrefix}$p -> $line"
          done <<< "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$dep]}"
        else
          debug "Processing dep '$dep' ($p)"
          processDepTree "${dep}" "$p -> " "${parentPrefix}$p -> "
          debug "Processed dep '$dep' ($p)"
        fi
      done
    else
      # echo "${parentPrefix}$p" >> "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}"
      addToDeps "${parentPrefix}$p"
      if [ -n "${directPrefix}" ] && [[ "${parentPrefix}" != "${directPrefix}" ]]; then
        addToDeps "${directPrefix}$p"
      fi
    fi
  else
    # echo "${parentPrefix}$p" >> "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}"
    addToDeps "${parentPrefix}$p"
    if [ -n "${directPrefix}" ] && [[ "${parentPrefix}" != "${directPrefix}" ]]; then
      addToDeps "${directPrefix}$p"
    fi
  fi

  if [[ -n "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR[$p]-}" ]]; then
    info "Finished processing '$p'"
    debug "Dependency tree for '$p' --->
${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR[$p]}"
    TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED["$p"]="${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR[$p]}"
  fi
}

isProcessedDep() {
  [[ -n "${TARGET_PLUGIN_DEPS_PROCESSED_ARR[$1]-}" ]]
}

isProcessedDepNonTopLevel() {
  [[ -n "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR[$1]-}" ]]
}

processDeps() {
  local p=$1
  local indent="${2:-}"
  if ! isProcessedDep "$p"; then
    debug "${indent}Plugin: $p"
    # processed
    echo $p >> "${TARGET_PLUGIN_DEPS_PROCESSED}"
    TARGET_PLUGIN_DEPS_PROCESSED_ARR[$p]="$p"
    # bootstrap plugins
    if isBootstrapPlugin "$p"; then
      if [ $INCLUDE_BOOTSTRAP -eq 1 ]; then
        debug "${indent}Result - add bootstrap: $p"
        echo "  - id: $p" >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
      else
        debug "${indent}Result - ignore: $p (already in bootstrap)"
      fi
    else
      if isCapPlugin "$p"; then
        debug "${indent}Result - add non-bootstrap CAP plugin: $p"
        echo "  - id: $p" >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
      else
        debug "${indent}Result - add third-party plugin: $p"
        echo "  - id: $p" >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
      fi
      for dep in $(awk -v pat="^${p}:.*" -F':' '$0 ~ pat { print $2 }' $DEPS_FILES); do
        # record ALL non-top-level plugins as dependencies for the categorisation afterwards
        if ! isProcessedDepNonTopLevel "$dep"; then
          echo $dep >> "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
          TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR[$dep]="$dep"
        fi
        if isCapPlugin "$p"; then
          debug "${indent}  Dependency: $dep (parent in CAP so no further processing)"
        else
          debug "${indent}  Dependency: $dep"
          processDeps "${dep}" "${indent}  "
        fi
      done
    fi
  else
    debug "${indent}Plugin: $p (already processed)"
  fi
}

processAllDeps() {
  info "Calculating dependencies..."
  # empty the processed lists
  unset TARGET_PLUGIN_DEPS_PROCESSED_ARR
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_ARR
  unset TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR

  echo -n > "${TARGET_PLUGIN_DEPS_PROCESSED}"
  echo -n > "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
  echo "plugins:" > "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"

  # optional deps?
  [ $INCLUDE_OPTIONAL -eq 1 ] && DEPS_FILES="$TARGET_REQUIRED_DEPS $TARGET_OPTIONAL_DEPS" || DEPS_FILES="$TARGET_REQUIRED_DEPS"

  # process deps
  local p=
  for p in $LIST_OF_PLUGINS; do
      processDeps $p
  done
  sort -o "${TARGET_PLUGIN_DEPS_PROCESSED}" "${TARGET_PLUGIN_DEPS_PROCESSED}"
  info "Processing dependency tree..."
  unset TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR
  unset TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED
  for p in $(yq '.plugins[].id' ${TARGET_PLUGIN_DEPENDENCY_RESULTS}); do
    processDepTree "$p"
    echo "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$p]}" >> "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE"
  done
}

createPluginCatalogAndPluginsYaml() {
  # process dependencies
  processAllDeps

  # get the 3rd party plugins by removing all CAP plugins from list of processed dependencies
  NON_CAP_PLUGINS=$(comm -23 "${TARGET_PLUGIN_DEPS_PROCESSED}" "${TARGET_ENVELOPE_ALL_CAP}")

  export descriptionVer="These are Non-CAP plugins for version $CI_VERSION"
  export productVersion="[$CI_VERSION]"
  info "Recreate plugin-catalog"
  local targetFile="${TARGET_PLUGIN_CATALOG}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Plugin Catalog", "configurations": [ { "description": strenv(descriptionVer), "prerequisites": { "productVersion": strenv(productVersion) }, "includePlugins": {}}]}' "${targetFile}"
  for pluginName in $NON_CAP_PLUGINS; do
    info "Adding plugin '$pluginName'"
    pluginVersion="${TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR[$pluginName]}"
    k="$pluginName" v="$pluginVersion" yq -i '.configurations[].includePlugins += { env(k): { "version": env(v) }} | style="double" ..' "${targetFile}"
  done
  info "Recreate OFFLINE plugin-catalog plugins to plugin-cache...($PLUGINS_CACHE_DIR)"
  targetFile="${TARGET_PLUGIN_CATALOG_OFFLINE}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Offline Plugin Catalog", "configurations": [ { "description": strenv(descriptionVer), "prerequisites": { "productVersion": strenv(productVersion) }, "includePlugins": {}}]}' "${targetFile}"
  for pluginName in $NON_CAP_PLUGINS; do
    info "Adding OFFLINE plugin '$pluginName'"
    pluginVersion="${TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR[$pluginName]}"
    # pluginUrl defaults to the official online url
    local pluginUrlOfficial=$(grep "^$pluginName|.*$" "${TARGET_UC_ONLINE_ALL_WITH_URL}" | cut -d'|' -f2)
    if [ -n "${PLUGIN_CATALOG_OFFLINE_URL_BASE:-}" ]; then
      pluginUrl=$(echo "${PLUGIN_CATALOG_OFFLINE_URL_BASE}" | sed -e "s/PNAME/${pluginName}/g" -e "s/PVERSION/${pluginVersion}/g")
    else
      pluginUrl="$pluginUrlOfficial"
    fi

    # if the plugins were downloaded, copy and create an offline plugin catalog
    pluginDest=
    if [ $DOWNLOAD -eq 1 ]; then
      pluginDest="${PLUGINS_CACHE_DIR}/${pluginName}/${pluginVersion}/${pluginUrlOfficial//*\//}"
      # Copy to cache...
      mkdir -p $(dirname "${pluginDest}")
      if [ ! -f "$pluginDest" ]; then
        info "Downloading plugin from ${pluginUrlOfficial} -> ${pluginDest}"
        curl -sL "${pluginUrlOfficial}" -o "${pluginDest}"
      else
        info "Downloading (already exists) plugin from ${pluginUrlOfficial} -> ${pluginDest}"
      fi
    fi

    # Call exec hook if available...
    if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ]; then
      info "Calling exec-hook ${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}..."
      PNAME="$pluginName" PVERSION="$pluginVersion" PFILE="${pluginDest:-}" PURL_OFFICIAL="$pluginUrlOfficial" PURL="$pluginUrl" "$PLUGIN_CATALOG_OFFLINE_EXEC_HOOK"
    fi
    k="$pluginName" u="$pluginUrl" yq -i '.configurations[].includePlugins += { env(k): { "url": env(u) }} | style="double" ..' "${targetFile}"
  done


  #temporarily reformat each file to allow a proper yaml merge
  yq e '.plugins[].id | {.: {}}' "$TARGET_PLUGIN_DEPENDENCY_RESULTS" > $TARGET_GEN/temp0.yaml
  yq e '.plugins[].id | {.: {}}' "$TARGET_PLUGINS_YAML_ORIG_SANITIZED" > $TARGET_GEN/temp1.yaml
  yq e '.configurations[].includePlugins' "$TARGET_PLUGIN_CATALOG" > $TARGET_GEN/temp2.yaml

  #merge our newly found dependencies from the calculated plugin-catalog.yaml into plugins.yaml
  yq ea 'select(fileIndex == 0) * select(fileIndex == 1) * select(fileIndex == 2) | keys | {"plugins": ([{"id": .[]}])}' \
    "${TARGET_GEN}/temp0.yaml" \
    "${TARGET_GEN}/temp1.yaml" \
    "${TARGET_GEN}/temp2.yaml" \
    > "${TARGET_PLUGINS_YAML}" && rm "${TARGET_GEN}/temp"*

  # sanitize the final files for comparing later on
  yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML}"
  yq -i '.configurations[0].includePlugins|=sort_keys(..)|... comments=""' "${TARGET_PLUGIN_CATALOG}"
  cp "${TARGET_PLUGINS_YAML}" "${TARGET_PLUGINS_YAML_SANITIZED}"

  # Add metadata comments
  info "Adding metadata comments..."
  if [ -n "${PLUGIN_YAML_COMMENTS_STYLE}" ]; then
    # Header...
    case "${PLUGIN_YAML_COMMENTS_STYLE}" in
        header|footer|line)
          if [ $CHECK_CVES -eq 1 ]; then
            yq -i '. head_comment="This file is automatically generated - please do not edit manually.\n\nPlugin Categories:\n cap - is this a CAP plugin?\n 3rd - is this a 3rd party plugin?\n old - is this a deprecated plugin?\n cve - are there open security issues?\n bst - installed by default\n dep - installed as dependency\n lst - installed because it was listed"' "$TARGET_PLUGINS_YAML"
          else
            yq -i '. head_comment="This file is automatically generated - please do not edit manually.\n\nPlugin Categories:\n cap - is this a CAP plugin?\n 3rd - is this a 3rd party plugin?\n old - is this a deprecated plugin?\n bst - installed by default\n dep - installed as dependency\n lst - installed because it was listed"' "$TARGET_PLUGINS_YAML"
          fi
          ;;
        none)
          info "Comments style = none. Not setting comments."
          ;;
        *)
          warn "Comments style '${PLUGIN_YAML_COMMENTS_STYLE}' not recognised. Not setting comments."
          ;;
    esac

    # Plugin comments...
    considerForPotentialRemoval=""
    for p in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML"); do
      info "Adding comments for plugin '$p'"
      export pStr=""
      isCapPlugin "$p" && pStr="${pStr} cap" || pStr="${pStr} 3rd"
      isListed "$p" && pStr="${pStr} lst"
      isBootstrapPlugin "$p" && pStr="${pStr} bst"
      isDependency "$p" && pStr="${pStr} dep"
      isDeprecatedPlugin "$p" && pStr="${pStr} old"
      isNotAffectedByCVE "$p" || pStr="${pStr} cve"
      if [[ "$pStr" =~ cap\ lst.*dep ]] && isCandidateForRemoval "$p"; then
        considerForPotentialRemoval="$considerForPotentialRemoval $p "
      elif [[ "$pStr" =~ bst ]]; then
        considerForPotentialRemoval="$considerForPotentialRemoval $p "
      fi
      case "${PLUGIN_YAML_COMMENTS_STYLE}" in
        header)
          p=$p yq -i '.plugins[]|= (select(.id == env(p)).id|key) head_comment=env(pStr)' "$TARGET_PLUGINS_YAML"
          ;;
        footer)
          p=$p yq -i '.plugins[]|= (select(.id == env(p)).id|key) foot_comment=env(pStr)' "$TARGET_PLUGINS_YAML"
          ;;
        line)
          p=$p yq -i '.plugins[]|= (select(.id == env(p)).id|key) line_comment=env(pStr)' "$TARGET_PLUGINS_YAML"
          ;;
      esac
    done

    # list potential removal candidates
    if [ -n "$considerForPotentialRemoval" ]; then
      info "=============================================================="
      info "!!! Candidates for potential removal from the plugins.yaml !!!"
      info "=============================================================="
      info "The following plugins are either bootstrap or dependencies of CAP plugins: $considerForPotentialRemoval"
      info "For more details run: p=<PLUGIN_TO_CHECK>; grep -E \".* -> \$p($| )\" \"${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE#${CURRENT_DIR}/}\""
      for pToCheck in $considerForPotentialRemoval; do
        if isBootstrapPlugin "$pToCheck"; then
          info "  ${pToCheck}: is a bootstrap plugin"
        else
          parentList=$(grep -E ".* -> $pToCheck($| )" "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE" | cut -d' ' -f 1 | sort -u | xargs)
          info "  ${pToCheck}: provided by $parentList"
        fi
      done
    fi
  fi

  # are we currently processing multi-versions?
  if [ -n "${TMP_PLUGIN_CATALOG:-}" ]; then
    tmpStr=$(yq eval-all '. as $item ireduce ({}; . *+ $item )' "$TMP_PLUGIN_CATALOG" "${TARGET_PLUGIN_CATALOG}")
    echo "$tmpStr" > "$TMP_PLUGIN_CATALOG"
    tmpStr=$(yq eval-all '. as $item ireduce ({}; . *+ $item )' "$TMP_PLUGIN_CATALOG_OFFLINE" "${TARGET_PLUGIN_CATALOG_OFFLINE}")
    echo "$tmpStr" > "$TMP_PLUGIN_CATALOG_OFFLINE"
    info "Copying temp (collective) plugin catalog files to the target files."
    cp -v "$TMP_PLUGIN_CATALOG" "${TARGET_PLUGIN_CATALOG}"
    cp -v "$TMP_PLUGIN_CATALOG_OFFLINE" "${TARGET_PLUGIN_CATALOG_OFFLINE}"
  fi

  # let's create a list of ALL EXPECTED PLUGINS found on the controller after startup
  cat \
    "$TARGET_ENVELOPE_BOOTSTRAP" \
    "$TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL" \
    "$TARGET_PLUGIN_DEPS_PROCESSED" \
    | sort -u > "$TARGET_PLUGIN_LIST_ALL_EXPECTED"

  # how about creating a minimal list?
  if [ ${MINIMAL_PLUGIN_LIST} -eq 1 ]; then
    reducedPluginList=$(yq '.plugins[].id' "$TARGET_PLUGINS_YAML")
    removeAllBootstrap
    reducedList=1
    reducePluginList
    cp "${TARGET_PLUGINS_YAML}" "$TARGET_PLUGINS_YAML_MINIMAL"
    for k in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML_MINIMAL"); do
      if ! grep -qE "^$k$" <<< "$reducedPluginList"; then
        debug "Removing '$k' from the TARGET_PLUGINS_YAML_MINIMAL"
        k=$k yq -i 'del(.plugins[] | select(.id == env(k)))' "${TARGET_PLUGINS_YAML_MINIMAL}"
      fi
    done
  fi

  # final target stuff
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH" ] || cp -v "${TARGET_PLUGINS_YAML}" "$FINAL_TARGET_PLUGIN_YAML_PATH"
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL" ] || cp -v "${TARGET_PLUGINS_YAML_MINIMAL}" "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG" ] || cp -v "${TARGET_PLUGIN_CATALOG}" "$FINAL_TARGET_PLUGIN_CATALOG"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE" ] || cp -v "${TARGET_PLUGIN_CATALOG_OFFLINE}" "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE"

}

sortDepsByDepth() {
  local p= matchedLines=
  for p in $1; do
    matchedLines=$(grep -oE ".* -> $p($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}" | sed -e 's/\ $//' | sort -u)
    while IFS= read -r line; do
      echo "$(echo "$line" | awk '{ printf("%02d\n", gsub(" -> ","")); }') $line"
    done <<< "$matchedLines"
  done | sort -r | grep -vE "^00.*" || true
}

reducePluginList() {
  info "Removing dependency plugins from main list..."
  while [ -n "${reducedList:-}" ]; do
    info "Removing dependency plugins - iterating..."
    reducedList=
    depsSortedByDepth=$(sortDepsByDepth "$reducedPluginList")
    debug "====================================="
    debug "========        DEPTH      =========="
    debug "====================================="
    debug "$depsSortedByDepth"
    debug "====================================="
    debug "====================================="
    debug "========        LIST       =========="
    debug "====================================="
    debug "$reducedPluginList"
    debug "====================================="
    while IFS= read -r pluginLineToCheck; do
      # go through the list of parents. if parent found in main list, remove any of its children
      for parentToCheck in $(echo "$pluginLineToCheck" | sed -e 's/^[0-9]* //' -e 's/ -> / /g' -e 's/\ [a-zA-Z0-9\-]*$//'); do
        if [[ -n "${TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS_ARR[$parentToCheck]-}" ]]; then
          debug "Ignoring parent '$parentToCheck' since it is a 3rd party plugin."
          continue
        elif grep -qE "^($parentToCheck)$" <<< "$reducedPluginList"; then
          debug "Found parent '$parentToCheck' in main list. Removing any of it's children..."
          childrenToRemove=$(echo "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$parentToCheck]-}" \
            | sed -e "s/^$parentToCheck -> //" -e 's/ -> /\n/g' \
            | sort -u | xargs)
          # if grep -qE "(^| )$parentToCheck($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}"; then
          #   childrenToRemove=$(grep -E "(^| )$parentToCheck($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}" \
          #     | sed -e "s/^$parentToCheck -> //" -e "s/^.* $parentToCheck -> //" -e 's/ -> /\n/g' \
          #     | sort -u | xargs)
          # fi
          for childToRemove in $childrenToRemove; do
            if grep -qE "^($childToRemove)$" <<< "$reducedPluginList"; then
              if isCapPlugin "$childToRemove"; then
                info "Removing child '$childToRemove' from main list due to parent $parentToCheck..."
                tmpReducedPluginList=$(grep -vE "^$childToRemove$" <<< "$reducedPluginList")
                reducedPluginList=$tmpReducedPluginList
                reducedList=1
              else
                info "Keeping child '$childToRemove' in main list due to being 3rd party (from $parentToCheck)..."
              fi
            fi
          done
          break
        fi
      done
    done <<< "$depsSortedByDepth"
  done
}

removeAllBootstrap() {
  info "Removing bootstrap plugins from main list..."
  for p in $reducedPluginList; do
    if grep -qE "^($p)$" "${TARGET_ENVELOPE_BOOTSTRAP}"; then
      debug "Removing bootstrap '$p' from main list..."
      tmpReducedPluginList=$(grep -vE "^$p$" <<< "$reducedPluginList")
      reducedPluginList="$tmpReducedPluginList"
    fi
  done
}

runMainProgram() {
  setScriptVars
  cacheUpdateCenter
  createTargetDirs
  copyOrExtractMetaInformation
  staticCheckOfRequiredPlugins
  createPluginCatalogAndPluginsYaml
  showSummaryResult
}

checkCIVersions() {
  mkdir -p "${TARGET_BASE_DIR}"
  # default to latest CI Version if not set
  if [ -z "${CI_VERSION:-}" ]; then
    info "CI_VERSION not set. Determining latest version..."
    CB_HELM_REPO_INDEX="${TARGET_BASE_DIR}/helm-chart.index.yaml"
    curl --fail -sSL -o "${CB_HELM_REPO_INDEX}" "${CB_HELM_REPO_URL}"
    LATEST_CHART_VERSION=$(yq '.entries.cloudbees-core[].version' "${CB_HELM_REPO_INDEX}" | sort -rV | head -n 1)
    CI_VERSION=$(cv=$LATEST_CHART_VERSION yq '.entries.cloudbees-core[]|select(.version == env(cv)).appVersion' "${CB_HELM_REPO_INDEX}")
  fi
  [ -n "${CI_VERSION:-}" ] && info "CI_VERSION set to '$CI_VERSION'." || die "CI_VERSION was empty."

  IFS=', ' read -r -a CI_VERSIONS_ARRAY <<< "$CI_VERSION"
  if [ ${#CI_VERSIONS_ARRAY[@]} -gt 1 ]; then
    info "ATTENTION: Comma or space separated CI_VERSION's detected. The COMPLETE plugin-catalog files will be placed in the last version in the list."
    TMP_PLUGIN_CATALOG="${TARGET_BASE_DIR}/plugin-catalog.yaml"
    TMP_PLUGIN_CATALOG_OFFLINE="${TARGET_BASE_DIR}/plugin-catalog-offline.yaml"
    echo -n > "$TMP_PLUGIN_CATALOG"
    echo -n > "$TMP_PLUGIN_CATALOG_OFFLINE"
  fi
}

# main
prereqs
checkCIVersions
for i in $(echo ${!CI_VERSIONS_ARRAY[@]}); do
  CI_VERSION="${CI_VERSIONS_ARRAY[$i]}"
  runMainProgram
done
