set -euo pipefail

CI_VERSION="2.263.4.2"
CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-mm"
CB_DOCKER_IMAGE="cloudbees/cloudbees-core-mm"
# CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-oc"
# CB_DOCKER_IMAGE="cloudbees/cloudbees-cloud-core-oc"

#reformat plugins list to be compatible with pimt
yq e '.plugins[] | [{"artifactId": .[]}] | {"plugins": .}' plugins.yaml > pimt-plugins.yaml

#use docker to extract war file from cb image and cache it
if [[ -f jenkins.war ]]; then
  echo "jenkins.war already exist in the pwd, remove it if you need to refresh" >&2
else
  docker run -ti -v $(pwd):/war --user root --entrypoint "" $CB_DOCKER_IMAGE:$CI_VERSION cp /usr/share/jenkins/jenkins.war /war
fi

#cache PIMT
if [[ -f jenkins-plugin-manager.jar ]]; then
  echo "jenkins-plugin-manager.jar already exist in the pwd, remove it if you need to refresh" >&2
else
  JAR_URL=$(curl -sL \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
    | jq -r '.assets[0].browser_download_url')

  curl -sL $JAR_URL > jenkins-plugin-manager.jar 
fi

#cache the UC locally (we use update-center.json as the file because that's what PIMT expects)
if [[ -f update-center.json ]]; then
  echo "update-center.json already exist in the pwd, remove it if you need to refresh" >&2
else
  curl -sL "$CB_UPDATE_CENTER/update-center.json?version=$CI_VERSION" > update-center.json
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
java -jar jenkins-plugin-manager.jar \
  --war jenkins.war \
  --list \
  --no-download \
  --jenkins-update-center "file://$(pwd)" \
  --plugin-file pimt-plugins.yaml \
  | sed -n '/^Plugins\ that\ will\ be\ downloaded\:$/,/^Resulting\ plugin\ list\:$/p' \
  | sed '1d' | sed '$d' | sed '$d' \
  | sed 's/ /: {version: "/g' \
  | sed -e 's/.*/    &"}/'
