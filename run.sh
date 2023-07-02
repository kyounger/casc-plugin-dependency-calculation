#!/usr/bin/env bash

set -euo pipefail

# Initialize our own variables:
INDENT_SPACING='  '
STDERR_LOG_SUFFIX='.stderr.log'
CHECK_CVES=1
INCLUDE_BOOTSTRAP=0
INCLUDE_OPTIONAL=0
DOWNLOAD=0
VERBOSE_LOG=0
REFRESH=0
REFRESH_UC=0
DEDUPLICATE_PLUGINS="${DEDUPLICATE_PLUGINS:-0}"
CI_VERSION=
CI_TYPE=mm
PLUGIN_YAML_PATHS_FILES=()
PLUGIN_YAML_PATHS_IDX=0
PLUGIN_YAML_PATH="plugins.yaml"
PLUGIN_CATALOG_OFFLINE_EXEC_HOOK=''
PLUGIN_YAML_COMMENTS_STYLE=line
CURRENT_DIR=$(pwd)
TARGET_BASE_DIR=${TARGET_BASE_DIR:="${CURRENT_DIR}/target"}
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
    -c FILE     Final target of the resulting plugin-catalog.yaml
    -C FILE     Final target of the resulting plugin-catalog-offline.yaml

    -d          Download plugins and create a plugin-catalog-offline.yaml with URLs
    -D STRING   Offline pattern or set PLUGIN_CATALOG_OFFLINE_URL_BASE
                    e.g. 'http://plugin-catalog/plugins/\$PNAME/\$PVERSION'
                    defaults to the official url of the plugin
    -e FILE     Exec-hook - script to call when processing 3rd party plugins
                    script will have access env vars PNAME, PVERSION, PURL, PFILE
                    can be used to automate the uploading of plugins to a repository manager
                    see examples under examples/exec-hooks

    -i          Include optional dependencies in the plugins.yaml
    -I          Include bootstrap dependencies in the plugins.yaml
    -m STYLE    Include plugin metadata as comment (line, header, footer, none)
                    defaults to '$PLUGIN_YAML_COMMENTS_STYLE'
    -S          Disable CVE check against plugins (added to metadata)

    -r          Refresh the downloaded wars/jars (no-cache)
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

while getopts iIhv:xf:F:c:C:m:MrRSt:VdD:e: opt; do
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
        r)  REFRESH=1
            ;;
        R)  REFRESH_UC=1
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
  [ $VERBOSE_LOG -eq 0 ] || cat <<< "DEBUG: $@" 1>&2
}

# echo to stderr so as to send it to null if needed
echoerr() {
  cat <<< "$@" 1>&2
}

# echo to stderr
info() {
  cat <<< "INFO: $@" 1>&2
}

# echo to stderr
warn() {
  cat <<< "WARN: $@" 1>&2
}

# echo to stderr and exit 1
die() {
  cat <<< "ERROR: $@" 1>&2
  exit 1
}

extractAndFormat() {
  cat "${1}" | sed 's/.*\post(//' | sed 's/);\w*$//' | jq .
}

