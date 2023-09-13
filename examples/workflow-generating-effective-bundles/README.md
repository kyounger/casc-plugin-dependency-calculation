# Generating Effective Bundles

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Intro](#intro)
- [Scripts and example files](#scripts-and-example-files)
- [Filtering](#filtering)
- [Debugging](#debugging)
- [1. Using `pluginCommands` to prepare `plugins.yaml`](#1-using-plugincommands-to-prepare-pluginsyaml)
  - [Goal](#goal)
  - [Steps](#steps)
    - [What does the command do?](#what-does-the-command-do)
    - [Running](#running)
- [2. Using `generate` to create effective bundles](#2-using-generate-to-create-effective-bundles)
    - [What does the plugin-catalog command do?](#what-does-the-plugin-catalog-command-do)
  - [Bundle Version](#bundle-version)
  - [Overwriting versions/URLs of custom plugins](#overwriting-versionsurls-of-custom-plugins)
- [Making changes](#making-changes)
  - [Changes to plugins](#changes-to-plugins)
  - [Changes to configuration only](#changes-to-configuration-only)
  - [Upgrading](#upgrading)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Intro

This page will guide you through the steps used to manage your bundles statically by creating effective bundles per bundle AND CI version.

A set of example files are provided with the commands.

Starting with an initial set of bundles, we will:

- Prepare the `plugins.yaml` for each bundle for future management
- Create the effective bundle including custom `plugin-catalog.yaml` and `plugins.yaml`

## Scripts and example files

The scripts used here are:

- [utils/generate-effective-bundles.sh](../../utils/generate-effective-bundles.sh)
  - currently provides 3 actions
    - `pluginCommands`: used to create the minimal set of plugins for your bundles
    - `generate`: used to create the effective bundles
    - `pre-commit`: can be used in combination with [pre-commit](https://pre-commit.com/) to avoid unwanted mistakes in commits

The directories in this example are:

- `raw-bundles-original`: (temporary) kept just to show the difference before and after.
- `raw-bundles`: this directory holds the bundles in their raw form
- `effective-bundles`: TO BE CREATED, this directory holds the bundles in their effective form

## Filtering

Both the `pluginCommands` and the `generate` actions have two optional positional arguments which can be used for filtering so that:

```mono
../../utils/generate-effective-bundles.sh <ACTION> <BUNDLE_FILTER> <VERSION_FILTER>
```

**NOTE:** the bundle filter will take into consider all children of a bundle. Filtering by a parent will therefore automatically perform actions on all children

The following scenarios can be achieved:

- `generate-effective-bundles.sh <ACTION>` - all bundles in all versions
- `generate-effective-bundles.sh <ACTION> controller-c` - `controller-c` and children only in all versions
- `generate-effective-bundles.sh <ACTION> "" 2.401.2.3` - all bundles in version 2.401.2.3 only
- `generate-effective-bundles.sh <ACTION> controller-c 2.401.2.3` - `controller-c` and children only in version 2.401.2.3 only

## Debugging

Running with `DEBUG=1` will output additional information.

If more detailed information is needed, you can also revert to using `bash -x ...`

## 1. Using `pluginCommands` to prepare `plugins.yaml`

### Goal

Before we start, let us have a look at what we are trying to achieve.

Looking at the diff between `raw-bundles-original` and the `raw-bundles` we see that only the `plugins.yaml` have changed.

```sh
❯ diff -rq raw-bundles raw-bundles-original
Files raw-bundles-original/2.401.1.3/base/plugins/plugins.yaml and raw-bundles/2.401.1.3/base/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.1.3/bundle-a/plugins/plugins.yaml and raw-bundles/2.401.1.3/bundle-a/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.1.3/controller-a/plugins/plugins.yaml and raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.1.3/controller-c/plugins/plugins.yaml and raw-bundles/2.401.1.3/controller-c/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.2.3/base/plugins/plugins.yaml and raw-bundles/2.401.2.3/base/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.2.3/bundle-a/plugins/plugins.yaml and raw-bundles/2.401.2.3/bundle-a/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.2.3/controller-a/plugins/plugins.yaml and raw-bundles/2.401.2.3/controller-a/plugins/plugins.yaml differ
Files raw-bundles-original/2.401.2.3/controller-c/plugins/plugins.yaml and raw-bundles/2.401.2.3/controller-c/plugins/plugins.yaml differ
```

Taking a closer look at one of the `plugins.yaml` we see the file has been sanitised. This form of 'sanitising' is explained in the [standard-workflow-steps](../workflow-standard-steps/README.md)

```sh
❯ diff raw-bundles-original/2.401.2.3/controller-c/plugins/plugins.yaml raw-bundles/2.401.2.3/controller-c/plugins/plugins.yaml
0a1,17
> # This file is automatically generated - please do not edit manually.
>
> # Annotations (given as a comment above the plugin in question):
> #  tag:custom:version=...    - set a custom version (e.g. 1.0)
> #  tag:custom:url=...        - sets a custom url (e.g. https://artifacts.acme.test/my-plugin/1.0/my-plugin.jpi)
> #  tag:custom:requires=...   - spaced separated list of required dependencies (e.g. badge envinject)
>
> # Plugin Categories:
> #  cap - is this a CAP plugin?
> #  3rd - is this a 3rd party plugin?
> #  old - is this a deprecated plugin?
> #  cve - are there open security issues?
> #  bst - installed by default
> #  dep - installed as dependency
> #  lst - installed because it was listed
> #  src - used as a source plugin for this list
>
2,4c19,21
<   - id: git
<   - id: jfrog
<   - id: pipeline-model-definition
---
>   - id: git # cap lst dep
>   - id: jfrog # 3rd lst src
>   - id: pipeline-model-definition # cap lst dep
```

### Steps

From the root of your bundles repository, run the util script with the `pluginCommands` action.

```sh
../../utils/generate-effective-bundles.sh pluginCommands
```

The output will look something like this (**NOTE:** the full path has been made into a relative path for readability):

```sh
❯ ../../utils/generate-effective-bundles.sh pluginCommands
Looking for action 'pluginCommands'
Setting some vars...
Running with:
    DEP_TOOL=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh
    TARGET_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/target
    CACHE_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/.cache
    RAW_DIR=raw-bundles
    EFFECTIVE_DIR=effective-bundles
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.1.3 -s -f raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml -G raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.1.3 -s -f raw-bundles/2.401.1.3/base/plugins/plugins.yaml -G raw-bundles/2.401.1.3/base/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.1.3 -s -f raw-bundles/2.401.1.3/bundle-a/plugins/plugins.yaml -G raw-bundles/2.401.1.3/bundle-a/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.1.3 -s -f raw-bundles/2.401.1.3/controller-c/plugins/plugins.yaml -G raw-bundles/2.401.1.3/controller-c/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.2.3 -s -f raw-bundles/2.401.2.3/controller-a/plugins/plugins.yaml -G raw-bundles/2.401.2.3/controller-a/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.2.3 -s -f raw-bundles/2.401.2.3/base/plugins/plugins.yaml -G raw-bundles/2.401.2.3/base/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.2.3 -s -f raw-bundles/2.401.2.3/bundle-a/plugins/plugins.yaml -G raw-bundles/2.401.2.3/bundle-a/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -v 2.401.2.3 -s -f raw-bundles/2.401.2.3/controller-c/plugins/plugins.yaml -G raw-bundles/2.401.2.3/controller-c/plugins/plugins.yaml
Set DRY_RUN=0 to execute.
Done
```

#### What does the command do?

Looking at one of the commands above in more detail we can rewrite as:

```sh
/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh \
    -v 2.401.1.3 \
    -s \
    -f raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml \
    -G raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml
```

What this commands says is:

- using the plugin dependency tool
- `-v`: for version 2.401.1.3
- `-s`: create a minimal viable plugins list
- `-f`: using `raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml` as an input list
- `-G`: copy the resulting minimal viable plugins list to `raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml` (effectively replacing the input list)

#### Running

Setting `DRY_RUN=0` before the command, or exporting `DRY_RUN=0` will then run the commands in question (**NOTE:** exporting `DRY_RUN=0` will set the environment variable for EVERY subsequent command).

## 2. Using `generate` to create effective bundles

Now that we have a trusted set of plugins for which the dependencies have been calculated, we can use the `generate` action to create the effective bundle and corresponding plugin catalog.

From the root of your bundles repository, run the command `generate`

```sh
../../utils/generate-effective-bundles.sh generate
```

**NOTE:** this will copy over files, but not immediately recreate the plugin catalog. To recreate, `DRY_RUN=0` must be applied.

Using filtering to reduce the amount of output for this README.

Use `DEBUG=1` to see how and where the files are processed.

```sh
❯ ../../utils/generate-effective-bundles.sh generate controller-c 2.401.2.3
Looking for action 'generate'
Setting some vars...
Running with:
    DEP_TOOL=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh
    TARGET_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/target
    CACHE_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/.cache
    RAW_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/raw-bundles
    EFFECTIVE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles
INFO: Creating bundle '2.401.2.3-controller-c' using parents 'base bundle-a controller-c'
Running... /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh -N -M -v 2.401.2.3 -f /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/0.base.plugins.plugins.yaml -f /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/1.bundle-a.plugins.plugins.yaml -f /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/2.controller-c.plugins.plugins.yaml -c /home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/catalog/plugin-catalog.yaml
Set DRY_RUN=0 to execute.

INFO: Resulting files created using tree...
/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/examples/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c
├── bundle.yaml
├── catalog
│   └── 0.base.catalog.plugin-catalog.yaml
├── items
│   ├── 0.base.items.items.yaml
│   ├── 1.bundle-a.items.items.yaml
│   └── 2.controller-c.items.items.yaml
├── jcasc
│   ├── 0.base.jcasc.jenkins.yaml
│   ├── 1.bundle-a.jcasc.jenkins.yaml
│   └── 2.controller-c.jcasc.jenkins.yaml
├── plugins
│   ├── 0.base.plugins.plugins.yaml
│   ├── 1.bundle-a.plugins.plugins.yaml
│   └── 2.controller-c.plugins.plugins.yaml
└── variables
    ├── 0.base.variables.variables.yaml
    ├── 1.bundle-a.variables.variables.yaml
    └── 2.controller-c.variables.variables.yaml

6 directories, 14 files

INFO: Resulting bundle.yaml
apiVersion: '1'
id: 'controller-c'
description: 'Controller C (version: 2.401.2.3, inheritance: base bundle-a controller-c)'
version: 'e276d50540e0c28008d1e3a360ea5918'
jcascMergeStrategy: 'override'
jcasc:
  - jcasc
items:
  - items
catalog:
  - catalog
plugins:
  - plugins
variables:
  - variables
Done
```

#### What does the plugin-catalog command do?

Looking at one of the commands above in more detail we can rewrite as:

```sh
/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/run.sh \
    -N \
    -M \
    -v 2.401.2.3 \
    -f effective-bundles/2.401.2.3-controller-c/plugins/0.base.plugins.plugins.yaml \
    -f effective-bundles/2.401.2.3-controller-c/plugins/1.bundle-a.plugins.plugins.yaml \
    -f effective-bundles/2.401.2.3-controller-c/plugins/2.controller-c.plugins.plugins.yaml \
    -c effective-bundles/2.401.2.3-controller-c/catalog/plugin-catalog.yaml
```

What this commands says is:

- using the plugin dependency tool
- `-N`: skip dependency check and create the plugin catalog only (since we trust these plugin list)
- `-M`: deduplicate any plugins (plugin entries will be overwritten in the order of the argument)
- `-v`: for version 2.401.2.3
- `-f`: using `xxxxx` as an input list (**NOTE:** the order is the inheritance order of `base` -> `bundle-a` -> `controller-a`)
- `-c`: copy the resulting plugin catalog to `effective-bundles/2.401.2.3-controller-c/catalog/plugin-catalog.yaml` (previous files will be removed)

### Bundle Version

The unique `version` found in the `bundle.yaml` is made up of the md5sum all files found in the effective bundle.

### Overwriting versions/URLs of custom plugins

Sometimes a child bundle may need to use a different version of a custom plugin. This can be seen when looking at the `bundle-a` and `controller-a`, where the `some-custom-plugin` is overwritten to use `2.0` by the child bundle `controller-a`.

```sh
❯ grep -r custom-plugin raw-bundles
raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml:  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/2.0/some-custom-plugin-2.0.hpi
raw-bundles/2.401.1.3/controller-a/plugins/plugins.yaml:  - id: some-custom-plugin # 3rd lst src
raw-bundles/2.401.1.3/bundle-a/plugins/plugins.yaml:  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi
raw-bundles/2.401.1.3/bundle-a/plugins/plugins.yaml:  - id: some-custom-plugin # 3rd lst
```

The resulting dedicated plugin catalog after generating the effective bundle contains the version `2.0`:

```sh
❯ grep -r custom-plugin effective-bundles

...
...

effective-bundles/2.401.1.3-bundle-a/catalog/plugin-catalog.yaml:      some-custom-plugin:
effective-bundles/2.401.1.3-bundle-a/catalog/plugin-catalog.yaml:        url: "https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi"

...
...

effective-bundles/2.401.1.3-controller-a/catalog/plugin-catalog.yaml:      some-custom-plugin:
effective-bundles/2.401.1.3-controller-a/catalog/plugin-catalog.yaml:        url: "https://acme.org/artifactory/some-custom-plugin/2.0/some-custom-plugin-2.0.hpi"
```

## Making changes

### Changes to plugins

- add the plugin to the respective `plugins.yaml`
- run the `pluginCommands` action (optionally with filtering)
- run the `generate` action (optionally with filtering)

### Changes to configuration only

- make the change in the raw-bundles
- run the `generate` action (optionally with filtering)

### Upgrading

Consider having an `OLD_CI_VERSION` and a `NEW_CI_VERSION`

- copy the current `raw-bundles/OLD_CI_VERSION` to `raw-bundles/NEW_CI_VERSION`
  - optionally only copy the bundles you wish to test
- run the `pluginCommands` action (optionally with filtering for version)
- run the `generate` action (optionally with filtering for version)
- test the controller in question by applying the new effective bundle
