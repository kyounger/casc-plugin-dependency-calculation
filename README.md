# CloudBees CasC Plugin Catalog and Transitive Dependencies Calculator

Give this script a path to a `plugins.yaml` file in a bundle with all plugins you want installed (any tier), and it will:

1. Generate the `plugin-catalog.yaml` file for you in the same directory, including all versions and transitive dependencies.
2. Update the `plugins.yaml` file you originally specifed with the additional transitive dependencies.

This means that as long as you are willing to use the plugin versions in the CloudBees Update Centers (which you should be doing), then all you ever need to do is add plugins to the `plugins.yaml` file and this script will handle the rest. No more manually crafting plugin catalogs!

## :information_source: Upcoming removal of war file and docker dependency

This branch will soon use an updated version of the `run.sh` script which no longer uses the war file. The last release including this will be `v1.0.0`.

Removal of the war file dependency brings a number of advantages:

- less network bandwidth
    - no need to download the docker image for modern installations
    - no need to download the war file for traditional installations
- reduced execution time
- easier to integrate into pipelines since the dependency on docker has been removed

### Changes versus the old method

There are no changes in the resulting `plugins.yaml`, `plugin-catalog.yaml`, or `plugin-catalog-offline.yaml` files.

However, since the war file is no longer available, the meta information regarding the "Initial installation wizard" where the option "Install suggested" is given, for example:

```sh
❯ ls -1 target/2.387.2.4/mm/generated/platform-plugins.json*
target/2.387.2.4/mm/generated/platform-plugins.json
target/2.387.2.4/mm/generated/platform-plugins.json.wizard-all.txt
target/2.387.2.4/mm/generated/platform-plugins.json.wizard-non-suggested.txt
target/2.387.2.4/mm/generated/platform-plugins.json.wizard-suggested.txt
```

If it is still needed in the current development, please create an issue to reinstate the option to use the war file.

Otherwise it is strongly recommended to use the new version.

## New Features

- **multiple CBCI versions** - create a master plugin catalog for multiple CBCI versions
- **multiple source files** - create a master plugin catalog from multiple source files
- **metadata** - option to include metadata as a comment in the `plugins.yaml`
- **final target locations** - option to set specific target locations for final files
- **bootstrap or optional plugins** - improved plugin dependency management for more accurate `plugins.yaml`
    - include optional dependencies per flag
    - include bootstrap dependencies per flag
- **exec hooks** - ability to run `exec-hooks` for plugin post-processing
    - ability to create air-gapped `plugin-catalog-offline.yaml` files
- **simple cache** - rudimentary plugin-cache for holding plugins without an artifact repository manager

## Requirements

- docker (only for the v0.x branch)
- awk
- jq
- yq (v4)
- curl

## Usage

```mono
Usage: run.sh -v <CI_VERSION> [OPTIONS]

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
                    e.g. 'http://plugin-catalog/plugins/$PNAME/$PVERSION'
                    defaults to the official url of the plugin
    -e FILE     Exec-hook - script to call when processing 3rd party plugins
                    script will have access env vars PNAME, PVERSION, PURL, PFILE
                    can be used to automate the uploading of plugins to a repository manager
                    see examples under examples/exec-hooks

    -i          Include optional dependencies in the plugins.yaml
    -I          Include bootstrap dependencies in the plugins.yaml
    -m STYLE    Include plugin metadata as comment (line, header, footer, none)
                    defaults to 'line'
    -S          Disable CVE check against plugins (added to metadata)

    -r          Refresh the downloaded wars/jars (no-cache)
    -R          Refresh the downloaded update center jsons (no-cache)
    -V          Verbose logging (for debugging purposes)
```

## Plugin Metadata

This tool now provides metadata to the `plugins.yaml` giving more context to the included plugins.

Metadata is added in the form of comments. These can be added above, below, or on the same line as the plugin.

### File header

The file now comes with a header describing the categories.

```yaml
❯ yq target/2.375.1.1/mm/my-plugins.yaml
# This file is automatically generated - please do not edit manually.

# Plugin Categories:
#  cap - is this a CAP plugin?
#  3rd - is this a 3rd party plugin?
#  old - is this a deprecated plugin?
#  cve - are there open security issues?
#  bst - installed by default
#  dep - installed as dependency
#  lst - installed because it was listed
```

### Comment style - `line`

Comments are placed behind the plugin.

```yaml
plugins:
  - id: code-coverage-api # 3rd lst
  - id: commons-lang3-api # cap dep
  - id: ec2 # cap lst
  - id: hashicorp-vault-plugin # 3rd lst cve
```

### Comment style - `header`

Comments are placed above the plugin.

```yaml
plugins:
  - # 3rd lst
    id: code-coverage-api
  - # cap dep
    id: commons-lang3-api
  - # cap lst
    id: ec2
  - # 3rd lst cve
    id: hashicorp-vault-plugin
```

