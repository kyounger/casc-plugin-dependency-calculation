#!/usr/bin/env bash

set -euo pipefail

# Initialize our own variables:
STDERR_LOG_SUFFIX='.stderr.log'
INCLUDE_BOOTSTRAP=0
INCLUDE_OPTIONAL=0
DOWNLOAD=0
VERBOSE_LOG=0
REFRESH=0
REFRESH_UC=0
INPLACE_UPDATE=0
CI_VERSION=
CI_TYPE=mm
PLUGIN_YAML_PATH="plugins.yaml"
PLUGIN_CATALOG_OFFLINE_URL_BASE_DEFAULT='http://plugin-catalog/plugins/$PNAME/$PVERSION'
PLUGIN_CATALOG_OFFLINE_EXEC_HOOK=''

show_help() {
cat << EOF
Usage: ${0##*/} -v <CI_VERSION> [OPTIONS]

    -h          display this help and exit
    -f FILE     path to the plugins.yaml file
    -t          The instance type (oc, oc-traditional, cm, mm)
    -d          Download plugins and create a plugin-catalog-offline.yaml with URLs
    -D          Offline pattern or set PLUGIN_CATALOG_OFFLINE_URL_BASE
                    defaults to $PLUGIN_CATALOG_OFFLINE_URL_BASE_DEFAULT
    -e          Exec-hook - script to call when processing 3rd party plugins
                    script will have access env vars PNAME, PVERSION, PURL, PFILE
                    can be used to automate the uploading of plugins to a repository manager
                    see examples under examples/exec-hooks
    -i          Include optional dependencies in the plugins.yaml
    -I          Include bootstrap dependencies in the plugins.yaml
    -v          The version of CloudBees CI (e.g. 2.263.4.2)
    -V          Verbose logging (for debugging purposes)
    -r          Refresh the downloaded wars/jars (no-cache)
    -R          Refresh the downloaded update center jsons (no-cache)
    -x          Inplace-update of plugins.yaml and plugin-catalog.yaml
EOF
}

if [[ ${#} -eq 0 ]]; then
   show_help
   exit 0
fi

OPTIND=1
# Resetting OPTIND is necessary if getopts was used previously in the script.
# It is a good idea to make OPTIND local if you process options in a function.

while getopts iIhv:xf:rRt:VdD:e: opt; do
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
        f)  PLUGIN_YAML_PATH=$OPTARG
            ;;
        i)  INCLUDE_OPTIONAL=1
            ;;
        I)  INCLUDE_BOOTSTRAP=1
            ;;
        x)  INPLACE_UPDATE=1
            ;;
        r)  REFRESH=1
            ;;
        R)  REFRESH_UC=1
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
  PIMT_JAR_FILE=$(echo $PIMT_INFO_JSON | yq e '.assets[0].name' -)
  PIMT_JAR_URL=$(echo $PIMT_INFO_JSON | yq e '.assets[0].browser_download_url' -)
  PIMT_JAR_CACHE_FILE="$PIMT_JAR_CACHE_DIR/$PIMT_JAR_FILE"

  #download pimt jar file and cache it
  if [[ -f $PIMT_JAR_CACHE_FILE ]] && [ $REFRESH -eq 0 ]; then
    info "$(basename $PIMT_JAR_CACHE_FILE) already exist, remove it or use the '-r' flag" >&2
  else
    curl --fail -sSL -o "$PIMT_JAR_CACHE_FILE" $PIMT_JAR_URL
  fi
}

