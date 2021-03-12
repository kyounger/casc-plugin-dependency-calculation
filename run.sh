set -euo pipefail

#adjustable vars
CI_VERSION="2.263.4.2"
CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-mm"
CB_DOCKER_IMAGE="cloudbees/cloudbees-core-mm"

#calculated vars
PLUGIN_YAML_PATH=${1:="plugin.yaml"}
CB_UPDATE_CENTER_URL="$CB_UPDATE_CENTER/update-center.json?version=$CI_VERSION"

#cache some stuff locally
CACHE_BASE_DIR=$(pwd)/.cache
mkdir -p $CACHE_BASE_DIR

#create a space-delimited list of plugins from plugins.yaml to pass to PIMT
LIST_OF_PLUGINS=$(yq e '.plugins[].id ' $PLUGIN_YAML_PATH | tr "\n" " ")

#use docker to extract war file from cb image and cache it
WAR_CACHE_DIR=$CACHE_BASE_DIR/war/$CI_VERSION
if [[ -f $WAR_CACHE_DIR/jenkins.war ]]; then
  echo "$WAR_CACHE_DIR/jenkins.war already exist, remove it if you need to refresh" >&2
else
  mkdir -p $WAR_CACHE_DIR
  docker run -ti -v $WAR_CACHE_DIR:/war --user root --entrypoint "" $CB_DOCKER_IMAGE:$CI_VERSION cp /usr/share/jenkins/jenkins.war /war/jenkins.war
fi

#cache PIMT
PIMT_CACHE_DIR=$CACHE_BASE_DIR/pimt
if [[ -f $PIMT_CACHE_DIR/jenkins-plugin-manager.jar ]]; then
  echo "$PIMT_CACHE_DIR/jenkins-plugin-manager.jar already exist, remove it if you need to refresh" >&2
else
  mkdir -p $PIMT_CACHE_DIR
  JAR_URL=$(curl -sL \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
    | yq e '.assets[0].browser_download_url' -)

  curl -sL $JAR_URL > $PIMT_CACHE_DIR/jenkins-plugin-manager.jar 
fi

#cache the UC locally (we use update-center.json as the file because that's what PIMT expects)
UC_CACHE_DIR=$CACHE_BASE_DIR/uc/$CI_VERSION
if [[ -f $UC_CACHE_DIR/update-center.json ]]; then
  echo "$UC_CACHE_DIR/update-center.json already exist, remove it if you need to refresh" >&2
else
  mkdir -p $UC_CACHE_DIR
  curl -sL "$CB_UPDATE_CENTER_URL" > $UC_CACHE_DIR/update-center.json
fi

#run PIMT and reformat output to get the plugin-catalog.yaml
export JENKINS_UC_HASH_FUNCTION="SHA1" 
echo "type: plugin-catalog
version: '1'
name: rbac-casc-catalog
displayName: Rbac with casc for preview
configurations:
- description: these are tier3 plugins
  includePlugins:"
java -jar $PIMT_CACHE_DIR/jenkins-plugin-manager.jar \
  --war $WAR_CACHE_DIR/jenkins.war \
  --list \
  --no-download \
  --jenkins-update-center "file://$UC_CACHE_DIR" \
  --plugins $LIST_OF_PLUGINS \
  | sed -n '/^Plugins\ that\ will\ be\ downloaded\:$/,/^Resulting\ plugin\ list\:$/p' \
  | sed '1d' | sed '$d' | sed '$d' \
  | sed 's/ /: {version: "/g' \
  | sed -e 's/.*/    &"}/'
