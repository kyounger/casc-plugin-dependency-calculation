
# Script Parameters Summary (`run.sh`)

| Parameter / Flag | Purpose | Use Case |
| :--- | :--- | :--- |
| `-h` | Displays the help and usage guide. | Checking available script parameters and syntax. |
| `-f FILE` | Specifies path to input `plugins.yaml` (can be passed multiple times or set to `-` for stdin). | Reading plugin declarations from single/multiple files or piped input. |
| `-p PLUGINS` | Accepts a comma-separated list of plugin IDs (creates temporary `plugins.yaml`). | Quick ad-hoc dependency calculation without editing a YAML file. |
| `-M` | Deduplicates input plugin lists when multiple files or duplicate entries are provided. | Merging multiple plugin lists cleanly without duplicate key errors. |
| `-v VERSION` | Sets the target CloudBees CI version (e.g., `2.568.2.37664`). | Resolving update center envelopes and plugin versions for a specific CI release. |
| `-t TYPE` | Defines CloudBees CI instance type (`mm`, `cm`, `oc`, `oc-traditional`). | Tailoring update center resolution to specific controller/Operations Center roles. |
| `-F FILE` | Custom target output path for resolved `plugins.yaml`. | Writing the final calculated plugin list to a specific directory/filename. |
| `-g FILE` | Custom target path for `plugins-minimal-for-generation-only.yaml`. | Exporting a non-viable starter list for initial project creation. |
| `-G FILE` | Custom target path for `plugins-minimal.yaml`. | Saving a pruned minimal viable plugin list for bundle definitions. |
| `-c FILE` | Custom target path for generated `plugin-catalog.yaml`. | Exporting the online plugin catalog manifest to a specific location. |
| `-C FILE` | Custom target path for generated `plugin-catalog-offline.yaml`. | Exporting the offline/air-gapped plugin catalog manifest. |
| `-N` | Disables plugin dependency resolution and generates Plugin Catalog only. | Fast catalog generation when dependencies are already pre-calculated or ignored. |
| `-d` | Downloads plugin binaries (`.hpi`/`.jpi`) to the local disk cache. | Preparing offline plugin artifacts or enabling binary inspection by exec-hooks. |
| `-D STRING` | Sets offline download URL pattern using `PNAME` and `PVERSION` placeholders. | Configuring download URLs for air-gapped repositories (e.g., Nexus, Artifactory). |
| `-e FILE` | Specifies an executable hook script called when processing 3rd-party plugins. | Automating plugin upload/mirroring to internal artifact managers during processing. |
| `-i` | Includes optional dependencies in the output `plugins.yaml`. | Ensuring all optional plugin capabilities and features are transitively installed. |
| `-I` | Includes core/envelope bootstrap dependencies in `plugins.yaml`. | Explicitly listing bundled CloudBees CI base plugins in the generated output. |
| `-H` | Disables standard boilerplate header comments in generated YAML files. | Producing clean YAML files for automated downstream parsing or pipeline consumption. |
| `-m STYLE` | Sets metadata comment style in output YAML (`line` or `none`). | Adding inline metadata comments (tier, scope) or stripping comments entirely. |
| `-A` | Uses plugins tagged with `# src` comments as root inputs for calculation. | Calculating transitive dependencies strictly from user-specified root plugins. |
| `-s` | Creates a minimal plugin list by stripping bootstrap and transitive dependencies. | Maintaining lightweight root plugin lists in Configuration as Code (CasC) bundles. |
| `-S` | Queries update center advisories to flag known security vulnerabilities (CVEs). | Auditing plugin lists for security compliance and open CVE warnings. |
| `-u` | Includes plugin download URLs as comments in `plugins.yaml`. | Providing full traceability of artifact locations within generated files. |
| `-R` | Bypasses local Update Center JSON cache and forces a fresh download. | Fetching updated plugin metadata or recovering from stale update center caches. |
| `-V` | Enables verbose debug logging to stderr. | Troubleshooting script execution, regex matching, or dependency graph resolution. |

### Key Environment Variables

| Variable | Purpose | Use Case |
| :--- | :--- | :--- |
| `PLUGIN_YAML_CUSTOM_HEADER` | Overrides the default boilerplate header in generated YAML files. | Injecting custom license or corporate compliance headers into output files. |
| `REFRESH_UC_MINUTES` | Sets cache time-to-live (in minutes) for Update Center metadata (default: `360`). | Adjusting cache freshness thresholds during automated or frequent CI runs. |
| `ADD_TS` | Enables timestamp prefixing in log output (`1` to enable). | Performance profiling and tracing execution duration of script phases. |

---

## Plugin Metadata Types & Categories

| Category Tag | Name | Purpose & Definition |
| :--- | :--- | :--- |
| `cap` | CloudBees Assurance Program Plugin | Verified plugin included within the official CloudBees envelope distribution for the target release version. |
| `3rd` | 3rd-Party Plugin | Non-envelope/community plugin outside CAP, requiring definition in `plugin-catalog.yaml`. |
| `old` | Deprecated Plugin | Plugin marked as deprecated or unmaintained in the Update Center. |
| `cve` | Security Vulnerability | Plugin with open security issues or active CVE advisories. |
| `bst` | Bootstrap Plugin | Core plugin pre-installed by default in the CloudBees CI base image distribution. |
| `dep` | Transitive Dependency | Secondary plugin installed automatically because another plugin requires it as a prerequisite. |
| `src` | Source / Root Plugin | Explicitly declared top-level plugin requested by the user in the input `plugins.yaml`. |

### Key Differences: `bst` vs. `src` vs. `dep`

