# Create a simple plugin-cache backed by a git repository

## Create a git repository

Create a remote git repository using your favourite provider.

## Add the plugins

Copy the plugins directory (usually found at `.cache/plugin-cache/plugins`) into the root of your repository.

Your repository should look something like this:

```sh
❯ tree 
.
└── plugins
    ├── ansible
    │   ├── 148.v6b_13c6de3a_47
    │   │   └── ansible.jpi
    │   └── 174.vfd5323d2b_9d8
    │       └── ansible.jpi
    ├── cloudbees-prometheus
    │   ├── 1.0
    │   │   └── cloudbees-prometheus.jpi
    │   └── 1.2
    │       └── cloudbees-prometheus.jpi
    ├── job-dsl
    │   ├── 1.82
    │   │   └── job-dsl.jpi
    │   └── 1.83
    │       └── job-dsl.jpi
    ├── opentelemetry
    │   ├── 2.11.0
    │   │   └── opentelemetry.jpi
    │   └── 2.13.0
    │       └── opentelemetry.jpi
    ├── ui-samples-plugin
    │   └── 2.0
    └── uno-choice
        └── 2.6.5
            └── uno-choice.jpi

18 directories, 9 files
```

## Create the kubernetes cache deployment

The `template.sh` simply runs `envsubst` against the yaml files.

```sh
# to see the files
GIT_TOKEN=$(cat your_read_only_token) GIT_USER=your-user GIT_REPO=https://github.com/some-owner/plugin-cache ./template.sh

# to apply
GIT_TOKEN=$(cat your_read_only_token) GIT_USER=your-user GIT_REPO=https://github.com/some-owner/plugin-cache ./template.sh | kubectl apply -f -

# to delete
GIT_TOKEN=$(cat your_read_only_token) GIT_USER=your-user GIT_REPO=https://github.com/some-owner/plugin-cache ./template.sh | kubectl delete -f -

# etc...
```