cacheWarFile() {
  #download war file and cache it
  if [[ -f "${WAR_CACHE_FILE}" ]] && [ $REFRESH -eq 0 ]; then
    info "$(basename ${WAR_CACHE_FILE}) already exist, remove it or use the '-r' flag" >&2
  else
    mkdir -p $WAR_CACHE_DIR
    if [ -n "${CB_WAR_DOWNLOAD_URL:-}" ]; then
      info "Downloading war file from '${CB_WAR_DOWNLOAD_URL}'" >&2
      curl --progress-bar --fail -L -o "${WAR_CACHE_FILE}" "${CB_WAR_DOWNLOAD_URL}"
    elif [ -n "${CB_DOCKER_IMAGE}" ]; then
      info "Pulling docker image '$CB_DOCKER_IMAGE:$CI_VERSION'" >&2
      docker pull $CB_DOCKER_IMAGE:$CI_VERSION
      CONTAINER_ID=$(docker create $CB_DOCKER_IMAGE:$CI_VERSION 2>/dev/null) 2>/dev/null
      docker cp $CONTAINER_ID:/usr/share/jenkins/jenkins.war "${WAR_CACHE_FILE}" 2>/dev/null
      docker rm $CONTAINER_ID >/dev/null 2>&1
    else
      die "Cannot determine war. Exiting"
    fi
  fi
  # extract some metadata files
  for f in envelope.json platform-plugins.json update-center.json; do
    unzip -p "${WAR_CACHE_FILE}" WEB-INF/plugins/$f > "${WAR_CACHE_DIR}/$f"
  done

}

cacheUpdateCenter() {
  #download update-center.json file and cache it
  if [[ -f "${CB_UPDATE_CENTER_CACHE_FILE}" ]] && [ $REFRESH_UC -eq 0 ]; then
    info "$(basename ${CB_UPDATE_CENTER_CACHE_FILE}) already exist, remove it or use the '-R' flag" >&2
  else
    mkdir -p $CB_UPDATE_CENTER_CACHE_DIR
    curl --fail -sSL "${CB_UPDATE_CENTER_URL_WITH_VERSION}" > "${CB_UPDATE_CENTER_CACHE_FILE}"
  fi
}

setScriptVars() {
  # prereqs
  for tool in yq jq docker curl awk; do
    command -v $tool &> /dev/null || die "You need to install $tool"
  done

  # some general sanity checks
  if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK:-}" ]; then
    [ -f "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be a file"
    [ -x "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ] || die "The exec-hook '${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}' needs to be executable"
  fi

  # type based vars
  CB_DOWNLOADS_URL="https://downloads.cloudbees.com/cloudbees-core/traditional"
  case $CI_TYPE in
      mm)
        CB_DOCKER_IMAGE=${CB_DOCKER_IMAGE:="cloudbees/cloudbees-core-mm"}
          ;;
      oc)
        CB_DOCKER_IMAGE=${CB_DOCKER_IMAGE:="cloudbees/cloudbees-cloud-core-oc"}
          ;;
      cm)
        CB_WAR_DOWNLOAD_URL="${CB_DOWNLOADS_URL}/client-master/rolling/war/${CI_VERSION}/cloudbees-core-cm.war"
          ;;
      oc-traditional)
        CB_WAR_DOWNLOAD_URL="${CB_DOWNLOADS_URL}/operations-center/rolling/war/${CI_VERSION}/cloudbees-core-oc.war"
          ;;
      *)
          echo "CI_TYPE '${CI_TYPE}' not recognised" >&2
          exit 1
          ;;
  esac


  #adjustable vars. Will inherit from shell, but default to what you see here.
  CB_UPDATE_CENTER=${CB_UPDATE_CENTER:="https://jenkins-updates.cloudbees.com/update-center/envelope-core-${CI_TYPE}"}
  PLUGIN_CATALOG_OFFLINE_URL_BASE=${PLUGIN_CATALOG_OFFLINE_URL_BASE:=$PLUGIN_CATALOG_OFFLINE_URL_BASE_DEFAULT}
  #calculated vars
  CB_UPDATE_CENTER_URL="$CB_UPDATE_CENTER/update-center.json"
  CB_UPDATE_CENTER_URL_WITH_VERSION="$CB_UPDATE_CENTER/update-center.json?version=$CI_VERSION"

  #cache some stuff locally, sure cache directory exists
  CURRENT_DIR=$(pwd)
  CACHE_BASE_DIR=${CACHE_BASE_DIR:="$(pwd)/.cache"}
  WAR_CACHE_DIR=$CACHE_BASE_DIR/$CI_VERSION/$CI_TYPE/war
  WAR_CACHE_FILE="${WAR_CACHE_DIR}/jenkins.war"
  CB_UPDATE_CENTER_CACHE_DIR=$CACHE_BASE_DIR/$CI_VERSION/$CI_TYPE/update-center
  CB_UPDATE_CENTER_CACHE_FILE="${CB_UPDATE_CENTER_CACHE_DIR}/update-center.json"
  PIMT_JAR_CACHE_DIR=$CACHE_BASE_DIR/pimt-jar
  PLUGINS_CACHE_DIR=$CACHE_BASE_DIR/plugins

  # target base dir
  TARGET_BASE_DIR=${TARGET_BASE_DIR:="$(pwd)/target"}


  #create a space-delimited list of plugins from plugins.yaml to pass to PIMT
  LIST_OF_PLUGINS=$(yq '.plugins[].id ' $PLUGIN_YAML_PATH | xargs)
  PLUGIN_YAML_DIR=$(dirname $PLUGIN_YAML_PATH)
  PLUGIN_CATALOG_PATH=$(dirname $PLUGIN_YAML_PATH)/plugin-catalog.yaml
}

