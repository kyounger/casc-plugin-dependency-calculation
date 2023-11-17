# The `src` tag

The `src` tag could also be seen as the `keep-me-at-all-costs` tag.

It tells the script which plugins you wish to keep regardless.

If you create a minimal plugin list (using `-s`) on a clean set of plugins without any `src` tag, the script will automatically append the `# src` tags to all necessary plugins.

More context and information can be found in the example sections:

- the [manual alterations section of the standard workflow example](../workflow-standard-steps/README.md#manual-alterations)
- the [the reasoning behind the src plugins only option](../workflow-standard-steps/README.md#the-reasoning-behind-the--a-source-plugins-only-option)

## Example

Starting with a simple `plugins.yaml`

```yaml
plugins:
- id: beer
- id: ec2-fleet
```

Running `./run.sh -v 2.401.3.3 -f plugins.yaml -s`

...would give you a `plugins-minimal.yaml` like this (note the only "source" or "src" is the original `ec2-fleet` and `beer` plugins)

```yaml
plugins:
  - id: aws-credentials # cap dep
  - id: aws-java-sdk # 3rd dep
  - id: aws-java-sdk-cloudformation # 3rd dep
  - id: aws-java-sdk-codebuild # 3rd dep
  - id: aws-java-sdk-ec2 # cap dep
  - id: aws-java-sdk-ecr # 3rd dep
  - id: aws-java-sdk-ecs # 3rd dep
  - id: aws-java-sdk-efs # 3rd dep
  - id: aws-java-sdk-elasticbeanstalk # cap dep
  - id: aws-java-sdk-iam # 3rd dep
  - id: aws-java-sdk-kinesis # 3rd dep
  - id: aws-java-sdk-logs # 3rd dep
  - id: aws-java-sdk-minimal # cap dep
  - id: aws-java-sdk-sns # 3rd dep
  - id: aws-java-sdk-sqs # 3rd dep
  - id: aws-java-sdk-ssm # 3rd dep
  - id: beer # 3rd src
  - id: ec2-fleet # 3rd src
  - id: ssh-slaves # cap dep
```

Removing the `ec2-fleet` plugin and re-running would remove the plugin and all its dependencies.

However, if you wished, for whatever reason, to keep the `ssh-slaves` plugin regardless, simply append the `src` tag.

```yaml
  ...
  ...
  - id: beer # 3rd src
  - id: ec2-fleet # 3rd src
  - id: ssh-slaves # cap dep src
```

Now, even if you remove the `ec2-fleet` plugin, the `ssh-slaves` will still be kept.

```yaml
  - id: beer # 3rd src
  - id: ssh-slaves # cap src
```
