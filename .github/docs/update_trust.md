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

Accepting this trade is deliberate. The alternative — a maintainer-held signing
key — means key custody, rotation, and a revocation story, and it breaks every
release made through the GitHub UI. If that changes, sign release tags as
annotated signed tags with a maintainer key and pin that fingerprint instead.

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
