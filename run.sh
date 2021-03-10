set -euo pipefail

CI_VERSION="2.263.4.2"
CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-mm"
CB_DOCKER_IMAGE="cloudbees/cloudbees-core-mm"
# CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-oc"
# CB_DOCKER_IMAGE="cloudbees/cloudbees-cloud-core-oc"

#reformat plugins list to be compatible with pimt
yq e '.plugins[] | [{"artifactId": .[]}] | {"plugins": .}' plugins.yaml > pimt-plugins.yaml

#use docker to extract war file from 
if [[ -f jenkins.war ]]; then
  echo "jenkins.war already exist in the pwd, remove it if you need to refresh"
else
  docker run -ti -v $(pwd):/war --user root --entrypoint "" $CB_DOCKER_IMAGE:$CI_VERSION cp /usr/share/jenkins/jenkins.war /war
fi

#download PIMT
if [[ -f jenkins-plugin-manager.jar ]]; then
  echo "jenkins-plugin-manager.jar already exist in the pwd, remove it if you need to refresh"
else
  JAR_URL=$(curl -sL \
    -H "Accept: application/vnd.github.v3+json" \
    https://api.github.com/repos/jenkinsci/plugin-installation-manager-tool/releases/latest \
    | jq -r '.assets[0].browser_download_url')

  curl -sL $JAR_URL > jenkins-plugin-manager.jar 
fi

#run PIMT
  export JENKINS_UC_HASH_FUNCTION="SHA1" 
  java -jar jenkins-plugin-manager.jar \
      --war jenkins.war \
      --list \
      --no-download \
      --jenkins-update-center "$CB_UPDATE_CENTER" \
      --jenkins-version "$CI_VERSION" \
      --plugin-file pimt-plugins.yaml

