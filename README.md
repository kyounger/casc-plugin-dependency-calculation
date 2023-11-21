# CloudBees CasC Plugin Catalog and Transitive Dependencies Calculator

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->
## Contents

- [Intro](#intro)
  - [General Features](#general-features)
- [Requirements](#requirements)
- [Usage](#usage)
  - [Using the docker image](#using-the-docker-image)
  - [Using locally](#using-locally)
  - [Local Development](#local-development)
- [NEW: Effective Bundle Management](#new-effective-bundle-management)
- [Source Plugin Management](#source-plugin-management)
  - [The `src` tag explained](#the-src-tag-explained)
  - [Support for Custom Plugins](#support-for-custom-plugins)
- [Additional Plugin Metadata](#additional-plugin-metadata)
  - [File header](#file-header)
- [Unnecessary Plugins Check](#unnecessary-plugins-check)
- [Tests](#tests)
- [Examples](#examples)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Intro

Give this script a path to a `plugins.yaml` file in a bundle with all plugins you want installed (any tier), and it will:

1. Generate the `plugin-catalog.yaml` file for you including all versions and transitive dependencies.
2. Generate variations of the `plugins.yaml` file you originally specifed with any additional transitive dependencies.
3. Allow you to specify where you want the resulting files to go.

This means that as long as you are willing to use the plugin versions in the CloudBees Update Centers (which you should be doing), then all you ever need to do is add plugins to the `plugins.yaml` file and this script will handle the rest. No more manually crafting plugin catalogs!

### General Features

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

## Requirements

Use the docker image provided, or

- jq (tested with `v1.6` and `v1.7`)
- yq (tested with `v4.35.2`and `v4.40.2`)
- curl

## Usage

The tool can be used either locally or using the docker image.

### Using the docker image

Within the directory of your choice...

...use as one-shot container with:

```sh
docker run -v $(pwd):$(pwd) -w $(pwd) -u $(id -u):$(id -g) --rm -it ghcr.io/kyounger/casc-plugin-dependency-calculation bash
```

...use as a long-lived container to stop and start with:

```sh
docker run -v $(pwd):$(pwd) -w $(pwd) -u $(id -u):$(id -g) -d ghcr.io/kyounger/casc-plugin-dependency-calculation tail -f /dev/null

```

Whereby...

```mono
  -v $(pwd):$(pwd)         # mount your current directory
  -w $(pwd)                # use your current directory as the working directory
  -u $(id -u):$(id -g)     # use your own user
```

### Using locally

Ensuring you meet the requirements above.

The docker image provides two commands

- `cascdeps` which is equal to the main `run.sh` at the root of this repository
- `cascgen` which is equal to the `utils/generate-effective-bundles.sh` util script

If you wish to have the same thing when running locally, simply add a couple of symlinks, e.g.

```sh
❯ ls -l $(which cascdeps)
lrwxrwxrwx 1 fred fred 79 Nov 13 21:04 /home/fred/bin/cascdeps -> /path/to/casc-plugin-dependency-calculation/run.sh
❯ ls -l $(which cascgen)
lrwxrwxrwx 1 fred fred 108 Nov 13 22:45 /home/fred/bin/cascgen -> /path/to/casc-plugin-dependency-calculation/utils/generate-effective-bundles.sh
```

### Local Development

Building your own image:

```sh
docker build -t casc-plugin-dependency-calculation:dev -f Containerfile .
```

Then using it, for example, to run tests before pushing commits:

```sh
docker run -v $(pwd):$(pwd) -w $(pwd) -u $(id -u):$(id -g) --rm -it casc-plugin-dependency-calculation:dev ./tests/run.sh simple
```

## NEW: Effective Bundle Management

The plugin dependency management has now been integrated with a new [generate-effective-bundles.sh](./utils/generate-effective-bundles.sh) script.

See the example page [generating effective bundles](./examples/workflow-generating-effective-bundles/README.md) for more details.

## Source Plugin Management

A better way of managing plugin lists has been added. See the [Standard Workflow](examples/workflow-standard-steps/README.md) for more details

### The `src` tag explained

More information on [the src tag](./examples/the-src-tag/README.md).

### Support for Custom Plugins

See the information for [custom plugins tags](./examples/custom-plugins-tags/README.md).

## Additional Plugin Metadata

This tool now provides metadata to the `plugins.yaml` giving more context to the included plugins.

Metadata is added in the form of comments behind the plugin.

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
#  src - used as a source plugin for this list
plugins
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

Please see the [examples directory](./examples/) for more examples.

A single run with the plugins.yaml file in the same directory as `run.sh`. This creates `plugin-catalog.yaml`:

`./run.sh -v 2.263.4.2`

A single run with a specified path to plugins.yaml file, but using the `-x` option to turn on the "inplace update". This will overwrite the `plugins.yaml` and `plugin-catalog.yaml` files.

`./run.sh -v 2.263.4.2 -f /path/to/plugins.yaml`

Multiple runs taking advantage of caching and generating multiple different `plugin-catalogs.yaml` and updating their corresponding `plugins.yaml`:

``` bash
./run.sh -v 2.263.1.2 -f /bundle1/plugins.yaml
./run.sh -v 2.263.4.2 -f /bundle2/plugins.yaml
./run.sh -v 2.263.4.2 -f /bundle3/plugins.yaml
./run.sh -v 2.277.1.2 -f /bundle4/plugins.yaml
```
