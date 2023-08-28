#!/usr/bin/env bash

set -euo pipefail

# Initialize our own variables:
INDENT_SPACING='  '
ADD_TS="${ADD_TS:-0}"
STDERR_LOG_SUFFIX='.stderr.log'
CHECK_CVES=1
PLUGIN_SOURCE="${PLUGIN_SOURCE:-all}"
INCLUDE_BOOTSTRAP=0
INCLUDE_OPTIONAL=0
DOWNLOAD=0
VERBOSE_LOG=0
REFRESH_UC=0
REFRESH_UC_MINUTES=60
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

# plugin annotations to be added manually
export ANNOTATION_CUSTOM_VERSION_PREFIX="tag:custom:version="
export ANNOTATION_CUSTOM_URL_PREFIX="tag:custom:url="
export ANNOTATION_CUSTOM_REQUIRES_PREFIX="tag:custom:requires="
# special categories added when reducing the plugin list
export CATEGORY_MINIMAL="min"
export CATEGORY_GENERATION_ONLY="gen"

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
    -g FILE     Final target of the resulting plugins-minimal-for-generation-only.yaml
    -G FILE     Final target of the resulting plugins-minimal.yaml

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
    -m STYLE    Include plugin metadata as comment (line, none)
                    defaults to '$PLUGIN_YAML_COMMENTS_STYLE'
    -A          Use 'generation-only' plugins as the source list when calculating dependencies.
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

while getopts AiIhv:xf:F:g:G:c:C:m:MRsSt:VdD:e: opt; do
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
        g)  FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL_GEN=$OPTARG
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
        A)  PLUGIN_SOURCE=gen
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

downloadUpdateCenter() {
  local -r UC_FILE=$1
  local -r UC_DIR=$2
  local -r UC_URL=$3
  if [ "$(find "$UC_FILE" -mmin -"$REFRESH_UC_MINUTES")" ] && [ $REFRESH_UC -eq 0 ]; then
    info "$(basename "${UC_FILE}") is less than $REFRESH_UC_MINUTES minutes old. You can remove it or use the '-R' flag to refresh the cache." >&2
    return 1
  else
    info "Caching UC to '${UC_FILE}'"
    mkdir -p "$UC_DIR"
    curl --fail -sSL -o "${UC_FILE}" "${UC_URL}"
    return 0
  fi
}

cacheUpdateCenter() {
  #download update-center.json file and cache it
  downloadUpdateCenter "$CB_UPDATE_CENTER_CACHE_FILE" "$CB_UPDATE_CENTER_CACHE_DIR" "$CB_UPDATE_CENTER_URL_WITH_VERSION" || true

  [ $CHECK_CVES -eq 1 ] || return 0
  #download update-center.actual.json file and cache it
  if downloadUpdateCenter "$CB_UPDATE_CENTER_ACTUAL" "$CB_UPDATE_CENTER_ACTUAL_CACHE_DIR" "$JENKINS_UC_ACTUAL_URL"; then
    jq '.warnings[]|select(.type == "plugin")' "${CB_UPDATE_CENTER_ACTUAL}" > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}"
    jq -r '.name' "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}" | sort -u > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}.txt"
    jq '.warnings[]|select(.type == "plugin")' "${CB_UPDATE_CENTER_ACTUAL}" > "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}"
    rm -rf "${CB_UPDATE_CENTER_ACTUAL_WARNINGS}."*.json
  fi
}

