# Standard Workflow

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [Intro](#intro)
- [Obtaining a `plugins.yaml` from a controller](#obtaining-a-pluginsyaml-from-a-controller)
- [Preparing your `plugins.yaml`](#preparing-your-pluginsyaml)
  - [Minimum viable vs raw list](#minimum-viable-vs-raw-list)
  - [Minimum viable vs generation-only list](#minimum-viable-vs-generation-only-list)
  - [Manual alterations](#manual-alterations)
- [Creating your first `plugins.yaml` and `plugin-catalog.yaml`](#creating-your-first-pluginsyaml-and-plugin-catalogyaml)
- [Updating your `plugins.yaml` and `plugin-catalog.yaml`](#updating-your-pluginsyaml-and-plugin-catalogyaml)
  - [The reasoning behind the `-A` source plugins only option](#the-reasoning-behind-the--a-source-plugins-only-option)
- [Making changes](#making-changes)
  - [Adding a plugin](#adding-a-plugin)
  - [Removing a plugin](#removing-a-plugin)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

## Intro

This page will guide you through the steps used to manage your plugins in a standard environment with a single plugin list.

A set of example files are provided with the commands.

We will look at:

- Obtaining the initial set of plugins from a controller
- preparing the `plugins.yaml` for future management
- creating the `plugin-catalog.yaml` and `plugins.yaml` for a given version of CI
- recreating the `plugin-catalog.yaml` and `plugins.yaml` for an upgrade
- making changes

## Obtaining a `plugins.yaml` from a controller

Assuming the "CloudBees CasC Client" plugin is already installed, go to "Manage Jenkins" -> "CloudBees Configuration as Code export and update". Then click on the view icon.

Copy the list to `plugins-raw.yaml`

Example:

```sh
yq . "examples/workflow-standard-steps/files/plugins-raw.yaml"
```

## Preparing your `plugins.yaml`

Let us assume we are creating a bundle for CloudBees CI version `2.387.3.5`

Let's run the script using the `-s` option to minimise the raw set of plugins.

```sh
./run.sh -v "2.387.3.5" -f "examples/workflow-standard-steps/files/plugins-raw.yaml" -s
```

Take a closer look at the "Summary" at the end of the script.

### Minimum viable vs raw list

When comparing the "minimal list vs the original list" you will notice that:

- the bootstrap plugins have been removed
- any dependencies of CAP plugins have been removed

(both of which are installed automatically and therefore not needed in our list)

```sh
diff -y "target/2.387.3.5/mm/plugins.yaml" "target/2.387.3.5/mm/plugins-minimal.yaml" | less
```

### Minimum viable vs generation-only list

Further comparing "minimal list vs the generation-only list" you will notice that:

- the generation-only list contains the absolute minimum set of plugins this script needs to create the viable list of plugins
- all source plugins are tagged with the `src` category to indicate they are needed for generation purposes

```sh
diff -y "target/2.387.3.5/mm/plugins-minimal.yaml" "target/2.387.3.5/mm/plugins-minimal-for-generation-only.yaml" | less
```

The example file can be found at `examples/workflow-standard-steps/files/plugins-minimal.yaml`

### Manual alterations

There may be some plugins which are not currently classed as `src` but which you wish to keep.

In the example above, consider the `aws-credentials` plugin. We may wish to have this installed regardless. In this case, simply add the `src` tag to the plugin.

Before:

```yaml
plugins:
  - id: aws-credentials # cap lst dep
```

After (comment is optional):

```yaml
plugins:
  # we want to keep this plugin regardless - src added manually
  - id: aws-credentials # cap lst dep src
```

The resulting starter file can be found at `examples/workflow-standard-steps/files/plugins-starter.yaml`

We will now use this file to create our first catalog.

## Creating your first `plugins.yaml` and `plugin-catalog.yaml`

:information_source: the need for the `-A` flag will be explained in the upgrade section.

We will make use of:

- `-A` to use only the source (`src`) plugins when generating the new files
- `-G` to copy the resulting minimal viable list to it's final destination
- `-c` to copy the resulting plugin catalog to it's final destination

Using the starter file from above, we run:

```sh
./run.sh -v "2.387.3.5" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/plugins-starter.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugin-catalog.yaml"
```

As expected, the resulting `plugins.yaml` is identical to our input `plugins-starter.yaml`. This is because we are generating files for the same CloudBees CI version.

```sh
diff target/2.387.3.5/mm/plugins.yaml.orig.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml
```

From now on, we no longer need the separate starter file. Instead we can use the actual `examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml` as our reference file.

Running the following is identical to using the starter file, but with in place updates:

```sh
./run.sh -v "2.387.3.5" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugin-catalog.yaml"
```

Let's see what happens when we upgrade!

## Updating your `plugins.yaml` and `plugin-catalog.yaml`

:information_source: **handling changes to plugins and versions:** the bundle directories in this example are separated by CI version in order to show the differences between updates. However, you may wish to use the same directory and version your changes through git commits.

Using only the `src` plugins of our newly created reference file (in the `bundle-v2.387.3.5` bundle), we can create the files for our upcoming upgrade to `2.414.1.4`:

```sh
./run.sh -v "2.414.1.4" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugin-catalog.yaml"
```

Looking at the differences, you can see that upgraded `plugins.yaml` now has an additional dependency plugin `aws-java-sdk-kinesis` as well as the usual version changes in the `plugin-catalog.yaml` files:

```sh
❯ diff examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml
28a29
>   - id: aws-java-sdk-kinesis # 3rd dep
```

### The reasoning behind the `-A` source plugins only option

So, now we have a new file for `2.414.1.4` which contains additional plugins which were not present in a previous version `2.387.3.5`.

:warning: Following the same logic, a dependency could also be removed in a future release.

If we were to try and recreate files for the older `2.387.3.5` but using our plugin list from `2.414.1.4` the script would fail with:

```sh
❯ ./run.sh -v 2.387.3.5 -f examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml -s
INFO: CI_VERSION set to '2.387.3.5'.
...
...
INFO: Sanity checking 'examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml' for missing online plugins.
WARN: Missing online plugin 'aws-java-sdk-kinesis' which does not have a custom version or URL annotation.
ERROR: PLUGINS_MISSING_ONLINE: see above.

```

Using the `-A` option allows us to recreate files using just the source plugins, in effect making it a static set of plugins you wish to install from which to recreate viable lists for all versions.

To test, we repeat the command, but this time with the `-A` option:

```sh
./run.sh -v 2.387.3.5 -f examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml -s -A
```

This time it succeeds.

Comparing the input list with the newly created minimal list, we see that the `aws-java-sdk-kinesis` has been removed:

```sh
❯ diff "target/2.387.3.5/mm/plugins.yaml.orig.yaml" "target/2.387.3.5/mm/plugins-minimal.yaml"
29d28
<   - id: aws-java-sdk-kinesis # 3rd dep
```

## Making changes

Now that we have our reference file with `src` plugins marked accordingly, making changes is relatively easy.

### Adding a plugin

Files found in `*-add`.

Consider we want the `basic-branch-build-strategies` plugin. We can edit the reference file, adding the plugin and marking as `src`

```yaml
  - id: basic-branch-build-strategies # src
```

Then recreate the necessary files using the now edited file:

```sh
./run.sh -v "2.387.3.5" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugin-catalog.yaml"
```

The new files now include the `branch-api` as a dependency of the `basic-branch-build-strategies` plugin.

```sh
❯ diff -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5 examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugin-catalog.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugin-catalog.yaml
31a32,33
>       basic-branch-build-strategies:
>         version: "71.vc1421f89888e"
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5/plugins.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml
32a33,34
>   - id: basic-branch-build-strategies # 3rd lst src
>   - id: branch-api # cap dep
```

And, as before, the same can be performed for `2.414.1.4`:

```sh
./run.sh -v "2.387.3.5" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4-additional-plugin/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4-additional-plugin/plugin-catalog.yaml"
```

Results are similar, just with updated versions of the plugins:

```sh
❯ diff -r examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4 examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4-add
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugin-catalog.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4-add/plugin-catalog.yaml
33a34,35
>       basic-branch-build-strategies:
>         version: "81.v05e333931c7d"
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4/plugins.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.414.1.4-add/plugins.yaml
33a34,35
>   - id: basic-branch-build-strategies # 3rd lst src
>   - id: branch-api # cap lst dep
```

### Removing a plugin

Files found in `*-remove`.

Consider we want to now remove the `basic-branch-build-strategies` plugin. We can edit the reference file, removing the plugin (NOTE: the `branch-api` dependency is still in the list, but not a src file).

```sh
❯ diff -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugins.yaml
33d32
<   - id: basic-branch-build-strategies # 3rd lst src
```

Then recreate the necessary files using the now edited file:

```sh
./run.sh -v "2.387.3.5" \
    -s \
    -A \
    -f "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugins.yaml" \
    -G "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugins.yaml" \
    -c "examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugin-catalog.yaml"
```

The new files now reference neither plugin nor depedency.

```sh
❯ diff -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugin-catalog.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugin-catalog.yaml
32,33d31
<       basic-branch-build-strategies:
<         version: "71.vc1421f89888e"
diff --color -r examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-add/plugins.yaml examples/workflow-standard-steps/files/bundles/bundle-v2.387.3.5-remove/plugins.yaml
33,34d32
<   - id: basic-branch-build-strategies # 3rd lst src
<   - id: branch-api # cap dep
```