createTargetDirs() {
  # Set target files
  TARGET_DIR="${TARGET_BASE_DIR}/${CI_VERSION}/${CI_TYPE}"
  TARGET_GEN="${TARGET_DIR}/generated"

  TARGET_PLUGIN_DEPS_PROCESSED="${TARGET_GEN}/deps-processed.txt"
  TARGET_PLUGIN_DEPENDENCY_RESULTS="${TARGET_GEN}/processed-deps-results.yaml"
  TARGET_NONE="${TARGET_GEN}/pimt-without-plugins.yaml"
  TARGET_ALL="${TARGET_GEN}/pimt-with-plugins.yaml"
  TARGET_DIFF="${TARGET_GEN}/pimt-diff.yaml"
  TARGET_UC_OFFLINE="${TARGET_GEN}/update-center-offline.json"
  TARGET_UC_ONLINE="${TARGET_GEN}/update-center-online.json"
  TARGET_OPTIONAL_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.optional.txt"
  TARGET_REQUIRED_DEPS="${TARGET_UC_ONLINE}.plugins.all.deps.required.txt"
  BOOTSTRAP=target/2.387.2.3/mm/generated/envelope.json.bootstrap.txt
  TARGET_PLATFORM_PLUGINS="${TARGET_GEN}/platform-plugins.json"
  TARGET_ENVELOPE="${TARGET_GEN}/envelope.json"
  TARGET_ENVELOPE_DIFF="${TARGET_GEN}/envelope.json.diff.txt"
  TARGET_PLUGIN_CATALOG="${TARGET_DIR}/plugin-catalog.yaml"
  TARGET_PLUGIN_CATALOG_OFFLINE="${TARGET_DIR}/plugin-catalog-offline.yaml"
  TARGET_PLUGINS_YAML="${TARGET_DIR}/$(basename $PLUGIN_YAML_PATH)"
  TARGET_PLUGINS_DIR="${TARGET_GEN}/plugins"
  # original files
  TARGET_PLUGINS_YAML_ORIG="${TARGET_PLUGINS_YAML}.orig.yaml"
  TARGET_PLUGIN_CATALOG_ORIG="${TARGET_PLUGIN_CATALOG}.orig.yaml"
  # sanitized files
  TARGET_PLUGINS_YAML_ORIG_SANITIZED="${TARGET_PLUGINS_YAML}.orig.sanitized.yaml"
  TARGET_PLUGIN_CATALOG_ORIG_SANITIZED="${TARGET_PLUGIN_CATALOG}.orig.sanitized.yaml"

  info "Creating target dir (${TARGET_DIR})"
  rm -rf "${TARGET_DIR}"
  mkdir -p "${TARGET_GEN}"
}