prereqs() {
  [[ "${BASH_VERSION:0:1}" -lt 4 ]] && die "Bash 3.x is not supported. Please use Bash 4.x or higher."
  for tool in yq jq curl; do
    command -v $tool &> /dev/null || die "You need to install $tool"
  done
  # some general sanity checks
  if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK:-}" ]; then
    [ -f "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be a file"
    [ -x "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be executable"
  fi
  [[ "$CI_TYPE" =~ ^(mm|oc|cm|oc-traditional)$ ]] || die "CI_TYPE '${CI_TYPE}' not recognised"
  [[ "$PLUGIN_SOURCE" =~ ^(all|gen)$ ]] || die "PLUGIN_SOURCE '${PLUGIN_SOURCE}' not recognised. See usage."
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
  FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL_GEN="${FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL_GEN:-}"
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
    # looping through in reverse order since the yq ireduce does not overwrite existing entries.
    for ((i=${#PLUGIN_YAML_PATHS_FILES[@]}-1; i>=0; i--)); do
      local currentPluginYamlPath="${PLUGIN_YAML_PATHS_FILES[$i]}"
      tmpStr=$(yq eval-all '. as $item ireduce ({}; . *+ $item )' "$PLUGIN_YAML_PATH" "${currentPluginYamlPath}")
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

  TARGET_PLUGIN_DEPS_ALL_EXPECTED_POST_STARTUP="${TARGET_GEN}/deps-all-expected-post-startup.txt"
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
  TARGET_UC_ONLINE_ALL_WITH_SHA256="${TARGET_UC_ONLINE}.plugins.all-with-sha256.txt"
  TARGET_UC_ONLINE_ALL_WITH_VERSION="${TARGET_UC_ONLINE}.plugins.all-with-version.txt"
  TARGET_UC_ONLINE_THIRD_PARTY_PLUGINS="${TARGET_UC_ONLINE}.tier.3rd-party.txt"
  TARGET_UC_ONLINE_DEPRECATED_PLUGINS="${TARGET_UC_ONLINE}.deprecated.txt"
  TARGET_OPTIONAL_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.optional.txt"
  TARGET_REQUIRED_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.required.txt"
  TARGET_PLATFORM_PLUGINS="${TARGET_GEN}/platform-plugins.json"
  TARGET_ENVELOPE="${TARGET_UC_ONLINE}.envelope.json"
  TARGET_ENVELOPE_BOOTSTRAP="${TARGET_ENVELOPE}.bootstrap.txt"
  TARGET_ENVELOPE_NON_BOOTSTRAP="${TARGET_ENVELOPE}.non-bootstrap.txt"
  TARGET_ENVELOPE_ALL_CAP="${TARGET_ENVELOPE}.all.txt"
  TARGET_ENVELOPE_ALL_CAP_WITH_VERSION="${TARGET_ENVELOPE}.all-with-version.txt"
  TARGET_PLUGIN_CATALOG="${TARGET_DIR}/plugin-catalog.yaml"
  TARGET_PLUGIN_CATALOG_OFFLINE="${TARGET_DIR}/plugin-catalog-offline.yaml"
  TARGET_PLUGINS_YAML="${TARGET_DIR}/plugins.yaml"
  TARGET_PLUGINS_YAML_MINIMAL="${TARGET_DIR}/plugins-minimal.yaml"
  TARGET_PLUGINS_YAML_MINIMAL_GEN="${TARGET_DIR}/plugins-minimal-for-generation-only.yaml"
  # original files
  TARGET_PLUGINS_YAML_ORIG="${TARGET_PLUGINS_YAML}.orig.yaml"
  TARGET_PLUGIN_CATALOG_ORIG="${TARGET_PLUGIN_CATALOG}.orig.yaml"
  # sanitized files
  TARGET_PLUGINS_YAML_SANITIZED="${TARGET_PLUGINS_YAML}.sanitized.yaml"
  TARGET_PLUGINS_YAML_ORIG_SANITIZED="${TARGET_PLUGINS_YAML}.orig.sanitized.yaml"
  TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT="${TARGET_PLUGINS_YAML_ORIG_SANITIZED}.txt"
  TARGET_PLUGINS_SOURCED_YAML="${TARGET_PLUGINS_YAML}.sourced.yaml"
  TARGET_PLUGINS_SOURCED_YAML_TXT="${TARGET_PLUGINS_SOURCED_YAML}.txt"
  TARGET_PLUGINS_YAML_MINIMAL_SANITIZED="${TARGET_PLUGINS_YAML_MINIMAL}.sanitized.yaml"
  TARGET_PLUGINS_YAML_MINIMAL_GEN_SANITIZED="${TARGET_PLUGINS_YAML_MINIMAL_GEN}.sanitized.yaml"
  TARGET_PLUGIN_CATALOG_ORIG_SANITIZED="${TARGET_PLUGIN_CATALOG}.orig.sanitized.yaml"

  info "Creating target dir (${TARGET_DIR})"
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_GEN}"
}

equalPlugins() {
  diff <(yq '.plugins|sort_by(.id)' "$PLUGIN_YAML_PATH") <(yq '.plugins|unique_by(.id)|sort_by(.id)' "$PLUGIN_YAML_PATH")
}

fillTagArrayFromLine() {
    local tag="$1"
    local tag p comments comment value
    # filter all plugins with tag:custom annotations
    tagSearch="(^| )${tag}(\n| |$)"
    info "Looking in line comment for...$tag"
    for p in $(tagSearch="${tagSearch}" yq -r '.plugins[]|select(.id|line_comment|capture(env(tagSearch))).id' "$PLUGIN_YAML_PATH" | sort -u); do
      info "Setting $p (${tag}${value:-})"
      case "${tag}" in
          "$CATEGORY_GENERATION_ONLY")
            CATEGORY_GENERATION_ONLY_ARR["$p"]="${p}"
            ;;
          "$CATEGORY_MINIMAL")
            CATEGORY_MINIMAL_ARR["$p"]="${p}"
            ;;
          *) die "Tag '${tag}' not recognised." ;;
      esac
    done
}