- **`src` (Source / Root Plugin):** Top-level plugins explicitly declared by administrators in their original `plugins.yaml`. They represent the intentional functional requirements of the controller and serve as root nodes when calculating dependencies (`-A` flag).
- **`bst` (Bootstrap Plugin):** Base plugins pre-packaged out-of-the-box inside the CloudBees CI WAR/container distribution. Because they are already present in the base image, they can be pruned when generating minimal viable plugin lists (`-s` flag).
- **`dep` (Transitive Dependency Plugin):** Required helper plugins pulled in automatically to satisfy dependency requirements of `src` or `bst` plugins.

---

# Output Files Summary (`run.sh`)

The script generates primary target manifests in `target/${CI_VERSION}/${CI_TYPE}/` (or custom locations specified via flags) and intermediate analysis artifacts in `target/${CI_VERSION}/${CI_TYPE}/generated/`.

### Primary Output Manifests

| Output File | Default Path / Flag | Purpose | Use Case |
| :--- | :--- | :--- | :--- |
| `plugins.yaml` | `target/${CI_VERSION}/${CI_TYPE}/plugins.yaml` (or `-F`) | Complete resolved plugin list with calculated transitive dependencies and optional metadata comments (`cap`, `3rd`, `cve`, `dep`, `src`, `bst`). | Mounted/used in CloudBees CI CasC bundle definitions to install all required plugins on a controller. |
| `plugin-catalog.yaml` | `target/${CI_VERSION}/${CI_TYPE}/plugin-catalog.yaml` (or `-c`) | CloudBees Plugin Catalog manifest defining 3rd-party and custom plugin versions to be made available to controllers. | Configured on Operations Center or Controller to govern and authorize non-envelope/3rd-party plugin installations. |
| `plugin-catalog-offline.yaml` | `target/${CI_VERSION}/${CI_TYPE}/plugin-catalog-offline.yaml` (or `-C`) | Offline variation of `plugin-catalog.yaml` with plugin download URLs modified to point to internal repos or custom URL patterns. | Used in air-gapped / offline CloudBees CI environments without direct internet access. |
| `plugins-minimal.yaml` | `target/${CI_VERSION}/${CI_TYPE}/plugins-minimal.yaml` (or `-G`) | Pruned minimal viable `plugins.yaml` with bootstrap plugins and redundant transitive dependencies automatically stripped out (`-s`). | Maintaining clean, lightweight CasC plugin definitions without cluttering root files with secondary dependencies. |
| `plugins-minimal-for-generation-only.yaml` | `target/${CI_VERSION}/${CI_TYPE}/plugins-minimal-for-generation-only.yaml` (or `-g`) | Non-viable starter plugin list containing strictly top-level source plugins. | Used as a static starter template for initializing new plugin bundle configurations. |

### Intermediate & Analysis Artifacts (`target/${CI_VERSION}/${CI_TYPE}/generated/`)

| Output File / Pattern | Purpose | Use Case |
| :--- | :--- | :--- |
| `deps-processed-tree-single.txt` | Single-line dependency tree representing parent-to-child plugin relationships (`parent -> dep1 -> dep2`). | Used with helper shell functions (`pDeps`, `pDepsP`, `pDeps3rd`) to trace why specific plugins were included. |
| `deps-all-expected-post-startup.txt` | Flat list of all plugins (envelope base + user plugins + transitive dependencies) expected after controller boot. | Validating post-startup controller state and auditing full installed plugin inventories. |
| `deps-processed-non-top-level.txt` | List of plugins pulled in strictly as secondary/transitive dependencies. | Identifying candidate plugins eligible for removal from top-level declarations. |
| `deps-processed-results.yaml` | Detailed YAML file capturing evaluation state and metadata per processed plugin. | Troubleshooting complex dependency calculations and debugging script logic. |
| `update-center-online.json` | Extracted and formatted JSON of the CloudBees Update Center metadata for target `CI_VERSION`. | Primary lookup database used by `run.sh` to resolve plugin versions, dependencies, and SHA/URLs. |
| `update-center-online.json.envelope.json` | Extracted CloudBees CI envelope manifest containing core scope definitions. | Identifying core envelope plugins versus external 3rd-party plugins. |
| `update-center-online.json.envelope.json.bootstrap.txt` | List of core bootstrap plugins bundled in the target CloudBees CI image. | Filtering out base plugins that do not need explicit installation entries. |
| `update-center-online.json.tier.3rd-party.txt` | List of 3rd-party plugins present in the requested plugin list. | Identifying plugins that require entry into `plugin-catalog.yaml`. |
| `update-center-online.json.deprecated.txt` | List of plugins flagged as deprecated by the Update Center. | Auditing plugin lists for obsolete or unmaintained plugins. |

---

# Create baseline plugin dependency file

Can be used to declare just the required root plugins in your CasC bundle.

./run.sh -f andreas-plugins-mm-basic.yaml  -t mm -sA  -R -m line

## No bootstrap or dependencies in the list

cat target/2.568.2.37664/mm/plugins-minimal.yaml

# Add download URLs to the plugin catalog

## with bootstrap plugins,including required and optional dependencies

./run.sh -v 2.568.2.37664 -t mm -f plugin-requested.yaml -i -I -d -u

## with only requested plugins (no bootstrap), including required and optional dependencies

./run.sh -v 2.568.2.37664 -t mm -f plugin-requested.yaml -A -i -I -d -u

 cat target/2.568.2.37664/mm/plugins.yaml

## with only requested plugins (no bootstrap), including required only dependencies

 ./run.sh -v 2.568.2.37664 -t mm -f plugin-requested.yaml -A -d -u -I

 cat target/2.568.2.37664/mm/plugins.yaml
