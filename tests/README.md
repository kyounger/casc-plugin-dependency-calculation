# Tests

## Running all tests

Run the full test suite by running:

```sh
./tests/run.sh
```

## Running a single test

Run a single test by passing the test directory name.

```sh
./tests/run.sh simple
```

## Creating or correcting tests

Use the `CORRECT_TESTS=1` environment variable to re-align a test in the case of a feature changing the output of the resulting files.

Create a test by:

- creating the test directory
- adding the appropriate `source-*.yaml` files
- adding a `command.sh` file (see other files for inspiration)
- perform an initial run with `CORRECT_TESTS=1`

For example:

```sh
# create the new test directory
mkdir tests/my-new-test

# using the simple test as a starting point
cp tests/simple/source-plugins.yaml tests/my-new-test/source-plugins.yaml
vim tests/my-new-test/source-plugins.yaml

# using the simple test as a starting point
cp tests/simple/command.sh tests/my-new-test/command.sh
vim tests/my-new-test/command.sh

# create the expected yamls
CORRECT_TESTS=1 ./tests/run.sh my-new-test
```
