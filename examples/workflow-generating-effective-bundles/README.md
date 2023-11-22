# Generating Effective Bundles

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Intro](#intro)
- [Scripts and example files](#scripts-and-example-files)
- [Filtering](#filtering)
- [Debugging](#debugging)
- [Integration with pre-commit](#integration-with-pre-commit)
- [TLDR Walkthrough](#tldr-walkthrough)
  - [Setup](#setup)
  - [Using `plugins` to sanitize plugins files](#using-plugins-to-sanitize-plugins-files)
  - [Using `generate` to create effective bundles](#using-generate-to-create-effective-bundles)
  - [The plugin catalog versioning explained](#the-plugin-catalog-versioning-explained)
  - [The `AUTO_UPDATE_CATALOG` explained](#the-auto_update_catalog-explained)
  - [The `plugins` command explained](#the-plugins-command-explained)
    - [What does the command do?](#what-does-the-command-do)
  - [The `generate` command explained](#the-generate-command-explained)
    - [What does the plugin-catalog command do?](#what-does-the-plugin-catalog-command-do)
  - [Unique Bundle Version Per Effective Bundle](#unique-bundle-version-per-effective-bundle)
  - [Overwriting versions/URLs of custom plugins](#overwriting-versionsurls-of-custom-plugins)
- [PRO TIP: Use `raw.bundle.yaml`](#pro-tip-use-rawbundleyaml)
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

- [run.sh](../../run.sh) (aliased to `cascdeps` in the container)
- [utils/generate-effective-bundles.sh](../../utils/generate-effective-bundles.sh) (aliased to `cascgen` in the container)
  - currently provides 4 actions
    - `plugins`: used to create the minimal set of plugins for your bundles
    - `generate`: used to create the effective bundles
    - `all`: running both plugins and then generate
    - `force`: running both plugins and then generate, but taking a fresh update center json (normally cached for 6 hours, and regenerating the plugin catalog regardless)
    - `pre-commit`: can be used in combination with [pre-commit](https://pre-commit.com/) to avoid unwanted mistakes in commits

The directories in this example are:

- `raw-bundles-original`: (temporary) kept just to show the difference before and after.
- `raw-bundles`: this directory holds the bundles in their raw form
- `effective-bundles`: TO BE CREATED, this directory holds the bundles in their effective form

## Filtering

Both the `plugins` and the `generate` actions have two optional positional arguments which can be used for filtering so that:

```mono
cascgen <ACTION> <BUNDLE_FILTER>
```

**NOTE:** the bundle filter will take into consider all children of a bundle. Filtering by a parent will therefore automatically perform actions on all children

The following scenarios can be achieved:

- `cascgen <ACTION>` - all bundles in all versions
- `cascgen <ACTION> controller-c` - `controller-c` and children only

## Debugging

Running with `DEBUG=1` will output additional information.

If even more detailed information is needed, you can also revert to using `bash -x ...`

## Integration with pre-commit

Stop making inadvertent mistakes.

See [integration with pre-commit](../integrate-with-pre-commit/README.md) for more details.

## TLDR Walkthrough

Navigate into this directory and start the container.

### Setup

We are here 👇

```sh
$ ls -al
total 48
drwxrwxr-x    3 casc-use casc-use      4096 Nov 21 13:46 .
drwxrwxr-x    8 casc-use casc-use      4096 Nov 17 15:09 ..
-rw-rw-r--    1 casc-use casc-use        30 Nov 21 13:05 .gitignore
-rw-rw-r--    1 casc-use casc-use     16210 Nov 21 13:06 README.md
drwxrwxr-x    6 casc-use casc-use      4096 Nov 21 13:06 raw-bundles-original
```

Running the command tells us what our options are:

```sh
$ cascgen
Looking for action ''
Unknown action '' (actions are: pre-commit, generate, plugins, all)
```

Let's run the plugins command

```sh
$ cascgen plugins
Looking for action 'plugins'
Setting some vars...
RAW_DIR '/workspace/workflow-generating-effective-bundles/raw-bundles' is not a directory
```

Oh, the raw-bundles die hasn't been created. Let's copy the original...

```sh
$ cp -r raw-bundles-original raw-bundles
$ cascgen plugins
Looking for action 'plugins'
Setting some vars...
EFFECTIVE_DIR '/workspace/workflow-generating-effective-bundles/effective-bundles'  is not a directory
```

Now the effective-bundles dir...

```sh
$ mkdir effective-bundles
$ cascgen plugins
Looking for action 'plugins'
Setting some vars...
CI_VERSION '' is not a valid version.
$ export CI_VERSION=2.401.2.3
```

### Using `plugins` to sanitize plugins files

Run the `plugins` command

```sh
$ cascgen plugins
Looking for action 'plugins'
Setting some vars...
INFO: Setting CI_VERSION according to CI_VERSION env var.
Running with:
    DEP_TOOL=/usr/local/bin/cascdeps
    TARGET_BASE_DIR=/workspace/workflow-generating-effective-bundles/target
    CACHE_BASE_DIR=/workspace/workflow-generating-effective-bundles/.cache
    RAW_DIR=/workspace/workflow-generating-effective-bundles/raw-bundles
    EFFECTIVE_DIR=/workspace/workflow-generating-effective-bundles/effective-bundles
    CI_VERSION=2.401.2.3
Running... /usr/local/bin/cascdeps -v 2.401.2.3 -sAf /workspace/workflow-generating-effective-bundles/raw-bundles/controller-a/plugins.yaml -G /workspace/workflow-generating-effective-bundles/raw-bundles/controller-a/plugins.yaml
INFO: CI_VERSION set to '2.401.2.3'.
```

Looking at the diff between `raw-bundles-original` and the `raw-bundles` we see that only the `plugins.yaml` have changed.

```sh
$ diff -rq raw-bundles raw-bundles-original
Files raw-bundles/base/plugins.yaml and raw-bundles-original/base/plugins.yaml differ
Files raw-bundles/bundle-a/plugins.yaml and raw-bundles-original/bundle-a/plugins.yaml differ
Files raw-bundles/controller-a/plugins.yaml and raw-bundles-original/controller-a/plugins.yaml differ
Files raw-bundles/controller-c/plugins.yaml and raw-bundles-original/controller-c/plugins.yaml differ
```

Taking a closer look at one of the `plugins.yaml` we see the file has been sanitised. This form of 'sanitising' is explained in the [standard-workflow-steps](../workflow-standard-steps/README.md)

```sh
$ diff raw-bundles-original/controller-c/plugins.yaml raw-bundles/controller-c/plugins.yaml
--- raw-bundles-original/controller-c/plugins.yaml
+++ raw-bundles/controller-c/plugins.yaml
@@ -1,4 +1,20 @@
+# This file is automatically generated - please do not edit manually.
+
+# Annotations (given as a comment above the plugin in question):
+#  tag:custom:version=...    - set a custom version (e.g. 1.0)
+#  tag:custom:url=...        - sets a custom url (e.g. https://artifacts.acme.test/my-plugin/1.0/my-plugin.jpi)
+#  tag:custom:requires=...   - spaced separated list of required dependencies (e.g. badge envinject)
+
+# Plugin Categories:
+#  cap - is this a CAP plugin?
+#  3rd - is this a 3rd party plugin?
+#  old - is this a deprecated plugin?
+#  cve - are there open security issues?
+#  bst - installed by default
+#  dep - installed as dependency
+#  src - used as a source plugin for this list
+
 plugins:
-  - id: git
-  - id: jfrog
-  - id: pipeline-model-definition
+  - id: git # cap dep
+  - id: jfrog # 3rd src
+  - id: pipeline-model-definition # cap dep
```

### Using `generate` to create effective bundles

Now that we have a trusted set of `plugins.yaml` for which the dependencies have been calculated, we can use the `generate` action to create the effective bundle and corresponding plugin catalog.

From the root of your bundles repository, run the command `generate`.

```sh
$ cascgen generate
Looking for action 'generate'
Setting some vars...
INFO: Setting CI_VERSION according to CI_VERSION env var.
Running with:
    DEP_TOOL=/usr/local/bin/cascdeps
    TARGET_BASE_DIR=/workspace/workflow-generating-effective-bundles/target
    CACHE_BASE_DIR=/workspace/workflow-generating-effective-bundles/.cache
    RAW_DIR=/workspace/workflow-generating-effective-bundles/raw-bundles
    EFFECTIVE_DIR=/workspace/workflow-generating-effective-bundles/effective-bundles
    CI_VERSION=2.401.2.3
INFO: Creating bundle 'controller-c' using parents 'base controller-c'

AUTO_UPDATE_CATALOG - Checking plugin files checksum 'actual: ' vs 'expected: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0'
AUTO_UPDATE_CATALOG - no current plugin catalog found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)...

Running... /usr/local/bin/cascdeps -N -M -v 2.401.2.3 -f /workspace/workflow-generating-effective-bundles/effective-bundles/controller-c/plugins.1.controller-c.plugins.yaml -f /workspace/workflow-generating-effective-bundles/effective-bundles/controller-c/plugins.0.base.plugins.yaml -c /workspace/workflow-generating-effective-bundles/effective-bundles/controller-c/catalog.plugin-catalog.yaml
Removing any previous catalog files...
INFO: CI_VERSION set to '2.401.2.3'.
INFO: Setting CACHE_BASE_DIR=/workspace/workflow-generating-effective-bundles/.cache
INFO: Multiple source files passed. Creating temporary plugins.yaml file '/tmp/tmp.bIebin'.
INFO: update-center.json is less than 360 minutes old. You can remove it or use the '-R' flag to refresh the cache.
INFO: Creating target dir (/workspace/workflow-generating-effective-bundles/target/2.401.2.3/mm)
INFO: Sanity checking '/tmp/tmp.bIebin' for duplicates.

...
...

INFO: Resulting files created using tree...
/workspace/workflow-generating-effective-bundles/effective-bundles/controller-c
├── bundle.yaml
├── catalog.plugin-catalog.yaml
├── items.0.base.items.yaml
├── items.1.controller-c.items.yaml
├── jcasc.0.base.jenkins.yaml
├── jcasc.1.controller-c.jenkins.yaml
├── plugins.0.base.plugins.yaml
├── plugins.1.controller-c.plugins.yaml
├── variables.0.base.variables.yaml
└── variables.1.controller-c.variables.yaml

0 directories, 10 files

INFO: Resulting bundle.yaml
apiVersion: '1'
id: 'controller-c'
description: 'Controller C (version: 2.401.2.3, inheritance: base controller-c)'
version: '55dae9646e4c8ab1faf1e5173d33612b'
availabilityPattern: ".*"
jcascMergeStrategy: 'override'
jcasc:
  - jcasc.0.base.jenkins.yaml
  - jcasc.1.controller-c.jenkins.yaml
items:
  - items.0.base.items.yaml
  - items.1.controller-c.items.yaml
catalog:
  - catalog.plugin-catalog.yaml
plugins:
  - plugins.0.base.plugins.yaml
  - plugins.1.controller-c.plugins.yaml
variables:
  - variables.0.base.variables.yaml
  - variables.1.controller-c.variables.yaml
Done
```

### The plugin catalog versioning explained

Please see [](../catalog-version-explained/README.md) for more details on how the version of the plugin catalog is calculated.

### The `AUTO_UPDATE_CATALOG` explained

The `AUTO_UPDATE_CATALOG` is a feature which automatically detects changes in a bundles plugins and "automatically" recreates the associated plugin catalog.

It does this by adding a header comment to the plugin catalog file in the format `<CI_VERSION>-<PLUGIN_FILES_CHECKSUM>`. If the checksum or version changes, the plugin catalog is recreated.

Subsequent runs are obviously a lot faster if nothing has changed since the generation is skipped.

It is set activated by default, but can be deactivated if required (but then there is a risk that the plugin catalog becomes stale).

Here the log for a first run:

```sh
AUTO_UPDATE_CATALOG - Checking plugin files checksum 'actual: ' vs 'expected: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0'
AUTO_UPDATE_CATALOG - no current plugin catalog found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)...
```

And here a subsequent run with the same set of plugins

```sh
AUTO_UPDATE_CATALOG - Checking plugin files checksum 'actual: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0' vs 'expected: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0'
```

Here upon adding a plugin

```sh
AUTO_UPDATE_CATALOG - Checking plugin files checksum 'actual: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0' vs 'expected: 2.401.2.3-348b38f0e2108f8adce89d79743c9178'
AUTO_UPDATE_CATALOG - differences in plugins found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)...
```

Here upon updating the CI_VERSION

```sh
AUTO_UPDATE_CATALOG - Checking plugin files checksum 'actual: 2.401.2.3-62a294abe449b334cd474ee07c0c69f0' vs 'expected: 2.401.3.3-62a294abe449b334cd474ee07c0c69f0'
AUTO_UPDATE_CATALOG - differences in plugins found. Automatically refreshing the plugin catalog (setting DRY_RUN=0)...
```

### The `plugins` command explained

The output will look something like this (**NOTE:** the full path has been made into a relative path for readability):

```sh
❯ cascgen plugins controller-c
Looking for action 'plugins'
Setting some vars...
Running with:
    DEP_TOOL=/home/sboardwell/bin/cascdeps
    TARGET_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/target
    CACHE_BASE_DIR=/home/sboardwell/Workspace/sboardwell/casc-plugin-dependency-calculation/.cache
    RAW_DIR=raw-bundles
    EFFECTIVE_DIR=effective-bundles
Running... /home/sboardwell/bin/cascdeps -v 2.401.2.3 -s -f raw-bundles/controller-c/plugins/plugins.yaml -G raw-bundles/controller-c/plugins/plugins.yaml
```

#### What does the command do?

Looking at one of the commands above in more detail we can rewrite as:

```sh
/home/sboardwell/bin/cascdeps \
    -v 2.401.2.3 \
    -s \
    -f raw-bundles/controller-a/plugins/plugins.yaml \
    -G raw-bundles/controller-a/plugins/plugins.yaml
```

What this commands says is:

- using the plugin dependency tool
- `-v`: for version 2.401.2.3
- `-s`: create a minimal viable plugins list
- `-f`: using `raw-bundles/controller-a/plugins/plugins.yaml` as an input list
- `-G`: copy the resulting minimal viable plugins list to `raw-bundles/controller-a/plugins/plugins.yaml` (effectively replacing the input list)

### The `generate` command explained

Running the `generate` command you will see the following in the logs:

```sh
❯ cascgen generate controller-c
...
...
Running... /home/sboardwell/bin/cascdeps -N -M -v 2.401.2.3 -f /workspace/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/0.base.plugins.plugins.yaml -f /workspace/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/1.bundle-a.plugins.plugins.yaml -f /workspace/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/plugins/2.controller-c.plugins.plugins.yaml -c /workspace/workflow-generating-effective-bundles/effective-bundles/2.401.2.3-controller-c/catalog/plugin-catalog.yaml
Set DRY_RUN=0 to execute.
```

#### What does the plugin-catalog command do?

Looking at one of the commands above in more detail we can rewrite as:

```sh
/home/sboardwell/bin/cascdeps \
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

### Unique Bundle Version Per Effective Bundle

The unique `version` found in the `bundle.yaml` is made up of the md5sum all files found in the effective bundle.

### Overwriting versions/URLs of custom plugins

This is also covered in [the custom plugin tags section](../custom-plugins-tags/README.md)

Sometimes a child bundle may need to use a different version of a custom plugin. This can be seen when looking at the `bundle-a` and `controller-a`, where the `some-custom-plugin` is overwritten to use `2.0` by the child bundle `controller-a`.

```sh
❯ grep -r custom-plugin raw-bundles
raw-bundles/controller-a/plugins/plugins.yaml:  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/2.0/some-custom-plugin-2.0.hpi
raw-bundles/controller-a/plugins/plugins.yaml:  - id: some-custom-plugin # 3rd src
raw-bundles/bundle-a/plugins/plugins.yaml:  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi
raw-bundles/bundle-a/plugins/plugins.yaml:  - id: some-custom-plugin # 3rd
```

The resulting dedicated plugin catalog after generating the effective bundle contains the version `2.0`:

```sh
$ grep -r custom-plugin effective-bundles | grep plugin-catalog
effective-bundles/controller-a/catalog.plugin-catalog.yaml:      some-custom-plugin:
effective-bundles/controller-a/catalog.plugin-catalog.yaml:        url: "https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-2.0.hpi"
effective-bundles/bundle-a/catalog.plugin-catalog.yaml:      some-custom-plugin:
effective-bundles/bundle-a/catalog.plugin-catalog.yaml:        url: "https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi"
```

## PRO TIP: Use `raw.bundle.yaml`

Consider having your raw bundles and effective bundles in the same branch.

Given the bundle names are now duplicated, you cannot load them into the CloudBees Operations Center.

Meet the `raw.bundle.yaml`...

When looking for raw bundles, the tool will also recognise `*bundle.yaml` files.

This means you can change your raw bundles `bundle.yaml` files to something like `raw.bundle.yaml`

Try it for yourself

```sh
for f in $(find raw-bundles -name bundle.yaml); do fname=$(basename $f); fdir=$(dirname $f); mv "$f" "${fdir}/raw.${fname}"; done
```

The commands work the same, but now we can use the "CasC Bundle Location" feature in the CloudBees Operations Center.

## Making changes

### Changes to plugins

- add the plugin to the respective `plugins.yaml`
- run either:
  - the `plugins` and `generate` action (optionally with filtering)
  - the `all` action to do both (optionally with filtering)

### Changes to configuration only

- make the change in the raw-bundles
- run the `generate` action (optionally with filtering)

### Upgrading

This topic is out of the scope of this README.

The `CI_VERSION` is determined by one of the following things in order (see the `determineCIVersion` method for more details):

- the `CI_VERSION` environment variable.
- the parent directory of the `RAW_DIR` (sterred by the the `CI_DETECTION_PATTERN` which defaults to `vX.X.X.X`)
- the `GIT_BRANCH` environment variable.
- the git branch name using the git command (if available).

Whether to use:

- a single branch with version-based directories
- multiple branches with each branch called after the version
- multiple branches with each branch called after the version with the raw-bundles as code, but the effective-bundles as git sub modules
- a single branch with multiple different versions within the same list of bundles (I would not recommend this)

It is really a matter of choice. As soon as a standard is found, we can put it here.
