# Distribution

Nightdrive ships as a notarized Developer ID download that updates itself with
[Sparkle](https://sparkle-project.org). Releases are published to the public
`felixrieseberg/nightdrive` repository, which is also the update feed — the
app reads `releases/latest/download/appcast.xml`, so publishing a release *is*
the rollout.

## Versioning

An annotated Git tag on the release commit is the source of truth. Its form is
`v<marketing-version>+<build>`, for example `v1.0.0+2`:

- `1.0.0` becomes `CFBundleShortVersionString`;
- `2` becomes `CFBundleVersion`, which Sparkle compares — it must increase
  with every release.

Never create or move a release tag by hand; `make ship` creates it after the
artifacts pass validation. From-source builds keep the placeholder `0.0.0 (0)`
in `Resources/Info.plist` and never check for updates.

## One-time setup

The release Mac needs:

1. a **Developer ID Application** signing identity in the login keychain;
2. notary credentials stored as `nightdrive-notary`:

   ```bash
   xcrun notarytool store-credentials nightdrive-notary
   ```

3. a Sparkle EdDSA key pair generated once with
   `.build/artifacts/sparkle/Sparkle/bin/generate_keys`. The private key stays
   in the login keychain and signs each update — back it up; losing it means
   shipped apps can no longer verify updates. Pass the printed public key as
   `SPARKLE_PUBLIC_ED_KEY` when releasing; `generate_keys -p` prints it again.

## Cutting a release

Start from a clean, pushed `main`. Choose a build number greater than every
published one and write `ReleaseNotes/<version>.md` first — it becomes both
the Sparkle update description and the GitHub release body, and the release
fails without it. Then:

```bash
make verify-full
SPARKLE_PUBLIC_ED_KEY=… make ship RELEASE_TAG=v1.0.0+2 SHIP_FLAGS=--dry-run
SPARKLE_PUBLIC_ED_KEY=… make ship RELEASE_TAG=v1.0.0+2
```

`make ship` preflights credentials, repository state, and version monotonicity;
builds, signs, notarizes, and staples the app; then pauses before anything is
public. At that gate, launch the printed app from `dist/`, check its About
version and the workflows you changed, and type the full proposed tag to
continue — without committing, pulling, or pushing in the meantime. It then
creates and pushes the annotated tag and publishes the GitHub release with the
versioned zip, a stable `Nightdrive.zip` alias, and `appcast.xml`.

If a dry run or the build fails, fix the problem and rerun with the same tag;
nothing was published. After success, launch a previous build and confirm that
Sparkle offers the new version.

## Rolling back

```bash
make unship RELEASE_TAG=v1.0.0+2   # UNSHIP_FLAGS=--dry-run to preview
```

This deletes the public release and its tags, pointing the update feed back at
the previous release. Users who already updated stay on the pulled version —
Sparkle never offers a lower build — so ship a higher build to move them off.

## Individual stages

Each stage runs on its own when debugging, from the annotated tag at `HEAD`:

```bash
SPARKLE_PUBLIC_ED_KEY=… make developerid   # build, sign, notarize, staple, zip
make appcast                               # sign and describe the update
make publish                               # create the public GitHub release
```

Without `APP_SIGN_IDENTITY`, `scripts/package-developer-id.sh` builds an
ad-hoc-signed archive for structural validation — the quickest way to check
that packaging still works.