fillTagArray() {
    local tag="$1"
    local tag p comments comment value
    # filter all plugins with tag:custom annotations
    tagSearch="${tag}.*(\n|$)"
    info "Looking in head comments for...$tag"
    for p in $(tagSearch="${tagSearch}" yq -r '.plugins[]|select(head_comment|capture(env(tagSearch))).id' "$PLUGIN_YAML_PATH" | sort -u); do
      comments=$(tagSearch="${tagSearch}" p=$p yq '.plugins[]|select(.id == env(p))|head_comment|match(env(tagSearch))|.string' "$PLUGIN_YAML_PATH")
      while IFS= read -r comment; do
        value="${comment//${tag}/}"
        if [ -n "$value" ]; then
          info "Setting $p (${tag}${value})"
          case "${tag}" in
              "$ANNOTATION_CUSTOM_VERSION_PREFIX")
                ANNOTATION_CUSTOM_VERSION_PREFIX_ARR["$p"]="${value}"
                ANNOTATION_CUSTOM_PLUGINS_ARR["$p"]="${p}"
                ;;
              "$ANNOTATION_CUSTOM_URL_PREFIX")
                ANNOTATION_CUSTOM_URL_PREFIX_ARR["$p"]="${value}"
                ANNOTATION_CUSTOM_PLUGINS_ARR["$p"]="${p}"
                ;;
              "$ANNOTATION_CUSTOM_REQUIRES_PREFIX")
                ANNOTATION_CUSTOM_REQUIRES_PREFIX_ARR["$p"]="${value}"
                ;;
              *) die "Tag '${tag}' not recognised." ;;
          esac
        fi
      done <<< "${comments}"
    done
}

copyOrExtractMetaInformation() {
  # check all plugins for annotations if needed
  info "Parsing annotations..."

  unset ANNOTATION_CUSTOM_PLUGINS_ARR
  declare -g -A ANNOTATION_CUSTOM_PLUGINS_ARR
  unset ANNOTATION_CUSTOM_VERSION_PREFIX_ARR
  declare -g -A ANNOTATION_CUSTOM_VERSION_PREFIX_ARR
  unset ANNOTATION_CUSTOM_URL_PREFIX_ARR
  declare -g -A ANNOTATION_CUSTOM_URL_PREFIX_ARR
  unset ANNOTATION_CUSTOM_REQUIRES_PREFIX_ARR
  declare -g -A ANNOTATION_CUSTOM_REQUIRES_PREFIX_ARR
  fillTagArray "$ANNOTATION_CUSTOM_VERSION_PREFIX"
  fillTagArray "$ANNOTATION_CUSTOM_URL_PREFIX"
  fillTagArray "$ANNOTATION_CUSTOM_REQUIRES_PREFIX"

  unset CATEGORY_GENERATION_ONLY_ARR
  declare -g -A CATEGORY_GENERATION_ONLY_ARR
  unset CATEGORY_MINIMAL_ARR
  declare -g -A CATEGORY_MINIMAL_ARR
  fillTagArrayFromLine "$CATEGORY_GENERATION_ONLY"
  fillTagArrayFromLine "$CATEGORY_MINIMAL"
  info "Parsing annotations...finished."

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

  # create source list
  case "${PLUGIN_SOURCE}" in
      all)
        LIST_OF_PLUGINS=$(yq '.plugins[].id ' "$TARGET_PLUGINS_YAML_ORIG" | xargs)
        ;;
      gen)
        LIST_OF_PLUGINS="${CATEGORY_GENERATION_ONLY_ARR[@]}"
        ;;
      *) die "Plugin source '${PLUGIN_SOURCE}' not recognised." ;;
  esac
  # caching internally
  unset TARGET_PLUGINS_SOURCED_ARR
  declare -g -A TARGET_PLUGINS_SOURCED_ARR
  for key in $LIST_OF_PLUGINS; do
    TARGET_PLUGINS_SOURCED_ARR["$key"]="$key"
  done
  # let's create the source list yaml
  cp "$TARGET_PLUGINS_YAML_ORIG" "$TARGET_PLUGINS_SOURCED_YAML"
  for p in $(yq '.plugins[].id ' "$TARGET_PLUGINS_SOURCED_YAML" | xargs); do
    isSourced "$p" || p=$p yq -i 'del(.plugins[] | select(.id == env(p)))' "${TARGET_PLUGINS_SOURCED_YAML}"
  done
  yq '.plugins[].id' "${TARGET_PLUGINS_SOURCED_YAML}" | sort > "${TARGET_PLUGINS_SOURCED_YAML_TXT}"

  info "Sanity checking '$PLUGIN_YAML_PATH' for missing custom requirements."
  local missingRequirements=
  for p in "${!ANNOTATION_CUSTOM_REQUIRES_PREFIX_ARR[@]}"; do
    for req in ${ANNOTATION_CUSTOM_REQUIRES_PREFIX_ARR[$p]}; do
      if ! isListed "$req"; then
        warn "Missing custom requirement '$req' (required by '$p')"
        missingRequirements=1
      fi
    done
  done
  [ -z "$missingRequirements" ] || die "Missing requirements, see above."

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
  jq -r '.plugins[]|"\(.name):\(.sha256)"' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE_ALL_WITH_SHA256}"
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
  while IFS=\| read -r key value; do
      TARGET_UC_ONLINE_ALL_WITH_URL_ARR["$key"]=$value
  done < "$TARGET_UC_ONLINE_ALL_WITH_URL"

  if [ -n "${WITH_SHA256:-}" ]; then
    unset TARGET_UC_ONLINE_ALL_WITH_SHA256_ARR
    declare -g -A TARGET_UC_ONLINE_ALL_WITH_SHA256_ARR
    while IFS=: read -r key value; do
        TARGET_UC_ONLINE_ALL_WITH_SHA256_ARR["$key"]=$value
    done < "$TARGET_UC_ONLINE_ALL_WITH_SHA256"
  fi
}

