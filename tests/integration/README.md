# Installer and updater integration tests

Run all supported distributions with:

```sh
bash tests/integration/run-installer-matrix.sh
```

Pass `arch`, `fedora`, or `debian` to run one container. The suite uses each
distribution's real package database and package manager with a small package
set. It covers idempotent install/update, a failed batch followed by retry,
cancellation of an active transaction, and restoration of captured package
state after a simulated downstream failure.

The fixture calls the shared production `install_if_missing` helper for `tree`
and `jq`; it does not run the desktop installer or third-party repository setup.
The container matrix is also part of the Validate workflow.
