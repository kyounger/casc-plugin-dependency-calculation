# Integration with `pre-commit`

Using [pre-commit](https://pre-commit.com/) helps ensure you do not check in inconsistent bundles.

For example, if you make a change to your raw bundle but forget to run the appropriate `cascgen` command.

To do this, simply add the following pre-commit configuration to the root of your bundles repository.

```yaml
repos:
  - repo: local
    hooks:
      - id: check-effective-bundles
        name: check-effective-bundles
        entry: /usr/bin/env
        args: [cascgen, pre-commit]
        language: script
        pass_filenames: false
        verbose: false
        always_run: true
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: v4.4.0
    hooks:
      - id: check-yaml
        files: .*\.(yaml|yml)$
```

## Example

Make a change to a bundle

```sh
❯ git --no-pager diff
diff --git a/raw-bundles/controller-a/jcasc/jenkins.yaml b/raw-bundles/controller-a/jcasc/jenkins.yaml
index a01af6b..f4d0755 100644
--- a/raw-bundles/controller-a/jcasc/jenkins.yaml
+++ b/raw-bundles/controller-a/jcasc/jenkins.yaml
@@ -1,3 +1,3 @@
 ---
 jenkins:
-  systemMessage: "Configured with CasC from ${bundleName}! Hell yeah!"
+  systemMessage: "Configured with CasC from ${bundleName}! This was added without regenerating!"
```

Try and commit...

```sh
❯ gc -m "Adding a new system message" raw-bundles/controller-a/jcasc/jenkins.yaml
check-effective-bundles..................................................Failed
- hook id: check-effective-bundles
- exit code: 1
- files were modified by this hook

Looking for action 'pre-commit'
Setting some vars...
INFO: Setting CI_VERSION according to git branch from command.
Running with:
    DEP_TOOL=/home/sboardwell/bin/cascdeps
    TARGET_BASE_DIR=/home/sboardwell/Workspace/tsmp-falcon-platform/ci-bundles-controllers-git-sync-effective/target
    CACHE_BASE_DIR=/home/sboardwell/Workspace/tsmp-falcon-platform/ci-bundles-controllers-git-sync-effective/.cache
    RAW_DIR=/home/sboardwell/Workspace/tsmp-falcon-platform/ci-bundles-controllers-git-sync-effective/raw-bundles
    EFFECTIVE_DIR=/home/sboardwell/Workspace/tsmp-falcon-platform/ci-bundles-controllers-git-sync-effective/effective-bundles
    CI_VERSION=2.401.2.6
Effective bundles changed - please stage them before committing. Execution log: /tmp/pre-commit.check-effective-bundles.log

check yaml...............................................................Passed
```

View the new diff after pre-commit ran the generate command for us...

```sh
❯ git --no-pager diff
diff --git a/effective-bundles/controller-a/bundle.yaml b/effective-bundles/controller-a/bundle.yaml
index 9b7281d..c6772f6 100644
--- a/effective-bundles/controller-a/bundle.yaml
+++ b/effective-bundles/controller-a/bundle.yaml
@@ -1,7 +1,7 @@
 apiVersion: '1'
 id: 'controller-a'
 description: 'Controller A (version: 2.401.2.6, inheritance: base bundle-a controller-a)'
-version: '40fdaeef37aa94cf9e92c621c1ccdc8f'
+version: '0d1ae0097a09a4b4940d6d5591fce8e5'
 availabilityPattern: ".*test"
 jcascMergeStrategy: 'override'
 jcasc:
diff --git a/effective-bundles/controller-a/jcasc.2.controller-a.jcasc.jenkins.yaml b/effective-bundles/controller-a/jcasc.2.controller-a.jcasc.jenkins.yaml
index a01af6b..f4d0755 100644
--- a/effective-bundles/controller-a/jcasc.2.controller-a.jcasc.jenkins.yaml
+++ b/effective-bundles/controller-a/jcasc.2.controller-a.jcasc.jenkins.yaml
@@ -1,3 +1,3 @@
 ---
 jenkins:
-  systemMessage: "Configured with CasC from ${bundleName}! Hell yeah!"
+  systemMessage: "Configured with CasC from ${bundleName}! This was added without regenerating!"
diff --git a/raw-bundles/controller-a/jcasc/jenkins.yaml b/raw-bundles/controller-a/jcasc/jenkins.yaml
index a01af6b..f4d0755 100644
--- a/raw-bundles/controller-a/jcasc/jenkins.yaml
+++ b/raw-bundles/controller-a/jcasc/jenkins.yaml
@@ -1,3 +1,3 @@
 ---
 jenkins:
-  systemMessage: "Configured with CasC from ${bundleName}! Hell yeah!"
+  systemMessage: "Configured with CasC from ${bundleName}! This was added without regenerating!"
```

Stage the newly changed files...

```sh
❯ git add effective-bundles raw-bundles
```

Now if we run pre-commit, it doesn't complain. Yippeh!

```sh
❯ pre-commit run
check-effective-bundles..................................................Passed
check yaml...............................................................Passed
```
