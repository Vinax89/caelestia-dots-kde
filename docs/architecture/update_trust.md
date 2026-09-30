# Update trust model

## What is verified

Stable updates resolve the newest semantic-version release tag and verify that
tag's commit before any checked-out script is executed. The pinned trust anchor
is GitHub's web-flow commit-signing key, fingerprint
`968479A1AFF927E37D1A566BB5690EEEBB952194`.

The verifier downloads the public key over TLS, rejects it unless its complete
fingerprint matches the pinned anchor, and uses a temporary isolated GnuPG home.
Verification happens before submodules are initialised, so an unverified
`.gitmodules` never drives a fetch. Mutable `main` heads are never installed by
the stable updater.

Development updates must also have a trusted commit signature. The
`CAELESTIA_ALLOW_UNVERIFIED_UPDATE` bypass exists solely for local testing and
is never set by the UI or by CI.

## What the anchor actually proves — and what it does not

This is the part worth being precise about, because the property is weaker than
"the maintainer signed this".

The web-flow key is **GitHub's shared key**. It signs every commit created
through github.com itself: the web editor, the merge button, and the REST API —
for any account, in any repository. So a valid web-flow signature proves:

> this commit object was created by github.com, and has not been altered since.

It does **not** identify who authored it. Anything that can create a commit
through GitHub's own machinery in this repository produces a signature that
passes this check — including a token with `contents: write`.

What actually restricts who can get a commit into a release is therefore not
the signature but repository write access and branch protection. The signature
closes a narrower hole: it prevents a tampered checkout, a hostile mirror, or a
MITM from substituting commit content that the updater would then execute.

## Using a maintainer key instead

The verifier supports a stronger anchor, and prefers it when one is pinned.
Setting it up is three steps:

1. Create a signing key and commit its public half:

   ```bash
   gpg --quick-generate-key "Your Name <you@example.com>" ed25519 sign never
   gpg --armor --export <FINGERPRINT> > .github/release-signing-key.asc
   ```

2. Sign release tags with it: `git tag -s vX.Y.Z -m "..."`. The verifier checks
   an annotated signed tag first and falls back to the commit.

3. Pin the fingerprint. Where you pin it decides how much it is worth:

   * `CAELESTIA_RELEASE_SIGNER` in the environment, or the constant of the same
     name in `src/bin/caelestia-update` — **authoritative**, because the updater
     is installed in `~/.local/bin`, outside the repository it verifies.
   * `RELEASE_SIGNER` in `.github/version.env` — **advisory only**, and the
     standalone verifier warns when it falls back to this. An anchor read out of
     the thing being verified is worth nothing against someone who controls that
     repository; it still detects tampering after a known-good checkout.

Only the fingerprint has to be trusted. The key material is fetched and then
rejected unless it contains that exact fingerprint, so committing the public key
to the repository is safe: swapping it for an attacker's key fails the check.

Until a key is pinned, the web-flow fallback above remains in force. That trade
is deliberate — key custody, rotation and revocation are real costs, and
web-flow still prevents a tampered checkout, a hostile mirror or a MITM from
substituting content the updater would execute.

## Consequences for automation

Because the anchor is web-flow, **CI must not push locally-made commits to a
branch users verify**. A commit created by `git commit` on a runner is
unsigned; landing one at the tip of `main` makes `git verify-commit HEAD` fail
there.

Both workflows that write to the repository therefore commit through the
Contents API (`gh api --method PUT .../contents/...`), which produces a
web-flow-signed commit:

* `version-release.yml` — contributor stats in `.github/README.md`
* `sync-version-files.yml` — the version in `shell/CMakeLists.txt`

If you add a workflow that writes to the repository, use the same mechanism.

## Repository identity

The repository the updater talks to is `REPO` in `.github/version.env`.
Components that run before a checkout exists (`src/bin/caelestia-update`,
`src/bin/caelestia-check-updates`) carry a compiled-in default, and
`.github/scripts/check_repo_identity.py` fails CI whenever such a default drifts
from the canonical value. Override at runtime with `CAELESTIA_REPO`.