copyOrExtractMetaInformation() {
  # save a copy of the original json files
  cp "${PLUGIN_YAML_PATH}" "${TARGET_PLUGINS_YAML_ORIG}"
  # copy again and sanitize (better for comparing later)
  cp "${PLUGIN_YAML_PATH}" "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}"
  yq -i '.plugins|=sort_by(.id)|... comments=""' "${TARGET_PLUGINS_YAML_ORIG_SANITIZED}"
  # same for the plugin-catalog.yaml (if it exists)
  if [ -f "${PLUGIN_CATALOG_PATH}" ]; then
    cp "${PLUGIN_CATALOG_PATH}" "${TARGET_PLUGIN_CATALOG_ORIG}"
    cp "${PLUGIN_CATALOG_PATH}" "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED}"
    yq -i '.configurations[0].includePlugins|=sort_keys(..)|... comments=""' "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED}"
  fi

  # copy meta data json files
  cp "${PLUGIN_YAML_PATH}" "${TARGET_DIR}/"
  unzip -p "${WAR_CACHE_FILE}" WEB-INF/plugins/envelope.json > "${TARGET_ENVELOPE}"
  unzip -p "${WAR_CACHE_FILE}" WEB-INF/plugins/platform-plugins.json > "${TARGET_PLATFORM_PLUGINS}"
  extractAndFormat "${WAR_CACHE_DIR}/update-center.json" > "${TARGET_UC_OFFLINE}"
  extractAndFormat "${CB_UPDATE_CENTER_CACHE_FILE}" > "${TARGET_UC_ONLINE}"

  # check envelope.json from war against envelope.json from update center
  if diff -q <(jq '.envelope' "${TARGET_UC_ONLINE}") <(jq '.' "${TARGET_ENVELOPE}") > "${TARGET_ENVELOPE_DIFF}"; then
    info "No differences found in envelope.json from war vs online update-center."
  elif [ $? -eq 1 ]; then
    warn "Differences found in envelope.json from war vs online update-center. See ${TARGET_ENVELOPE_DIFF}"
  else
    die "Something went wrong. See above..."
  fi

  # extract online envelope json
  jq '.envelope' "${TARGET_UC_ONLINE}" > "${TARGET_UC_ONLINE}.envelope.json"

  # create some info lists from the envelope
  jq -r '.plugins[]|select(.scope|test("(bootstrap)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE}.bootstrap.txt"
  jq -r '.plugins[]|select(.scope|test("(fat)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE}.non-bootstrap.txt"
  jq -r '.plugins[]|select(.scope|test("(bootstrap|fat)"))|.artifactId' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE}.all.txt"
  jq -r '.plugins[]|"\(.artifactId):\(.version)"' \
    "${TARGET_ENVELOPE}" | sort > "${TARGET_ENVELOPE}.all-with-version.txt"

  # create some info lists from the online update-center
  jq -r '.envelope.plugins[]|select(.scope|test("(bootstrap)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.bootstrap.txt"
  jq -r '.envelope.plugins[]|select(.scope|test("(fat)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.non-bootstrap.txt"
  jq -r '.envelope.plugins[]|select(.scope|test("(bootstrap|fat)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.envelope.all.txt"

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
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.plugins.all-with-version.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(compatible)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.compatible.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(proprietary)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.proprietary.txt"
  jq -r '.envelope.plugins[]|select(.tier|test("(verified)"))|.artifactId' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.tier.verified.txt"
  jq -r '.plugins[]|select((.labels != null) and (.labels[]|index("deprecated")) != null).name' \
    "${TARGET_UC_ONLINE}" | sort > "${TARGET_UC_ONLINE}.deprecated.txt"
  comm -13 "${TARGET_UC_ONLINE}.envelope.all.txt" "${TARGET_UC_ONLINE}.plugins.all.txt" \
    > "${TARGET_UC_ONLINE}.tier.3rd-party.txt"

  # create some info lists from the platform-plugins
  jq -r '.[].plugins[]|select(.suggested != null)|.name' \
    "${TARGET_GEN}/platform-plugins.json" | sort > "${TARGET_GEN}/platform-plugins.json.wizard-non-suggested.txt"
  jq -r '.[].plugins[]|select(.suggested == null)|.name' \
    "${TARGET_GEN}/platform-plugins.json" | sort > "${TARGET_GEN}/platform-plugins.json.wizard-suggested.txt"
  jq -r '.[].plugins[]|.name' \
    "${TARGET_GEN}/platform-plugins.json" | sort > "${TARGET_GEN}/platform-plugins.json.wizard-all.txt"
}