staticCheckOfRequiredPlugins() {
  info "Sanity checking '$PLUGIN_YAML_PATH' for missing online plugins."
  # Static check: loop through plugins and ensure they exist in the downloaded update-center
  debug "Plugins in ${TARGET_UC_ONLINE}:"
  debug "${TARGET_UC_ONLINE_ALL}"
  PLUGINS_MISSING_ONLINE=$(comm -23 "${TARGET_PLUGINS_SOURCED_YAML_TXT}" "${TARGET_UC_ONLINE_ALL}" | xargs)
  local missingPlugins= p=
  for p in $PLUGINS_MISSING_ONLINE; do
    if ! hasCustomAnnotation "$p"; then
      warn "Missing online plugin '$p' which does not have a custom version or URL annotation."
      missingPlugins=1
    fi
  done
  [ -z "${missingPlugins}" ] || die "PLUGINS_MISSING_ONLINE: see above."
}

showSummaryResult() {
cat << EOF
======================= Summary ====================================

  See the new files:
    yq . "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}"
    yq . "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}"
    yq . "${TARGET_PLUGIN_CATALOG_OFFLINE#${CURRENT_DIR}/}"

  Difference between current vs new plugins.yaml
    diff "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_SANITIZED#${CURRENT_DIR}/}"

  Dependency tree of processed plugins:
    cat "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE#${CURRENT_DIR}/}"

  List of all plugins to be expected on controller after startup:
    cat "${TARGET_PLUGIN_DEPS_ALL_EXPECTED_POST_STARTUP#${CURRENT_DIR}/}"

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
  Minimal viable plugins.yaml
    yq . "${TARGET_PLUGINS_YAML_MINIMAL#${CURRENT_DIR}/}"

    Difference: provided list vs minimal viable list:
    diff -y "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_MINIMAL#${CURRENT_DIR}/}"

  Minimal non-viable plugins.yaml (to be used a static starter list)
    yq . "${TARGET_PLUGINS_YAML_MINIMAL_GEN#${CURRENT_DIR}/}"

    Difference: original list vs starter list:
    diff -y "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_MINIMAL_GEN_SANITIZED#${CURRENT_DIR}/}"

    Difference: minimal viable list vs starter list:
    diff -y "${TARGET_PLUGINS_YAML_MINIMAL_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML_MINIMAL_GEN_SANITIZED#${CURRENT_DIR}/}"

EOF
  fi
}

isCapPlugin() {
  [[ -n "${TARGET_ENVELOPE_ALL_CAP_ARR[$1]-}" ]]
}

isListed() {
  [[ -n "${TARGET_PLUGINS_YAML_ORIG_SANITIZED_TXT_ARR[$1]-}" ]]
}

isSourced() {
  [[ -n "${TARGET_PLUGINS_SOURCED_ARR[$1]-}" ]]
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
    || [[ -n "${TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR[$1]-}" ]] \
    || [[ -n "${TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR[$1]-}" ]]
}

