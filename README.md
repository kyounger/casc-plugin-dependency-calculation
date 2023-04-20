# CloudBees CasC Plugin Catalog and Transitive Depedencies Calculator

Give this script a path to a `plugins.yaml` file in a bundle with all plugins you want installed (any tier), and it will:

1. Generate the `plugin-catalog.yaml` file for you in the same directory, including all versions and transitive dependencies.
2. Update the `plugins.yaml` file you originally specifed with the additional transitive dependencies.

This means that as long as you are willing to use the plugin versions in the CloudBees Update Centers (which you should be doing), then all you ever need to do is add plugins to the `plugins.yaml` file and this script will handle the rest. No more manually crafting plugin catalogs!

## New Features

- ability to run `exec-hooks` for plugin post-processing
- ability to create air-gapped `plugin-catalog.yaml` files
- rudimentary plugin-cache for holding plugins without an artifact repository manager

## Requirements

* docker
* jq
* yq (v4)
* curl

## Usage

```sh
Usage: run.sh -v <CI_VERSION> [OPTIONS]

    -h          display this help and exit
    -f FILE     path to the plugins.yaml file
    -t          The instance type (oc, oc-traditional, cm, mm)
    -d          Download plugins and create a plugin-catalog-offline.yaml with URLs
    -D          Offline pattern or set PLUGIN_CATALOG_OFFLINE_URL_BASE
                    defaults to $PLUGIN_CATALOG_OFFLINE_URL_BASE_DEFAULT
    -e          Exec-hook - script to call when processing 3rd party plugins
                    script will have access env vars PNAME, PVERSION, PURL, PFILE
                    can be used to automate the uploading of plugins to a repository manager
                    see examples under examples/exec-hooks
    -v          The version of CloudBees CI (e.g. 2.263.4.2)
    -V          Verbose logging (for debugging purposes)
    -r          Refresh the downloaded wars/jars (no-cache)
    -R          Refresh the downloaded update center jsons (no-cache)
    -x          Inplace-update of plugins.yaml and plugin-catalog.yaml
```

## Examples

A single run with the plugins.yaml file in the same directory as `run.sh`. This creates `plugin-catalog.yaml`:

`./run.sh -v 2.263.4.2`

A single run with a specified path to plugins.yaml file, but using the `-x` option to turn off the "inplace update". This leave the `plugins.yaml` file alone and only output the `plugin-catalog.yaml` content to stdout.

`./run.sh -v 2.263.4.2 -f /path/to/plugins.yaml -x`

Multiple runs taking advantage of caching and generating multiple different `plugin-catalogs.yaml` and updating their corresponding `plugins.yaml`:

``` bash
./run.sh -v 2.263.1.2 -f /bundle1/plugins.yaml
./run.sh -v 2.263.4.2 -f /bundle2/plugins.yaml
./run.sh -v 2.263.4.2 -f /bundle3/plugins.yaml
./run.sh -v 2.277.1.2 -f /bundle4/plugins.yaml
```

## Notes

* This will update your `plugins.yaml` file unless you specify the `-x` flag.

* This process caches all resources that it fetches under a `.cache` directory in the pwd. It caches multiple versions of the artifacts to enable re-running with different CI_VERSION.
  * `jenkins.war` from the docker image
  * `jenkins-plugin-manager.jar` download from github releases
  * `update-center.json` is cached from the UC download (this can reduce network traffic and delay if wanting to run this subseqently against multiple different `plugins.yaml`s.

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