cachePimtJar() {
  mkdir -p $PIMT_JAR_CACHE_DIR
  PIMT_INFO_JSON=$(curl --fail -sL \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest)
  PIMT_JAR_FILE=$(echo "$PIMT_INFO_JSON" | yq e '.assets[0].name' -)
  PIMT_JAR_URL=$(echo "$PIMT_INFO_JSON" | yq e '.assets[0].browser_download_url' -)
  PIMT_JAR_CACHE_FILE="$PIMT_JAR_CACHE_DIR/$PIMT_JAR_FILE"

  #download pimt jar file and cache it
  if [[ -f "$PIMT_JAR_CACHE_FILE" ]] && [ $REFRESH -eq 0 ]; then
    info "$(basename "$PIMT_JAR_CACHE_FILE") already exist, remove it or use the '-r' flag" >&2
  else
    info "Caching PIMT JAR to '$PIMT_JAR_CACHE_FILE'"
    curl --fail -sSL -o "$PIMT_JAR_CACHE_FILE" $PIMT_JAR_URL
  fi
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
  [[ "$CI_TYPE" =~ ^mm|oc|cm|oc-traditional$ ]] || die "CI_TYPE '${CI_TYPE}' not recognised"
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
  PIMT_JAR_CACHE_DIR="$CACHE_BASE_DIR/pimt-jar"
  PLUGINS_CACHE_DIR="$CACHE_BASE_DIR/plugins"

  # final location stuff
  FINAL_TARGET_PLUGIN_YAML_PATH="${FINAL_TARGET_PLUGIN_YAML_PATH:-}"
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

  TARGET_PLUGIN_DEPS_PROCESSED="${TARGET_GEN}/deps-processed.txt"
  TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE="${TARGET_GEN}/deps-processed-tree-single.txt"
  TARGET_PLUGIN_DEPS_PROCESSED_TREE_INDENTED_MULTILINE="${TARGET_GEN}/deps-processed-tree-multiline.txt"
  TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL="${TARGET_GEN}/deps-processed-non-top-level.txt"
  TARGET_PLUGIN_DEPENDENCY_RESULTS="${TARGET_GEN}/processed-deps-results.yaml"
  TARGET_NONE="${TARGET_GEN}/pimt-without-plugins.yaml"
  TARGET_ALL="${TARGET_GEN}/pimt-with-plugins.yaml"
  TARGET_DIFF="${TARGET_GEN}/pimt-diff.yaml"
  TARGET_UC_ACTUAL="${TARGET_GEN}/update-center.actual.json"
  TARGET_UC_ACTUAL_WARNINGS="${TARGET_UC_ACTUAL}.plugins.warnings.json"
  TARGET_UC_ONLINE="${TARGET_GEN}/update-center-online.json"
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
  TARGET_PLUGINS_DIR="${TARGET_GEN}/plugins"
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
  yq '.plugins[].id' "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}" > "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT}"
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
  jq -r '.envelope.plugins[]|select(.scope|test("(bootstrap)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.bootstrap.txt"
  jq -r '.envelope.plugins[]|select(.scope|test("(fat)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.non-bootstrap.txt"
  jq -r '.envelope.plugins[]|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.all.txt"
  jq -r '.plugins[]|.name' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.plugins.all.txt"
  jq -r '.plugins[]|"\(.name):\(.dependencies[]|select(.optional == false)|.name)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_REQUIRED_DEPS}"
  jq -r '.plugins[]|"\(.name):\(.dependencies[]|select(.optional == true)|.name)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_OPTIONAL_DEPS}"
  jq -r '.envelope.plugins[]|"\(.artifactId):\(.version)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.all-with-version.txt"
  jq -r '.plugins[]|"\(.name):\(.version)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_ALL_WITH_VERSION}"
  jq -r '.envelope.plugins[]|select(.tier|test("(compatible)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.compatible.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(proprietary)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.proprietary.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(verified)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.verified.txt"
  jq -r '.plugins[]|select((.labels != null) and (.labels[]|index("deprecated")) != null).name' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_DEPRECATED_PLUGINS}"
  comm -13 "${TARGET_UC_ONLINE}.envelope.all.txt" "${TARGET_UC_ONLINE}.plugins.all.txt" \
    > "${TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS}"
}

staticCheckOfRequiredPlugins() {
  # Static check: loop through plugins and ensure they exist in the downloaded update-center
  debug "Plugins in ${TARGET_UC_ONLINE}:"
  debug "$(jq -r '.plugins[].name' "${TARGET_UC_ONLINE}" | sort)"
  PLUGINS_MISSING_ONLINE=''
  for p in $LIST_OF_PLUGINS; do
    # do not use 'grep -q' to avoid the "The Infamous SIGPIPE Signal" http://www.tldp.org/LDP/lpg/node20.html
    jq -r '.plugins[].name' "${TARGET_UC_ONLINE}" | grep -E "^${p}$" &> /dev/null \
    || { [ $? -eq 1 ] && PLUGINS_MISSING_ONLINE="${PLUGINS_MISSING_ONLINE} ${p}" || die "Plugin grep search failed somehow. bash -x to see..."; }
  done
  [ -z "${PLUGINS_MISSING_ONLINE}" ] || die "PLUGINS_MISSING_ONLINE:${PLUGINS_MISSING_ONLINE}"
}