isCandidateForRemoval() {
  # assumption: CAP and all direct parents are CAP plugins
  isCapPlugin "$1" && [[ -z "${TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR[$1]-}" ]]
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
  depList=$(sed -n "s/^${p}:\(.*\)/\1/p" "$DEPS_FILES" | xargs)
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
      addToDeps "${parentPrefix}$p"
      if [ -n "${directPrefix}" ] && [[ "${parentPrefix}" != "${directPrefix}" ]]; then
        addToDeps "${directPrefix}$p"
      fi
    fi
  else
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

isAddedToResults() {
  [[ -n "${TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR[$1]-}" ]]
}
processDeps() {
  local p=$1
  local parent="${2:-}"
  local indent="${3:-}"
  # add parent regardless...
  if [ -n "${parent}" ]; then
    if isCapPlugin "$parent"; then
      TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR["$p"]="${TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR[$p]:-} $parent"
    else
      TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR["$p"]="${TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR[$p]:-} $parent"
    fi
    isProcessedDep "$parent" && return
  fi
  if ! isAddedToResults "$p"; then
    debug "${indent}Plugin: $p"
    # bootstrap plugins
    if isBootstrapPlugin "$p"; then
      if [ $INCLUDE_BOOTSTRAP -eq 1 ]; then
        debug "${indent}Result - add bootstrap: $p"
        TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR["$p"]="$p"
      else
        debug "${indent}Result - ignore: $p (already in bootstrap)"
      fi
    else
      if isCapPlugin "$p"; then
        if [ -n "${TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR["$p"]-}" ]; then
          debug "${indent}Result - add non-bootstrap CAP plugin (3rd party parent): $p"
          TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR["$p"]="$p"
        else
          if [ -n "${TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR["$p"]-}" ]; then
            debug "${indent}Result - ignore since parent is already a CAP plugin: $p"
          else
            debug "${indent}Result - add non-bootstrap CAP plugin: $p"
            TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR["$p"]="$p"
          fi
        fi
      else
        debug "${indent}Result - add third-party plugin: $p"
        TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR["$p"]="$p"
      fi
      for dep in $(sed -n "s/^${p}:\(.*\)/\1/p" "$DEPS_FILES" | xargs); do
        # record ALL non-top-level plugins as dependencies for the categorisation afterwards
        if ! isProcessedDepNonTopLevel "$dep"; then
          TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR[$dep]="$dep"
        fi
        debug "${indent}  Dependency: $dep"
        processDeps "${dep}" "$p" "${indent}  "
      done
    fi
    # processed
    TARGET_PLUGIN_DEPS_PROCESSED_ARR[$p]="$p"
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
  unset TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR
  declare -g -A TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR
  unset TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR
  declare -g -A TARGET_PLUGIN_DEPS_NON_CAP_PARENTS_ARR
  unset TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR
  declare -g -A TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR

  # optional deps?
  [ $INCLUDE_OPTIONAL -eq 1 ] && DEPS_FILES="$TARGET_REQUIRED_DEPS $TARGET_OPTIONAL_DEPS" || DEPS_FILES="$TARGET_REQUIRED_DEPS"

  # process deps
  local p=
  for p in $LIST_OF_PLUGINS; do
    info "Processing dependencies of '$p'"
    processDeps $p
  done
  # sort processed into files for later
  printf "%s\n" "${!TARGET_PLUGIN_DEPS_PROCESSED_ARR[@]}" | sort > "${TARGET_PLUGIN_DEPS_PROCESSED}"
  printf "%s\n" "${!TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL_ARR[@]}" | sort > "${TARGET_PLUGIN_DEPS_PROCESSED_NON_TOP_LEVEL}"
  echo "plugins:" > "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
  printf "  - id: %s\n" "${!TARGET_PLUGIN_DEPENDENCY_RESULTS_ARR[@]}" | sort >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
  # yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"

  info "Processing dependency tree..."
  unset TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR
  unset TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED
  declare -g -A TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED
  for p in "${TARGET_PLUGIN_DEPS_PROCESSED_ARR[@]}"; do
    if ! isBootstrapPlugin "$p"; then
      processDepTree "$p"
      echo "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$p]}" >> "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE"
    fi
  done
  sort -o "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE" "$TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE"
}

addEntry() {
  info "Adding plugin '$1' with '$2: $3'"
  k="$1" t="$2" v="$3" yq -i '.configurations[].includePlugins[env(k)]+= { env(t): env(v) } | style="double" ..' "${targetFile}"
}

hasCustomAnnotation() {
  [ -n "${ANNOTATION_CUSTOM_PLUGINS_ARR[$1]-}" ]
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
  # Add the custom plugins first
  local customVersion customUrl
  for pluginName in ${ANNOTATION_CUSTOM_PLUGINS_ARR[@]}; do
    # accounting for custom plugins
    customVersion="${ANNOTATION_CUSTOM_VERSION_PREFIX_ARR[$pluginName]-}"
    customUrl="${ANNOTATION_CUSTOM_URL_PREFIX_ARR[$pluginName]-}"
    if [ -n "$customVersion" ]; then
      addEntry "$pluginName" "version" "$customVersion" "$targetFile"
    elif [ -n "$customUrl" ]; then
      addEntry "$pluginName" "url" "$customUrl" "$targetFile"
    fi
  done
  # Now the other non-cap plugins
  for pluginName in $NON_CAP_PLUGINS; do
    if hasCustomAnnotation "$pluginName"; then
      info "Already processed '$pluginName' with custom plugin above. Ignoring..."
      continue
    fi
    pluginVersion="${TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR[$pluginName]}"
    addEntry "$pluginName" "version" "$pluginVersion" "$targetFile"
    addEntrySha256 "$pluginName" "$targetFile"
  done

  info "Recreate OFFLINE plugin-catalog plugins to plugin-cache...($PLUGINS_CACHE_DIR)"
  targetFile="${TARGET_PLUGIN_CATALOG_OFFLINE}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Offline Plugin Catalog", "configurations": [ { "description": strenv(descriptionVer), "prerequisites": { "productVersion": strenv(productVersion) }, "includePlugins": {}}]}' "${targetFile}"
  # Add the custom plugins first
  for pluginName in ${ANNOTATION_CUSTOM_PLUGINS_ARR[@]}; do
    # accounting for custom plugins
    customUrl="${ANNOTATION_CUSTOM_URL_PREFIX_ARR[$pluginName]-}"
    customVersion="${ANNOTATION_CUSTOM_VERSION_PREFIX_ARR[$pluginName]-}"
    if [ -n "$customUrl" ]; then
      addEntry "$pluginName" "url" "$customUrl" "$targetFile"
    else
      warn "Custom plugin found without a custom url. Falling back to PLUGIN_CATALOG_OFFLINE_URL_BASE"
      pluginUrl=$(echo "${PLUGIN_CATALOG_OFFLINE_URL_BASE}" | sed -e "s/PNAME/${pluginName}/g" -e "s/PVERSION/${customVersion}/g")
      addEntry "$pluginName" "url" "$pluginUrl" "$targetFile"
    fi
  done
  for pluginName in $NON_CAP_PLUGINS; do
    if hasCustomAnnotation "$pluginName"; then
      info "Already processed '$pluginName' with custom plugin above. Ignoring..."
      continue
    fi
    info "Adding OFFLINE plugin '$pluginName'"
    pluginVersion="${TARGET_UC_ONLINE_ALL_WITH_VERSION_ARR[$pluginName]}"
    # pluginUrl defaults to the official online url
    local pluginUrlOfficial="${TARGET_UC_ONLINE_ALL_WITH_URL_ARR[$pluginName]}"
    if [ -n "${PLUGIN_CATALOG_OFFLINE_URL_BASE:-}" ]; then
      pluginUrl=$(echo "${PLUGIN_CATALOG_OFFLINE_URL_BASE}" | sed -e "s/PNAME/${pluginName}/g" -e "s/PVERSION/${pluginVersion}/g")
    else
      pluginUrl="$pluginUrlOfficial"
    fi

    # if the plugins were downloaded, copy and create an offline plugin catalog
    # TODO - do we want to support downloading custom plugins? It would get even messier than now.
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
    # TODO - do we want to support exec-hooks for custom plugins? It would get even messier than now.
    if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ]; then
      info "Calling exec-hook ${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}..."
      PNAME="$pluginName" PVERSION="$pluginVersion" PFILE="${pluginDest:-}" PURL_OFFICIAL="$pluginUrlOfficial" PURL="$pluginUrl" "$PLUGIN_CATALOG_OFFLINE_EXEC_HOOK"
    fi
    addEntry "$pluginName" "url" "$pluginUrl" "$targetFile"
    addEntrySha256 "$pluginName" "$targetFile"
  done


  #temporarily reformat each file to allow a proper yaml merge
  yq e '.plugins[].id | {.: {}}|... comments=""' "$TARGET_PLUGIN_DEPENDENCY_RESULTS" > $TARGET_GEN/temp0.yaml
  yq e '.plugins[].id | {.: {}}|... comments=""' "$TARGET_PLUGINS_SOURCED_YAML" > $TARGET_GEN/temp1.yaml
  yq e '.configurations[].includePlugins|... comments=""' "$TARGET_PLUGIN_CATALOG" > $TARGET_GEN/temp2.yaml

  #merge our newly found dependencies from the calculated plugin-catalog.yaml into plugins.yaml
  yq ea 'select(fileIndex == 0) * select(fileIndex == 1) * select(fileIndex == 2) | keys | {"plugins": ([{"id": .[]}])}' \
    "${TARGET_GEN}/temp0.yaml" \
    "${TARGET_GEN}/temp1.yaml" \
    "${TARGET_GEN}/temp2.yaml" \
    > "${TARGET_PLUGINS_YAML}" && rm "${TARGET_GEN}/temp"*

  # sanitize the final files for comparing later on
  yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML}"
  yq -i '.configurations[0].includePlugins|=sort_keys(..)|... comments=""' "${TARGET_PLUGIN_CATALOG}"
  yq -i '.configurations[0].includePlugins|=sort_keys(..)|... comments=""' "${TARGET_PLUGIN_CATALOG_OFFLINE}"
  cp "${TARGET_PLUGINS_YAML}" "${TARGET_PLUGINS_YAML_SANITIZED}"

  # Add metadata comments
  info "Adding metadata comments..."
  # Header...
  read -r -d '' HEADER <<EOF || true # needed because read returns 1 on stopping