### Comment style - `footer`

Comments are placed below the plugin.

```yaml
plugins:
  - id: code-coverage-api
    # 3rd lst
  - id: commons-lang3-api
    # cap dep
  - id: ec2
    # cap lst
  - id: hashicorp-vault-plugin
    # 3rd lst cve
```

## Unnecessary Plugins Check

The script will check for superfluous plugins which are already installed by another plugin in the list.

:warning: You still need to decide whether your situation requires the plugin explicitly. Do not simple remove plugins blindly.

The log will look something like this:

```text
INFO: ==============================================================
INFO: !!! Candidates for potential removal from the plugins.yaml !!!
INFO: ==============================================================
INFO: The following plugins are dependencies of CAP plugins:  aws-credentials  aws-java-sdk-ec2  aws-java-sdk-minimal  branch-api  cloudbees-casc-items-api  cloudbees-casc-items-commons  git  git-client  github-api  mina-sshd-api-common  mina-sshd-api-core  mina-sshd-api-sftp  pipeline-graph-analysis  pipeline-groovy-lib  pipeline-input-step  pipeline-rest-api  pipeline-stage-tags-metadata  workflow-basic-steps  workflow-multibranch 
INFO: For more details run: p=<PLUGIN_TO_CHECK>; grep -E ".* -> $p($| )" "target/2.401.2.3/mm/generated/deps-processed-tree-single.txt"
INFO:   aws-credentials provided by: infradna-backup
INFO:   aws-java-sdk-ec2 provided by: aws-credentials infradna-backup
INFO:   aws-java-sdk-minimal provided by: aws-credentials aws-java-sdk-ec2 infradna-backup
INFO:   branch-api provided by: pipeline-model-definition workflow-multibranch
```

The command given given for more detail looks like:

```text
❯ p=aws-credentials; grep -E ".* -> $p($| )" "target/2.401.2.3/mm/generated/deps-processed-tree-single.txt"
infradna-backup -> aws-credentials -> aws-java-sdk-ec2 -> aws-java-sdk-minimal -> apache-httpcomponents-client-4-api
infradna-backup -> aws-credentials -> aws-java-sdk-ec2 -> aws-java-sdk-minimal -> jackson2-api -> javax-activation-api
infradna-backup -> aws-credentials -> aws-java-sdk-ec2 -> aws-java-sdk-minimal -> jackson2-api -> jaxb -> javax-activation-api
...
...
```

## Tests

Please see the [tests page](./tests/README.md) for details on how to run and create tests.

## Examples

A single run with the plugins.yaml file in the same directory as `run.sh`. This creates `plugin-catalog.yaml`:

`./run.sh -v 2.263.4.2`

A single run with a specified path to plugins.yaml file, but using the `-x` option to turn on the "inplace update". This will overwrite the `plugins.yaml` and `plugin-catalog.yaml` files.

`./run.sh -v 2.263.4.2 -f /path/to/plugins.yaml -x`

Multiple runs taking advantage of caching and generating multiple different `plugin-catalogs.yaml` and updating their corresponding `plugins.yaml`:

``` bash
./run.sh -v 2.263.1.2 -f /bundle1/plugins.yaml -x
./run.sh -v 2.263.4.2 -f /bundle2/plugins.yaml -x
./run.sh -v 2.263.4.2 -f /bundle3/plugins.yaml -x
./run.sh -v 2.277.1.2 -f /bundle4/plugins.yaml -x
```

## Notes

- This will NOT update your `plugins.yaml` file unless you specify the `-x` flag.
- This process caches all resources that it fetches under a `.cache` directory in the PWD. It caches multiple versions of the artifacts to enable re-running with different CI_VERSION.
    - `jenkins.war` from the docker image
    - `jenkins-plugin-manager.jar` download from github releases
    - `update-center.json` is cached from the UC download (this can reduce network traffic and delay if wanting to run this subseqently against multiple different `plugins.yaml`s.

## Advanced

**WARNING:** this should no longer be necessary, and could in fact lead to incorrect results. Use with caution.

These two settings are adjustable by exporting them in the shell prior to running. This, for example, is running the process again the client master UC and docker image. *Note that caching does not handle changing this on subseqent runs!*

```bash
export CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-cm"
export CB_DOCKER_IMAGE="cloudbees/cloudbees-core-cm"
```

## TODO

- [x] Generate the updated `plugins.yaml` file that includes the additional transitive dependencies.
- [x] Put in some examples
- [x] Consider parameterizing the CI_VERSION. This would require checking the version of the war/UC that is cached and potentially invalidating those artifacts prior to running.
- [x] Put time into a PR for PIMT that allows it to have structured output to avoid the use of `sed` in processing its output.
- [x] Update the README to reflect the new script functionality.
- [x] Add the ability to create a `plugin-catalog.yaml` for an air-gapped installation.