createPluginListsWithPIMT() {
  #run PIMT and reformat output to get the variable part
  if [ -z "${JENKINS_UC_HASH_FUNCTION:-}" ]; then
    export JENKINS_UC_HASH_FUNCTION="SHA1"
    warn "Using the deprecated JENKINS_UC_HASH_FUNCTION=$JENKINS_UC_HASH_FUNCTION for backwards compatibility. Try setting to SHA256 for better security, or set explicitly to SHA1 to remove this message."
  fi
  [ $VERBOSE_LOG -eq 0 ] && PIMT_VERBOSE= || PIMT_VERBOSE=--verbose
  [ $DOWNLOAD -eq 0 ] && PIMT_DOWNLOAD=--no-download || PIMT_DOWNLOAD="-d $TARGET_PLUGINS_DIR"

  PIMT_OPTIONS=(
    -jar "$PIMT_JAR_CACHE_FILE" \
    --list \
    --view-security-warnings \
    $PIMT_DOWNLOAD \
    --jenkins-version $CI_VERSION \
    --output YAML \
    --jenkins-update-center "${CB_UPDATE_CENTER_URL}" \
    $PIMT_VERBOSE)

  info "Getting default plugins list (${TARGET_NONE})"
  info "Running command... java ${PIMT_OPTIONS[@]}"
  if java "${PIMT_OPTIONS[@]}" > "${TARGET_NONE}" 2> "${TARGET_NONE}${STDERR_LOG_SUFFIX}"; then
    debug "$(cat "${TARGET_NONE}${STDERR_LOG_SUFFIX}")"
  else
    cat "${TARGET_NONE}${STDERR_LOG_SUFFIX}"
    die "Couldn't create list of plugins. See above."
  fi

  info "Getting default plugins list after including plugins (${TARGET_ALL})"
  # NOTE: if you don't specify the plugin versions, it will try to process the latest
  local LIST_OF_PLUGINS_WITH_VERSIONS=
  for p in $LIST_OF_PLUGINS; do
    LIST_OF_PLUGINS_WITH_VERSIONS="${LIST_OF_PLUGINS_WITH_VERSIONS} $(grep "^$p:.*$" "${TARGET_UC_ONLINE_ALL_WITH_VERSION}")"
  done
  if java "${PIMT_OPTIONS[@]}" --plugins $(echo "$LIST_OF_PLUGINS_WITH_VERSIONS" | xargs) > "${TARGET_ALL}" 2> "${TARGET_ALL}${STDERR_LOG_SUFFIX}"; then
    debug "$(cat "${TARGET_ALL}${STDERR_LOG_SUFFIX}")"
  else
    cat "${TARGET_ALL}${STDERR_LOG_SUFFIX}"
    die "Couldn't create list of plugins. See above."
  fi

  info "Generating diff by removing all bundled plugins (${TARGET_DIFF})"
  cp "${TARGET_ALL}" "${TARGET_DIFF}"
  for k in $(cat "${TARGET_ENVELOPE_ALL_CAP}"); do
    k=$k yq -i 'del(.plugins[] | select(.artifactId == env(k)))' "${TARGET_DIFF}"
  done
  # sanitise pimt result files
  yq -i '.plugins|=sort_by(.artifactId)|... comments=""' "${TARGET_NONE}"
  yq -i '.plugins|=sort_by(.artifactId)|... comments=""' "${TARGET_ALL}"
  yq -i '.plugins|=sort_by(.artifactId)|... comments=""' "${TARGET_DIFF}"

}

showSummaryResult() {
cat << EOF
======================= Summary ====================================

  See the new files:
    yq  "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG_OFFLINE#${CURRENT_DIR}/}"

  Difference between current vs new plugins.yaml
    diff "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}"

  Dependency tree of processed plugins (as single line or indented multiline):
    cat "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE#${CURRENT_DIR}/}"
    cat "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_INDENTED_MULTILINE#${CURRENT_DIR}/}"

EOF

  if [ -f "$TARGET_PLUGIN_CATALOG_ORIG" ]; then
cat << EOF

  Difference between current vs new plugin-catalog.yaml (if existed)
    diff "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}"

EOF
  fi
}

isCapPlugin() {
  grep -qE "^$1$" "${TARGET_ENVELOPE_ALL_CAP}"
}

isListed() {
  grep -qE "^$1$" "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT}"
}

isBootstrapPlugin() {
  grep -qE "^$1$" "${TARGET_ENVELOPE_BOOTSTRAP}"
}

isDeprecatedPlugin() {
  grep -qE "^$1$" "${TARGET_UC_ONLINE_DEPRECATED_PLUGINS}"
}

