# Tags for Custom Plugins

Sometimes you have a custom plugin which is not in the official CloudBees Update Center. Perhaps it is an in-house plugin, or perhaps you wish to use a specific version.

Normally the dependency script's sanity check would fail saying the "the plugin does not exist in the UC".

However, a set of tags now allows you to specify custom plugins in your plugins list.

- The tags must be given as comments above the plugin in question.
- An short explanation of the tags is provided in the header of the resulting `plugins.yaml` (see below)

```yaml
# Annotations (given as a comment above the plugin in question):
#  tag:custom:version=...    - set a custom version (e.g. 1.0)
#  tag:custom:url=...        - sets a custom url (e.g. https://artifacts.acme.test/my-plugin/1.0/my-plugin.jpi)
#  tag:custom:requires=...   - spaced separated list of required dependencies (e.g. badge envinject)
```

## Tag `tag:custom:version`

This tag sets a custom version for your plugin.

:warning: You are responsible for ensuring the plugin can be found in the version you specify.

Example:

```mono
❯ grep -B 1 beer target/2.401.3.3/mm/plugins.yaml
  # tag:custom:version=9.9.9
  - id: beer # 3rd src

❯ grep -A 1 beer target/2.401.3.3/mm/plugin-catalog.yaml
      beer:
        version: "9.9.9"

❯ grep -A 1 beer target/2.401.3.3/mm/plugin-catalog-offline.yaml
      beer:
        url: "https://jenkins-updates.cloudbees.com/download/plugins/beer/9.9.9/beer.hpi"
```

## Tag `tag:custom:url`

This tag sets a custom url for your plugin.

**NOTE:** here the url is used in both the `plugin-catalog.yaml` (where versions are otherwise given) as well as the `plugin-catalog-offline.yaml`.

:warning: You are responsible for ensuring the plugin can be found in the version you specify.

Example:

```mono
❯ grep -B 1 beer target/2.401.3.3/mm/plugins.yaml
  # tag:custom:url=https://artifacts.acme.com/download/beer.hpi
  - id: beer # 3rd src

❯ grep -A 1 beer target/2.401.3.3/mm/plugin-catalog.yaml
      beer:
        url: "https://artifacts.acme.com/download/beer.hpi"

❯ grep -A 1 beer target/2.401.3.3/mm/plugin-catalog-offline.yaml
      beer:
        url: "https://artifacts.acme.com/download/beer.hpi"
```

## Tag `tag:custom:requires`

This tag allows you specify any dependencies your custom plugin has.

e.g. the follow would tell ensure the script checks for the existence of the `badge` and `env-inject` in the list when generating the plugins list

```mono
  # tag:custom:url=https://artifacts.acme.com/download/custom-badges.hpi
  # tag:custom:requires=badge envinject
  - id: custom-badges # src
```

**NOTE:** The required plugins will also need the 'src' tag.
