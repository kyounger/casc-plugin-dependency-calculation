# CloudBees CasC Plugin Catalog and Transitive Depedencies Calculator

Give this script a path to a `plugins.yaml` file in a bundle with all plugins you want installed (any tier), and it will:

1. Generate the `plugin-catalog.yaml` file for you in the same directory, including all versions and transitive dependencies.
2. Update the `plugins.yaml` file you originally specifed with the additional transitive dependencies.

This means that as long as you are willing to use the plugin versions in the CloudBees Update Centers (which you should be doing), then all you ever need to do is add plugins to the `plugins.yaml` file and this script will handle the rest. No more manually crafting plugin catalogs!

## Requirements

* docker
* yq (v4)
* curl

## Usage

```
Usage: run.sh -v <CI_VERSION> [-f <path/to/plugins.yaml>] [-h] [-x]

    -h          display this help and exit
    -f FILE     path to the plugins.yaml file
    -v          The version of CloudBees CI (e.g. 2.263.4.2)
    -x          Do NOT do an inplace update of plugins.yaml
```

## Examples

A single run with the plugins.yaml file in the same directory as `run.sh`. This create `plugin-catalog.yaml` and updates `plugins.yaml`:

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

These two settings are adjustable by exporting them in the shell prior to running. This, for example, is running the process again the client master UC and docker image. *Note that caching does not handle changing this on subseqent runs!*

```bash
export CB_UPDATE_CENTER="https://jenkins-updates.cloudbees.com/update-center/envelope-core-cm"
export CB_DOCKER_IMAGE="cloudbees/cloudbees-core-cm"
```

## TODO

- [x] Generate the updated `plugins.yaml` file that includes the additional transitive dependencies.
- [x] Put in some examples
- [x] Consider parameterizing the CI_VERSION. This would require checking the version of the war/UC that is cached and potentially invalidating those artifacts prior to running.
- [ ] Put time into a PR for PIMT that allows it to have structured output to avoid the use of `sed` in processing its output.