staticCheckOfRequiredPlugins() {
  # Static check: loop through plugins and ensure they exist in the downloaded update-center
  debug "Plugins in ${TARGET_UC_OFFLINE}:"
  debug "$(jq -r '.plugins[].name' "${TARGET_UC_OFFLINE}" | sort)"
  debug "Plugins in ${TARGET_UC_ONLINE}:"
  debug "$(jq -r '.plugins[].name' "${TARGET_UC_ONLINE}" | sort)"
  PLUGINS_MISSING_OFFLINE=''
  PLUGINS_MISSING_ONLINE=''
  for p in $LIST_OF_PLUGINS; do
    # do not use 'grep -q' to avoid the "The Infamous SIGPIPE Signal" http://www.tldp.org/LDP/lpg/node20.html
    jq -r '.plugins[].name' "${TARGET_UC_OFFLINE}" | grep -E "^${p}$" &> /dev/null \
    || { [ $? -eq 1 ] && PLUGINS_MISSING_OFFLINE="${PLUGINS_MISSING_OFFLINE} ${p}" || die "Plugin grep search failed somehow. bash -x to see..."; }
    jq -r '.plugins[].name' "${TARGET_UC_ONLINE}" | grep -E "^${p}$" &> /dev/null \
    || { [ $? -eq 1 ] && PLUGINS_MISSING_ONLINE="${PLUGINS_MISSING_ONLINE} ${p}" || die "Plugin grep search failed somehow. bash -x to see..."; }
  done
  [ -z "${PLUGINS_MISSING_ONLINE}" ] || die "PLUGINS_MISSING_ONLINE:${PLUGINS_MISSING_ONLINE}"
  [ -z "${PLUGINS_MISSING_OFFLINE}" ] || warn "PLUGINS_MISSING_OFFLINE:${PLUGINS_MISSING_OFFLINE}"
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
    -jar $PIMT_JAR_CACHE_FILE \
    --war $WAR_CACHE_FILE \
    --list \
    $PIMT_DOWNLOAD \
    --jenkins-version $CI_VERSION \
    --output YAML \
    --jenkins-update-center "${CB_UPDATE_CENTER_URL}" \
    $PIMT_VERBOSE)

  info "Getting default plugins list (${TARGET_NONE})"
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
    LIST_OF_PLUGINS_WITH_VERSIONS="${LIST_OF_PLUGINS_WITH_VERSIONS} $(grep "^$p:.*$" "${TARGET_UC_ONLINE}.plugins.all-with-version.txt")"
  done
  if java "${PIMT_OPTIONS[@]}" --plugins $(echo "$LIST_OF_PLUGINS_WITH_VERSIONS" | xargs) > "${TARGET_ALL}" 2> "${TARGET_ALL}${STDERR_LOG_SUFFIX}"; then
    debug "$(cat "${TARGET_ALL}${STDERR_LOG_SUFFIX}")"
  else
    cat "${TARGET_ALL}${STDERR_LOG_SUFFIX}"
    die "Couldn't create list of plugins. See above."
  fi

  info "Generating diff (${TARGET_DIFF})"
  cp "${TARGET_ALL}" "${TARGET_DIFF}"
  for k in $(yq '.plugins[].artifactId' "${TARGET_NONE}"); do
    k=$k yq -i 'del(.plugins[] | select(.artifactId == env(k)))' "${TARGET_DIFF}"
  done
}

