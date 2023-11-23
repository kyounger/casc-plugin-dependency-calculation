# Plugin Catalog Version Explained

<!-- START doctoc generated TOC please keep comment here to allow auto update -->
<!-- DON'T EDIT THIS SECTION, INSTEAD RE-RUN doctoc TO UPDATE -->

- [The Format](#the-format)
- [Example](#example)
  - [Plugins](#plugins)
  - [The `includePlugins` section](#the-includeplugins-section)
  - [Why do we need the `includePlugins` section?](#why-do-we-need-the-includeplugins-section)

<!-- END doctoc generated TOC please keep comment here to allow auto update -->

When validating a bundle, one of the important things is to ensure the target machine contains:

- the same set of plugins
- in the same versions

This is where the version comment in the plugin catalog may prove useful. Prefixed with `CHECKSUM_PLUGIN_FILES=`, it can be seen as a unique identifier for the expected set of 3rd party plugins and dependencies.

It is already used internally by the script to determine whether to update a particular plugin catalog.

```mono
❯ cat effective-bundles/controller-test/catalog.plugin-catalog.yaml
# CHECKSUM_PLUGIN_FILES=2-401-2-6-3463125b1438df855aaad9f12814f473-dbbca657af13497964cbbb579136ed2c
type: "plugin-catalog"
version: "1"
...
...
```

## The Format

The format consists of `<CI_VERSION_DASHES>-<EFFECTIVE_PLUGINS_MD5SUM>-<CATALOG_INCLUDE_PLUGINS_MD5SUM>`

- `CI_VERSION_DASHES` - 2-401-2-6 for version 2.401.2.6
- `EFFECTIVE_PLUGINS_MD5SUM` - the md5sum of the effective list of plugins
- `CATALOG_INCLUDE_PLUGINS_MD5SUM` - the md5sum of the includePlugins section of the plugin catalog

## Example

Consider an effective bundle for a controller named `controller-a` consisting of plugins from:

- base - the base or global bundle
- bundle-a - an intermediary bundle (e.g. with plugins for a particular purpose, e.g. android, finance)
- controller-a - the controller bundle (e.g. with plugins specific for this controller or controller type)

```sh
❯ tree effective-bundles/controller-a
effective-bundles/controller-a
├── bundle.yaml
├── catalog.plugin-catalog.yaml
├── items.0.base.items.items.yaml
├── items.1.bundle-a.items.items.yaml
├── jcasc.0.base.jcasc.jenkins.yaml
├── jcasc.1.bundle-a.jcasc.jenkins.yaml
├── jcasc.2.controller-a.jcasc.jenkins.yaml
├── plugins.0.base.plugins.plugins.yaml
├── plugins.1.bundle-a.plugins.plugins.yaml
├── plugins.2.controller-a.plugins.plugins.yaml
├── variables.0.base.variables.variables.yaml
├── variables.1.bundle-a.variables.variables.yaml
└── variables.2.controller-a.variables.variables.yaml
```

It has a unique plugin catalog ID of `2-401-2-6-b26f5b8c05254744c84d39c4c8aaf24c-c2bbe1739393f3765a56f7299e66c72c`

### Plugins

Let's find the `b26f5b8c05254744c84d39c4c8aaf24c` from the plugins files.

Source: `plugins.0.base.plugins.plugins.yaml`

```yaml
plugins:
  - id: cloudbees-casc-client # cap src
  - id: cloudbees-casc-items-controller # cap src
  - id: cloudbees-prometheus # 3rd src
  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi
  - id: some-custom-plugin # 3rd src
  - id: configuration-as-code # cap src
  - id: github # cap src
  - id: infradna-backup # cap src
  - id: managed-master-hibernation # cap src
  - id: pipeline-model-definition # cap src
  - id: pipeline-stage-view # cap src
  - id: sshd # cap src
  - id: branch-api # cap dep
  - id: job-dsl # 3rd src
```

Source: `plugins.1.bundle-a.plugins.plugins.yaml`

```yaml
plugins:
  - id: branch-api # cap dep
  - id: job-dsl # 3rd src
```

Source: `plugins.2.controller-a.plugins.plugins.yaml`

```yaml
plugins:
  - id: beer # 3rd src
  # tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.1/some-custom-plugin-1.1.hpi
  - id: some-custom-plugin # 3rd src
```

:warning: Notice that `controller-a` overrides the url of the `some-custom-plugin` to use version `1.1`

For more information on custom tags, see [custom pluginstags](../custom-plugins-tags/README.md).

Listing all plugins from all files with:

```sh
❯ yq --no-doc '.plugins' plugins.0.base.plugins.plugins.yaml plugins.1.bundle-a.plugins.plugins.yaml plugins.2.controller-a.plugins.plugins.yaml
- id: cloudbees-casc-client # cap src
- id: cloudbees-casc-items-controller # cap src
- id: cloudbees-prometheus # 3rd src
- id: configuration-as-code # cap src
# tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.0/some-custom-plugin-1.0.hpi
- id: some-custom-plugin # 3rd src
- id: github # cap src
- id: infradna-backup # cap src
- id: managed-master-hibernation # cap src
- id: pipeline-model-definition # cap src
- id: pipeline-stage-view # cap src
- id: sshd # cap src
- id: branch-api # cap dep
- id: job-dsl # 3rd src

- id: branch-api # cap dep
- id: job-dsl # 3rd src

- id: beer # 3rd src
# tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.1/some-custom-plugin-1.1.hpi
- id: some-custom-plugin # 3rd src
```

Now we create a unique list by:

- reversing (so the `1.1` version of `some-custom-plugin` comes first)
- removing duplocates (existing entries are not overwritten)
- sorting again to create an ordered list

The result is as follows:

```sh
❯ ...previous command... | yq '. |= (reverse | unique_by(.id) | sort_by(.id))' - --header-preprocess=false
- id: beer # 3rd src
- id: branch-api # cap dep
- id: cloudbees-casc-client # cap src
- id: cloudbees-casc-items-controller # cap src
- id: cloudbees-prometheus # 3rd src
- id: configuration-as-code # cap src
- id: github # cap src
- id: infradna-backup # cap src
- id: job-dsl # 3rd src
- id: managed-master-hibernation # cap src
- id: pipeline-model-definition # cap src
- id: pipeline-stage-view # cap src
# tag:custom:url=https://acme.org/artifactory/some-custom-plugin/1.1/some-custom-plugin-1.1.hpi
- id: some-custom-plugin # 3rd src
- id: sshd # cap src
```

Finally, an `md5sum` is made to create the `EFFECTIVE_PLUGINS_MD5SUM` part of the ID.

```sh
❯ ...previous command...  | md5sum -
b26f5b8c05254744c84d39c4c8aaf24c  -
```

### The `includePlugins` section

This is a much simpler command to find the `c2bbe1739393f3765a56f7299e66c72c` part of the ID.

```sh
❯ yq '.configurations[0].includePlugins' catalog.plugin-catalog.yaml | md5sum -
c2bbe1739393f3765a56f7299e66c72c  -
```

### Why do we need the `includePlugins` section?

Because the **versions** of 3rd plugins can still change, even if the underlying list does not.

We also want to be aware if this happens.