This file is automatically generated - please do not edit manually.

Annotations:
 ${ANNOTATION_CUSTOM_VERSION_PREFIX}...    - sets a custom version
 ${ANNOTATION_CUSTOM_URL_PREFIX}...        - sets a custom url
 ${ANNOTATION_CUSTOM_REQUIRES_PREFIX}...   - specifies any required dependencies

Plugin Categories:
 cap - is this a CAP plugin?
 3rd - is this a 3rd party plugin?
 old - is this a deprecated plugin?
 cve - are there open security issues?
 bst - installed by default
 dep - installed as dependency
 lst - installed because it was listed
 src - used as a source plugin for this list
 min - is part of the viable 'minimal' set of plugins
 gen - is part of the non-viable 'generation-only' set of plugins
EOF

  case "${PLUGIN_YAML_COMMENTS_STYLE}" in
      line)
        HEADER="$HEADER" yq -i '. head_comment=strenv(HEADER)' "$TARGET_PLUGINS_YAML"
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
  declare -A ALL_DEPS_ARR
  local previousHeadComment=
  for p in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML"); do
    debug "Adding comments for plugin '$p'"
    export pStr=""
    isCapPlugin "$p" && pStr="${pStr} cap" || pStr="${pStr} 3rd"
    isListed "$p" && pStr="${pStr} lst"
    isBootstrapPlugin "$p" && pStr="${pStr} bst"
    isDependency "$p" && { pStr="${pStr} dep"; ALL_DEPS_ARR["$p"]="$p"; }
    isDeprecatedPlugin "$p" && pStr="${pStr} old"
    isNotAffectedByCVE "$p" || pStr="${pStr} cve"
    isSourced "$p" && pStr="${pStr} src"
    if [[ "$pStr" =~ cap\ lst.*dep ]] && isCandidateForRemoval "$p"; then
      considerForPotentialRemoval="$considerForPotentialRemoval $p "
    elif [[ "$pStr" =~ bst ]]; then
      considerForPotentialRemoval="$considerForPotentialRemoval $p "
    fi
    case "${PLUGIN_YAML_COMMENTS_STYLE}" in
      line)
        p=$p yq -i '.plugins[]|= (select(.id == env(p)).id|key) line_comment=env(pStr)' "$TARGET_PLUGINS_YAML"
        ;;
    esac
    # reinstate the previous head comments
    previousHeadComment=$(p="$p" yq -r '.plugins[]|select(.id == env(p))|head_comment' "$TARGET_PLUGINS_YAML_ORIG")
    [ -z "$previousHeadComment" ] || p="$p" v="${previousHeadComment}" yq -i 'with(.plugins[]|select(.id == env(p)); . | . head_comment |= strenv(v))' "$TARGET_PLUGINS_YAML"
  done

  # list potential removal candidates
  if [ -n "$considerForPotentialRemoval" ]; then
    info "CANDIDATES FOR REMOVAL: candidates found..."
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
  else
    info "CANDIDATES FOR REMOVAL: Congratulations! There are no candidates for potential removal in your plugins list."
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
    | sort -u > "$TARGET_PLUGIN_DEPS_ALL_EXPECTED_POST_STARTUP"

  # how about creating a minimal list?
  if [ ${MINIMAL_PLUGIN_LIST} -eq 1 ]; then
    reducedPluginList=$(yq '.plugins[].id' "$TARGET_PLUGINS_YAML")
    removeAllBootstrap
    reducedList=1
    info "Removing dependency plugins from main list..."
    reducePluginList
    cp "${TARGET_PLUGINS_YAML}" "$TARGET_PLUGINS_YAML_MINIMAL"
    for k in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML_MINIMAL"); do
      if ! grep -qE "^$k$" <<< "$reducedPluginList"; then
        debug "Removing '$k' from the TARGET_PLUGINS_YAML_MINIMAL"
        k=$k yq -i 'del(.plugins[] | select(.id == env(k)))' "${TARGET_PLUGINS_YAML_MINIMAL}"
      else
        # add the minimal annotation
        for f in "${TARGET_PLUGINS_YAML}" "${TARGET_PLUGINS_YAML_MINIMAL}"; do
          k=$k yq -i 'with(.plugins[]|select(.id == env(k)); . | .id line_comment |= line_comment + " " + env(CATEGORY_MINIMAL))' "${f}"
        done
      fi
    done
    # copy again and sanitize (better for comparing later)
    cp "${TARGET_PLUGINS_YAML_MINIMAL}" "${TARGET_PLUGINS_YAML_MINIMAL_SANITIZED}"
    yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML_MINIMAL_SANITIZED}"

    info "Removing ALL dependency plugins from minimal list to create starter pack..."
    cp "${TARGET_PLUGINS_YAML_MINIMAL}" "$TARGET_PLUGINS_YAML_MINIMAL_GEN"
    for k in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML_MINIMAL_GEN"); do
      if [[ -n "${ALL_DEPS_ARR[$k]-}" ]]; then
        debug "Removing '$k' from the TARGET_PLUGINS_YAML_MINIMAL_GEN"
        k=$k yq -i 'del(.plugins[] | select(.id == env(k)))' "${TARGET_PLUGINS_YAML_MINIMAL_GEN}"
      else
        # add the generation-only annotation
        for f in "${TARGET_PLUGINS_YAML}" "${TARGET_PLUGINS_YAML_MINIMAL}" "${TARGET_PLUGINS_YAML_MINIMAL_GEN}"; do
          k=$k yq -i 'with(.plugins[]|select(.id == env(k)); . | .id line_comment |= line_comment + " " + env(CATEGORY_GENERATION_ONLY))' "${f}"
        done
      fi
    done
    # copy again and sanitize (better for comparing later)
    cp "${TARGET_PLUGINS_YAML_MINIMAL_GEN}" "${TARGET_PLUGINS_YAML_MINIMAL_GEN_SANITIZED}"
    yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML_MINIMAL_GEN_SANITIZED}"
  fi

  # final target stuff
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH" ] || cp -v "${TARGET_PLUGINS_YAML}" "$FINAL_TARGET_PLUGIN_YAML_PATH"
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL" ] || cp -v "${TARGET_PLUGINS_YAML_MINIMAL}" "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL"
  [ -z "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL_GEN" ] || cp -v "${TARGET_PLUGINS_YAML_MINIMAL_GEN}" "$FINAL_TARGET_PLUGIN_YAML_PATH_MINIMAL_GEN"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG" ] || cp -v "${TARGET_PLUGIN_CATALOG}" "$FINAL_TARGET_PLUGIN_CATALOG"
  [ -z "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE" ] || cp -v "${TARGET_PLUGIN_CATALOG_OFFLINE}" "$FINAL_TARGET_PLUGIN_CATALOG_OFFLINE"

}

