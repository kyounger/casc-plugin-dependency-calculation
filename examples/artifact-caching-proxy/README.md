# Artifact Caching Proxy for 3rd Party Plugins

We will:

- create the `artifact-caching-proxy` nginx server
- test the connection

## Install `artifact-caching-proxy`

Now you have the values in place you can install the chart with:

```mono
helm upgrade --install my-artifact-caching-proxy --values artifact-caching-proxy-values.yaml jenkins-infra/artifact-caching-proxy --version 0.16.1
```

## Prime the cache

Prime the cache for your list of plugins by using an exec-hook such as in [../exec-hooks/use-nginx-proxy-cache.sh](../exec-hooks/use-nginx-proxy-cache.sh)

This exec-hook gives an example of how the plugin dependency tool can be used to call the cache in advance to allow it to pull the plugins before starting the controller.