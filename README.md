# CloudBees CasC Plugin Catalog and Transitive Dependencies Calculator

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
## Intro

- [Intro](#intro)
- [:information_source: Removal of plugin-installation-manager-tool dependency](#information_source-removal-of-plugin-installation-manager-tool-dependency)
- [Source Plugin Management](#source-plugin-management)
- [New Features](#new-features)
  - [Minimal and Generation-Only Plugins](#minimal-and-generation-only-plugins)
  - [Generation-Only Use Case](#generation-only-use-case)
- [Requirements](#requirements)
- [Usage](#usage)
- [Plugin Metadata](#plugin-metadata)
  - [File header](#file-header)
  - [Comment style - `line`](#comment-style---line)
- [Unnecessary Plugins Check](#unnecessary-plugins-check)
- [Tests](#tests)
- [Examples](#examples)
- [Notes](#notes)
- [Advanced](#advanced)
- [TODO](#todo)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->
## Intro

Give this script a path to a `plugins.yaml` file in a bundle with all plugins you want installed (any tier), and it will:

1. Generate the `plugin-catalog.yaml` file for you in the same directory, including all versions and transitive dependencies.
2. Update the `plugins.yaml` file you originally specifed with the additional transitive dependencies.

This means that as long as you are willing to use the plugin versions in the CloudBees Update Centers (which you should be doing), then all you ever need to do is add plugins to the `plugins.yaml` file and this script will handle the rest. No more manually crafting plugin catalogs!

## :information_source: Removal of plugin-installation-manager-tool dependency

The plugin installation manager tool is no longer needed, since CloudBees update centers come with a pre-determined set of plugin versions for CAP plugins.

Removal of this dependency results in:

- less network bandwidth
- reduced execution time

## Source Plugin Management

A better way of managing plugin lists has been added. See the [Standard Workflow](examples/workflow-standard-steps/README.md) for more details

## New Features

- **minimal plugin list** - create a minimal viable list of plugins based on a starting list. See `-s` for more details.
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

### Minimal and Generation-Only Plugins

The `-s` flag can be used to create:

- `plugins-minimal.yaml`: the minimal viable list of plugins needed to create the controller as requested.
- `plugins-minimal-for-generation-only.yaml`: the bare-minimum list of plugins needed by the script to create the same resulting `plugins.yaml`

These minimal and gen-only plugins are also categorised as `min` and `gen` in the comments of the main `plugins.yaml`

### Generation-Only Use Case

The `-A` flag tells the script to use only those plugins from the `plugins.yaml` which are marked as "generation only" (`gen`) in order to create the new list.

For example, take the `ec2-fleet` plugin which depends on the `aws-java-sdk` plugin, which pulls in a number of dependencies such as `aws-java-sdk-ec2`, etc.

A recent version of the `aws-java-sdk` plugin added the `aws-java-sdk-kinesis` plugin as a dependency (see below - other plugins removed for brevity).

```yaml
plugins:
...
- id: aws-java-sdk # 3rd lst dep src min
- id: aws-java-sdk-kinesis # 3rd lst dep src min
- id: ec2-fleet # 3rd lst src min gen
```

This new `aws-java-sdk-kinesis` plugin is not available in older update centers meaning the catalog generation would fail for older versions of CI.

Using the `-A` will create the plugin catalog using `ec2-fleet` only, thus creating the correct `plugins.yaml` and `plugin-catalog.yaml` for that particular version of CI.

Further examples will be added to the examples folder at a later date.
## Requirements

- docker (only for the v0.x branch)
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
                    defaults to 'line'
    -A          Use 'generation-only' plugins as the source list when calculating dependencies.
    -s          Create a MINIMAL plugin list (auto-removing bootstrap and dependencies)
    -S          Disable CVE check against plugins (added to metadata)

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

# Annotations:
#  tag:custom:version=...    - sets a custom version
#  tag:custom:url=...        - sets a custom url
#  tag:custom:requires=...   - specifies any required dependencies

# Plugin Categories:
#  cap - is this a CAP plugin?
#  3rd - is this a 3rd party plugin?
#  old - is this a deprecated plugin?
#  cve - are there open security issues?
#  bst - installed by default
#  dep - installed as dependency
#  lst - installed because it was listed
#  src - used as a source plugin for this list
#  min - is part of the viable 'minimal' set of plugins
#  gen - is part of the non-viable 'generation-only' set of plugins
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

## Unnecessary Plugins Check

The script will check for superfluous plugins which are already installed by another plugin in the list.

:warning: You still need to decide whether your situation requires the plugin explicitly. Do not simple remove plugins blindly.

The log will look something like this:

```text
INFO: CANDIDATES FOR REMOVAL: candidates found...
INFO: ==============================================================
INFO: !!! Candidates for potential removal from the plugins.yaml !!!
INFO: ==============================================================
INFO: The following plugins are either bootstrap or dependencies of CAP plugins:  cloudbees-casc-items-api  cloudbees-casc-items-commons  favorite  git  git-client  github  github-api  github-branch-source  htmlpublisher  mailer
INFO: For more details run: p=<PLUGIN_TO_CHECK>; grep -E ".* -> $p($| )" "/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/target/2.387.3.5/mm/generated/deps-processed-tree-single.txt"
INFO:   cloudbees-casc-items-api: provided by cloudbees-casc-client cloudbees-casc-items-controller
INFO:   cloudbees-casc-items-commons: provided by cloudbees-casc-items-controller
INFO:   favorite: provided by blueocean
INFO:   git: provided by blueocean blueocean-git-pipeline
INFO:   git-client: provided by blueocean
INFO:   github: provided by blueocean
INFO:   github-api: provided by blueocean
INFO:   github-branch-source: provided by blueocean
INFO:   htmlpublisher: provided by blueocean
INFO:   mailer: is a bootstrap plugin
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
