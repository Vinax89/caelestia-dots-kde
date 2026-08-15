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

The `CAELESTIA_INTEGRATION_PACKAGES` override is intentionally undocumented for
end users. It changes only the requested package set and third-party repository
setup; package installation, retry, and installed-state checks remain the
production code paths.