showSummaryResult() {
cat << EOF
Summary:

  Difference between current vs new plugins.yaml
    diff "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}"
    cat "${TARGET_PLUGINS_YAML_ORIG_SANITIZED#${CURRENT_DIR}/}"
    cat "${TARGET_PLUGINS_YAML#${CURRENT_DIR}/}"
EOF

  if [ -f "$TARGET_PLUGIN_CATALOG_ORIG" ]; then
cat << EOF

  Difference between current vs new plugin-catalog.yaml (if existed)
    diff "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED#${CURRENT_DIR}/}" "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}"
    cat "${TARGET_PLUGIN_CATALOG_ORIG_SANITIZED#${CURRENT_DIR}/}"
    cat "${TARGET_PLUGIN_CATALOG#${CURRENT_DIR}/}"
EOF
  fi

  if [ -f "$TARGET_PLUGIN_CATALOG_OFFLINE" ]; then
cat << EOF
  You can find the plugin-catalog-offline.yaml here
    cat "${TARGET_PLUGIN_CATALOG_OFFLINE#${CURRENT_DIR}/}"
EOF
  fi
}

processDeps() {
    local p=$1
    local indent="${2:-}"
    if ! grep -qE "^$p$" "${TARGET_PLUGIN_DEPS_PROCESSED}"; then
        debug "${indent}Plugin: $p"
        # processed
        echo $p >> "${TARGET_PLUGIN_DEPS_PROCESSED}"
        # bootstrap plugins
        if grep -qE "^$p$" "${BOOTSTRAP}"; then
            if [ $INCLUDE_BOOTSTRAP -eq 1 ]; then
                debug "${indent}Result - add bootstrap: $p"
                echo "  - id: $p" >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
            else
                debug "${indent}Result - ignore: $p (already in bootstrap)"
            fi
        else
            debug "${indent}Result - add non-bootstrap: $p"
            echo "  - id: $p" >> "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"
        fi
        # process deps
        for dep in $(awk -v pat="^${p}:.*" -F':' '$0 ~ pat { print $2 }' $DEPS_FILES); do
            debug "${indent}  Dependency: $dep"
            processDeps   "${dep}" "${indent}  "
        done
    else
        debug "${indent}Plugin: $p (already processed)"
    fi
}

processAllDeps() {
  # empty the processed lists
  echo -n > "${TARGET_PLUGIN_DEPS_PROCESSED}"
  echo "plugins:" > "${TARGET_PLUGIN_DEPENDENCY_RESULTS}"

  # optional deps?
  [ $INCLUDE_OPTIONAL -eq 1 ] && DEPS_FILES="$TARGET_REQUIRED_DEPS $TARGET_OPTIONAL_DEPS" || DEPS_FILES="$TARGET_REQUIRED_DEPS"

  # process deps
  for p in $(yq '.plugins[].id' "$TARGET_PLUGINS_YAML_ORIG_SANITIZED"); do
      processDeps $p
  done
}