isNotAffectedByCVE() {
  if [ $CHECK_CVES -eq 1 ]; then
    # retrieve actual json if needed
    if [ ! -f "${TARGET_UC_ACTUAL}" ]; then
      curl --fail -sSL -o "${TARGET_UC_ACTUAL}" "$JENKINS_UC_ACTUAL_URL"
      jq '.warnings[]|select(.type == "plugin")' "${TARGET_UC_ACTUAL}" > "${TARGET_UC_ACTUAL_WARNINGS}"
    fi
    # create plugin specific warning json
    local pWarnings="${TARGET_UC_ACTUAL_WARNINGS}.${1}.json"
    jq --arg p "$1" 'select(.name == $p)' "${TARGET_UC_ACTUAL_WARNINGS}" > "${pWarnings}"
    # go through each security warning
    local pluginVersion=''
    pluginVersion=$(grep "^$1:.*$" "${TARGET_UC_ONLINE_ALL_WITH_VERSION}" | cut -d':' -f 2)
    for w in $(jq -r '.id' "${pWarnings}"); do
      debug "Plugin '$1' - checking security issue '$w'"
      for pattern in $(jq --arg w "$w" 'select(.id == $w).versions[].pattern' "${TARGET_UC_ACTUAL_WARNINGS}"); do
        patternNoQuotes=${pattern//\"/}
        debug "Plugin '$1' - testing version '$pluginVersion' against pattern '$patternNoQuotes' from file '$pWarnings'"
        if [[ "$pluginVersion" =~ ^$patternNoQuotes$ ]]; then
          info "Plugin '$1' - affected by '$w' according to pattern '$patternNoQuotes' from file '$(basename $pWarnings)'"
          return 1
        fi
      done
    done
  fi
}

isDependency() {
  # assumption of dependency:
  # - non bootstrap
  # - found as a dependency of another listed plugin
  isBootstrapPlugin "$1" && return 1 \
    || grep -qE "^$1$" "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
}

processDepTree() {
    local pList=$1
    local indent="${2:-}"
    local parentPrefix="${3:-}"
    for p in $pList; do
      debug "${indent}$p"
      echo "${indent}$p" >> "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_INDENTED_MULTILINE}"
      depList=$(awk -v pat="^${p}:.*" -F':' '$0 ~ pat { print $2 }' $DEPS_FILES | xargs)
      if [ -n "$depList" ]; then
        processDepTree "${depList}" "${indent}${INDENT_SPACING}"  "${parentPrefix}$p -> "
      else
        echo "${parentPrefix}$p" >> "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}"
      fi
    done
}

processDeps() {
    local p=$1
    local indent="${2:-}"
    if ! grep -qE "^$p$" "${TARGET_PLUGIN_DEPS_PROCESSED}"; then
      debug "${indent}Plugin: $p"
      # processed
      echo $p >> "${TARGET_PLUGIN_DEPS_PROCESSED}"
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
          if ! grep -qE "^$dep$" "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"; then
            echo $dep >> "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
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
  # empty the processed lists
  echo -n > "${TARGET_PLUGIN_DEPS_PROCESSED}"
  echo -n > "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
  echo "plugins:" > "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"

  # optional deps?
  [ $INCLUDE_OPTIONAL -eq 1 ] && DEPS_FILES="$TARGET_REQUIRED_DEPS $TARGET_OPTIONAL_DEPS" || DEPS_FILES="$TARGET_REQUIRED_DEPS"

  # process deps
  for p in $LIST_OF_PLUGINS; do
      processDeps $p
  done
  debug "Processing dependency tree:"
  processDepTree "${LIST_OF_PLUGINS}"
}

createPluginCatalogAndPluginsYaml() {
  export descriptionVer="These are Non-CAP plugins for version $CI_VERSION"
  export productVersion="[$CI_VERSION]"
  info "Recreate plugin-catalog"
  local targetFile="${TARGET_PLUGIN_CATALOG}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Plugin Catalog", "configurations": [ { "description": strenv(descriptionVer), "prerequisites": { "productVersion": strenv(productVersion) }, "includePlugins": {}}]}' "${targetFile}"
  for pluginName in $(yq '.plugins[].artifactId' "${TARGET_DIFF}"); do
    pluginVersion=$(k=$pluginName yq '.plugins[]|select(.artifactId == env(k)).source.version' "${TARGET_DIFF}")
    k="$pluginName" v="$pluginVersion" yq -i '.configurations[].includePlugins += { env(k): { "version": env(v) }} | style="double" ..' "${targetFile}"
  done
  info "Recreate OFFLINE plugin-catalog plugins to plugin-cache...($PLUGINS_CACHE_DIR)"
  targetFile="${TARGET_PLUGIN_CATALOG_OFFLINE}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Offline Plugin Catalog", "configurations": [ { "description": strenv(descriptionVer), "prerequisites": { "productVersion": strenv(productVersion) }, "includePlugins": {}}]}' "${targetFile}"
  for pluginName in $(yq '.plugins[].artifactId' "${TARGET_DIFF}"); do
    pluginVersion=$(k=$pluginName yq '.plugins[]|select(.artifactId == env(k)).source.version' "${TARGET_DIFF}")

    # if the plugins were downloaded, copy and create an offline plugin catalog
    pluginDest=
    if [ $DOWNLOAD -eq 1 ]; then
      pluginSrc="$(find "${TARGET_PLUGINS_DIR}" -type f -name "${pluginName}.*pi")"
      pluginFile=$(basename "${pluginSrc}")
      pluginDest="${PLUGINS_CACHE_DIR}/${pluginName}/${pluginVersion}/${pluginFile}"
      # Copy to cache...
      mkdir -p $(dirname "${pluginDest}")
      info "Copying plugin from ${pluginSrc} -> ${pluginDest}"
      cp "${pluginSrc}" "${pluginDest}"
    fi

    # pluginUrl defaults to the official online url
    if [ -n "${PLUGIN_CATALOG_OFFLINE_URL_BASE:-}" ]; then
      pluginUrl=$(PNAME="${pluginName}" PVERSION="${pluginVersion}" eval "echo \"${PLUGIN_CATALOG_OFFLINE_URL_BASE}/${pluginFile}\" 2> /dev/null")
    else
      pluginUrl=$(k=$pluginName jq --arg p "$pluginName" -r '.plugins[$p].url' "${TARGET_UC_ONLINE}")
    fi

    # Call exec hook if available...
    if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ]; then
      info "Calling exec-hook ${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}..."
      PNAME="$pluginName" PVERSION="$pluginVersion" PFILE="$pluginDest" PURL="$pluginUrl" "$PLUGIN_CATALOG_OFFLINE_EXEC_HOOK"
    fi
    k="$pluginName" u="$pluginUrl" yq -i '.configurations[].includePlugins += { env(k): { "url": env(u) }} | style="double" ..' "${targetFile}"
  done

  # process dependencies
  processAllDeps

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
      export pStr=""
      isCapPlugin "$p" && pStr="${pStr} cap" || pStr="${pStr} 3rd"
      isListed "$p" && pStr="${pStr} lst"
      isBootstrapPlugin "$p" && pStr="${pStr} bst"
      isDependency "$p" && pStr="${pStr} dep"
      isDeprecatedPlugin "$p" && pStr="${pStr} old"
      isNotAffectedByCVE "$p" || pStr="${pStr} cve"
      if [[ "$pStr" =~ cap.*dep ]]; then
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
      info "The following plugins are dependencies of CAP plugins: $considerForPotentialRemoval"
      info "For more details run: p=<PLUGIN_TO_CHECK>; grep -E \".* -> \$p($| )\" \"${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE#${CURRENT_DIR}/}\""
      for pToCheck in $considerForPotentialRemoval; do
        parentList=$(grep -E ".* -> $pToCheck($| )" "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE" | cut -d' ' -f 1 | sort -u | xargs)
        info "  ${pToCheck} provided by: $parentList"
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

  # final target stuff
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH" ] || cp -v "${TARGET_PLUGINS_YAML}" "$FINAL_TARGET_PLUGIN_YAML_PATH"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG" ] || cp -v "${TARGET_PLUGIN_CATALOG}" "$FINAL_TARGET_PLUGIN_CATALOG"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE" ] || cp -v "${TARGET_PLUGIN_CATALOG_OFFLINE}" "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE"

}

runMainProgram() {
  setScriptVars
  cachePimtJar
  cacheUpdateCenter
  createTargetDirs
  copyOrExtractMetaInformation
  staticCheckOfRequiredPlugins
  createPluginListsWithPIMT
  createPluginCatalogAndPluginsYaml
  showSummaryResult
}

checkCIVersions() {
  # default to latest CI Version if not set
  if [ -z "${CI_VERSION:-}" ]; then
    info "CI_VERSION not set. Determining latest version..."
    mkdir -p "${TARGET_BASE_DIR}"
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
    echo > "$TMP_PLUGIN_CATALOG"
    echo > "$TMP_PLUGIN_CATALOG_OFFLINE"
  fi
}

# main
prereqs
checkCIVersions
for i in $(echo ${!CI_VERSIONS_ARRAY[@]}); do
  CI_VERSION="${CI_VERSIONS_ARRAY[$i]}"
  runMainProgram
done
