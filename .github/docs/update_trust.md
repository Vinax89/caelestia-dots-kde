# Update trust model

Stable updates resolve the newest semantic-version release tag and verify the
tag's commit before any checked-out script is executed. The trusted signer is
GitHub's web-flow commit-signing key, fingerprint
`968479A1AFF927E37D1A566BB5690EEEBB952194`.

The verifier downloads the public key over TLS, rejects it unless its complete
fingerprint matches the compiled-in trust anchor, and uses a temporary isolated
GnuPG home. Release automation refuses to tag an unsigned or differently signed
commit. Mutable `main` heads are never installed by the stable updater.

Development updates must also have a trusted commit signature. The bypass
environment variable exists solely for local testing and is never set by the UI
or CI.
