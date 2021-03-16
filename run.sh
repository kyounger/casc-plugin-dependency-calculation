#!/usr/bin/env sh

set -euo pipefail

show_help() {
cat << EOF
Usage: ${0##*/} -v <CI_VERSION> [-f <path/to/plugins.yaml>] [-h] [-x]

    -h          display this help and exit
    -f FILE     path to the plugins.yaml file
    -v          The version of CloudBees CI (e.g. 2.263.4.2)
    -x          Do NOT do an inplace update of plugins.yaml
EOF
}

if [[ ${#} -eq 0 ]]; then
   show_help
   exit 0
fi

# Initialize our own variables:
INPLACE_UPDATE=1
CI_VERSION=
PLUGIN_YAML_PATH="plugins.yaml"

OPTIND=1
# Resetting OPTIND is necessary if getopts was used previously in the script.
# It is a good idea to make OPTIND local if you process options in a function.

while getopts hv:xf: opt; do
    case $opt in
        h)
            show_help
            exit 0
            ;;
        v)  CI_VERSION=$OPTARG
            ;;
        f)  PLUGIN_YAML_PATH=$OPTARG
            ;;
        x)  INPLACE_UPDATE=0
            ;;
        *)
            show_help >&2
            exit 1
            ;;
    esac
done
shift "$((OPTIND-1))"   # Discard the options and sentinel --

#adjustable vars. Will inherit from shell, but default to what you see here.
CB_UPDATE_CENTER=${CB_UPDATE_CENTER:="https://jenkins-updates.cloudbees.com/update-center/envelope-core-mm"}
CB_DOCKER_IMAGE=${CB_DOCKER_IMAGE:="cloudbees/cloudbees-core-mm"}

#calculated vars
CB_UPDATE_CENTER_URL="$CB_UPDATE_CENTER/update-center.json?version=$CI_VERSION"

#cache some stuff locally, sure cache directory exists
CACHE_BASE_DIR=${CACHE_BASE_DIR:="$(pwd)/.cache"}
mkdir -p $CACHE_BASE_DIR

#create a space-delimited list of plugins from plugins.yaml to pass to PIMT
LIST_OF_PLUGINS=$(yq e '.plugins[].id ' $PLUGIN_YAML_PATH | tr "\n" " ")

#use docker to extract war file from cb image and cache it
WAR_CACHE_DIR=$CACHE_BASE_DIR/war/$CI_VERSION
if [[ -f $WAR_CACHE_DIR/jenkins.war ]]; then
  echo "$WAR_CACHE_DIR/jenkins.war already exist, remove it if you need to refresh" >&2
else
  mkdir -p $WAR_CACHE_DIR
  CONTAINER_ID=$(docker create $CB_DOCKER_IMAGE:$CI_VERSION 2>/dev/null) 2>/dev/null
  docker cp $CONTAINER_ID:/usr/share/jenkins/jenkins.war $WAR_CACHE_DIR 2>/dev/null
  docker rm $CONTAINER_ID >/dev/null 2>&1
fi

#cache PIMT jar
PIMT_JAR_CACHE_DIR=$CACHE_BASE_DIR/pimt-jar
if [[ -f $PIMT_JAR_CACHE_DIR/jenkins-plugin-manager.jar ]]; then
  echo "$PIMT_JAR_CACHE_DIR/jenkins-plugin-manager.jar already exist, remove it if you need to refresh" >&2
else
  mkdir -p $PIMT_JAR_CACHE_DIR
  JAR_URL=$(curl -sL \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
    | yq e '.assets[0].browser_download_url' -)

  curl -sL $JAR_URL > $PIMT_JAR_CACHE_DIR/jenkins-plugin-manager.jar 
fi

PLUGIN_YAML_DIR=$(dirname $PLUGIN_YAML_PATH)
PLUGIN_CATALOG_PATH=$(dirname $PLUGIN_YAML_PATH)/plugin-catalog.yaml

#being writing the plugin-catalog
echo "type: plugin-catalog
version: '1'
name: rbac-casc-catalog
displayName: Rbac with casc for preview
configurations:
- description: these are tier3 plugins
  includePlugins:" > $CACHE_BASE_DIR/pc.yaml

#run PIMT and reformat output to get the variable part
export JENKINS_UC_HASH_FUNCTION="SHA1" 
export CACHE_DIR=${CACHE_DIR:="$CACHE_BASE_DIR/jenkins-plugin-management-cli"}
java -jar $PIMT_JAR_CACHE_DIR/jenkins-plugin-manager.jar \
  --war $WAR_CACHE_DIR/jenkins.war \
  --list \
  --no-download \
  --jenkins-update-center "$CB_UPDATE_CENTER_URL" \
  --plugins $LIST_OF_PLUGINS \
  | sed -n '/^Plugins\ that\ will\ be\ downloaded\:$/,/^Resulting\ plugin\ list\:$/p' \
  | sed '1d' | sed '$d' | sed '$d' \
  | sed 's/ /: {version: "/g' \
  | sed -e 's/.*/    &"}/' \
  >> $CACHE_BASE_DIR/pc.yaml

if [ $INPLACE_UPDATE -ne 1 ]; then
  cat $CACHE_BASE_DIR/pc.yaml
  exit
fi

#write the the inplace updated plugin-catalog.yaml
cat $CACHE_BASE_DIR/pc.yaml > $PLUGIN_CATALOG_PATH

#temporarily reformat each file to allow a proper yaml merge
yq e '.plugins[].id | {.: {}}' "$PLUGIN_YAML_PATH" > $CACHE_BASE_DIR/temp1.yaml
yq e '.configurations[].includePlugins' "$PLUGIN_CATALOG_PATH" > $CACHE_BASE_DIR/temp2.yaml

#merge our newly found dependencies from the calculated plugin-catalog.yaml into plugins.yaml
yq ea 'select(fileIndex == 0) * select(fileIndex == 1) | keys | {"plugins": ([{"id": .[]}])}' \
  $CACHE_BASE_DIR/temp1.yaml \
  $CACHE_BASE_DIR/temp2.yaml \
  > $PLUGIN_YAML_PATH