addEntrySha256() {
  if [ -n "${WITH_SHA256:-}" ]; then
    local pluginSha256="${TARGET_UC_ONLINE_ALL_WITH_SHA256_ARR[$1]}"
    addEntry "$1" "sha256" "$pluginSha256" "$2"
  fi
}

sortDepsByDepth() {
  local p= matchedLines=
  for p in $1; do
    matchedLines=$(grep -oE ".* -> $p($| )" "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE}" | sed -e 's/\ $//' | sort -u)
    while IFS= read -r line; do
      echo "$(printf "%02d" "$(echo "$line" | grep -o " -> " | wc -l)") $line"
    done <<< "$matchedLines"
  done | sort -r | grep -vE "^00.*" || true
}

reducePluginList() {
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
        fi
        if grep -qE "^($parentToCheck)$" <<< "$reducedPluginList"; then
          debug "Found parent '$parentToCheck' in main list. Removing any of it's children..."
          for childToRemove in $(getChildren "$parentToCheck"); do
            if grep -qE "^($childToRemove)$" <<< "$reducedPluginList"; then
              if isCandidateForRemoval "$childToRemove"; then
                debug "Removing child '$childToRemove' from main list due to parent $parentToCheck..."
                removeFromReduceList "$childToRemove"
              else
                debug "Keeping child '$childToRemove' in main list due to having 3rd party parents somewhere..."
              fi
            fi
          done
          break
        fi
      done
    done <<< "$depsSortedByDepth"
  done
  # final cleanup
  info "Removing dependency plugins final cleanup..."
  reducedList=1
  local p=
  while [ -n "${reducedList:-}" ]; do
    reducedList=
    for p in $reducedPluginList; do
      if ! isCapPlugin "$p"; then
        debug "Removing dependency plugins final cleanup - looking at $p..."
        for childToRemove in $(getChildren "$p"); do
          local possibleParents="${TARGET_PLUGIN_DEPS_CAP_PARENTS_ARR[$childToRemove]-}"
          for capParent in $possibleParents; do
            if grep -qE "^($childToRemove)$" <<< "$reducedPluginList" && grep -qE "^($capParent)$" <<< "$reducedPluginList"; then
                info "Removing child '$childToRemove' from main list due to CAP parent $capParent existing..."
                removeFromReduceList "$childToRemove"
                continue
            fi
          done
        done
      fi
    done
  done
}

removeFromReduceList() {
    local tmpReducedPluginList=$(grep -vE "^$1$" <<< "$reducedPluginList")
    reducedPluginList=$tmpReducedPluginList
    reducedList=1
}

getChildren() {
  echo "${TARGET_PLUGIN_DEPS_PROCESSED_TREE_SINGLE_LINE_ARR_FINISHED[$1]-}" \
    | sed -e "s/^$1 -> //" -e 's/ -> /\n/g' \
    | sort -u | xargs
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
for i in "${!CI_VERSIONS_ARRAY[@]}"; do
  CI_VERSION="${CI_VERSIONS_ARRAY[$i]}"
  runMainProgram
done