createPluginCatalogAndPluginsYaml() {
  info "Recreate plugin-catalog"
  # create the plugin catalog
  local targetFile="${TARGET_PLUGIN_CATALOG}"
  touch "${targetFile}"
  yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Plugin Catalog", "configurations": [ { "description": "These are Non-CAP plugins", "includePlugins": {}}]}' "${targetFile}"
  for pluginName in $(yq '.plugins[].artifactId' "${TARGET_DIFF}"); do
    pluginVersion=$(k=$pluginName yq '.plugins[]|select(.artifactId == env(k)).source.version' "${TARGET_DIFF}")
    k="$pluginName" v="$pluginVersion" yq -i '.configurations[].includePlugins += { env(k): { "version": env(v) }} | style="double" ..' "${targetFile}"
  done
  # if the plugins were downloaded, copy and create an offline plugin catalog
  if [ -d "${TARGET_PLUGINS_DIR}" ]; then
    info "Recreate OFFLINE plugin-catalog plugins to plugin-cache...($PLUGINS_CACHE_DIR)"
    targetFile="${TARGET_PLUGIN_CATALOG_OFFLINE}"
    touch "${targetFile}"
    yq -i '. = { "type": "plugin-catalog", "version": "1", "name": "my-plugin-catalog", "displayName": "My Offline Plugin Catalog", "configurations": [ { "description": "These are Non-CAP plugins", "includePlugins": {}}]}' "${targetFile}"
    for pluginName in $(yq '.plugins[].artifactId' "${TARGET_DIFF}"); do
      pluginVersion=$(k=$pluginName yq '.plugins[]|select(.artifactId == env(k)).source.version' "${TARGET_DIFF}")
      pluginSrc="$(find "${TARGET_PLUGINS_DIR}" -type f -name "${pluginName}.*pi")"
      pluginFile=$(basename "${pluginSrc}")
      pluginDest="${PLUGINS_CACHE_DIR}/${pluginName}/${pluginVersion}/${pluginFile}"
      pluginUrl=$(PNAME="${pluginName}" PVERSION="${pluginVersion}" envsubst <<< "${PLUGIN_CATALOG_OFFLINE_URL_BASE}/${pluginFile}")
      # Copy to cache...
      mkdir -p $(dirname "${pluginDest}")
      info "Copying plugin from ${pluginSrc} -> ${pluginDest}"
      cp "${pluginSrc}" "${pluginDest}"
      # Call exec hook if available...
      if [ -n "${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}" ]; then
        info "Calling exec-hook ${PLUGIN_CATALOG_OFFLINE_EXEC_HOOK}..."
        PNAME="$pluginName" PVERSION="$pluginVersion" PFILE="$pluginDest" PURL="$pluginUrl" "$PLUGIN_CATALOG_OFFLINE_EXEC_HOOK"
      fi
      k="$pluginName" u="$pluginUrl" yq -i '.configurations[].includePlugins += { env(k): { "url": env(u) }} | style="double" ..' "${targetFile}"
    done
  fi

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

  # TODO: summary of plugins in plugins.yaml, stating...
  # - tier
  # - adoption status?
  # - release date (YYYYMM)
  # - installation scope:
  #   - installed by default (bootstrap - do we need here then?)
  #   - installed as dependency (are parents part of bootstrapping? are parents in the list? can it be removed?)
  #   - installed just because it is in the list as required (is it needed?)
  # report() { echo "$*"  >> "${TARGET_GEN}/plugin-summary.txt"; }
  # report "##############################"
  # report "####### Plugin Summary #######"
  # report "##############################"
  # for p in $(yq e '.plugins[].id' "${TARGET_PLUGINS_YAML}"); do
  #   pStr="# ${p}"
  #   if grep -E "^${p}$" "${TARGET_GEN}/envelope.json.bootstrap.txt"; then
  #     pStr="${pStr} - CAP PLUGIN (installed by default)"
  #   elif grep -E "^${p}$" "${TARGET_GEN}/envelope.json.non-bootstrap.txt"; then
  #     pStr="${pStr} - CAP PLUGIN (installed by default)"
  #   else
  #   fi
  # done

  # copy if required
  if [ $INPLACE_UPDATE -eq 1 ]; then
    #write the the inplace updated plugin-catalog.yaml
    cp "${TARGET_PLUGINS_YAML}" "$PLUGIN_YAML_PATH"
    cp "${TARGET_PLUGIN_CATALOG}" "$PLUGIN_CATALOG_PATH"
  fi
}

# main
setScriptVars
cachePimtJar
cacheWarFile
cacheUpdateCenter
createTargetDirs
copyOrExtractMetaInformation
staticCheckOfRequiredPlugins
createPluginListsWithPIMT
createPluginCatalogAndPluginsYaml
showSummaryResult
