# Releasing

A release is a tag. Everything else is automated by
[`.github/workflows/release.yml`](../.github/workflows/release.yml), which calls
[`scripts/package-release.sh`](../scripts/package-release.sh).

```sh
git tag v0.1.0
git push origin v0.1.0
```

That builds a Release `.app`, zips it, and publishes a GitHub release with the
zip attached. Locally, `make release` does the same build without publishing.

Versions come from the tag: `v0.1.0` becomes `CFBundleShortVersionString` `0.1.0`,
and the commit count becomes `CFBundleVersion`. Nothing in the repo hard-codes a
version, so there is no file to bump.

## Tag format matters

The in-app update check compares the running build's
`CFBundleShortVersionString` against the tag on GitHub's *latest release*, so:

- **Tag as `vX.Y.Z`.** `AppVersion` strips the leading `v`, so `v0.2.0` and the
  bundle's `0.2.0` compare equal. A tag that doesn't parse as numbers is
  ignored, and users are never told about the release.
- **Versions must only go up.** Comparison is numeric per component, so
  `v0.10.0` correctly follows `v0.9.0`.
- **Prereleases are safe.** Mark a release as a prerelease on GitHub and it is
  excluded from `/releases/latest`, so it won't be offered to everyone. A
  `-beta` suffix in the tag also sorts below the final release of the same
  numbers.

## Signing, and why releases are not notarized

Notarization — the thing that makes macOS open an app without complaint —
requires a **paid Apple Developer Program membership** ($99/year). This project
deliberately doesn't have one, so releases are **ad-hoc signed**: a valid
signature structure, but not one Apple vouches for.

What that means in practice:

- Users get a one-time warning on first launch, cleared through *System
  Settings → Privacy & Security → Open Anyway*, or avoided entirely by
  installing with `scripts/install.sh`, which never lets the quarantine flag
  stick. The README and the generated release notes both spell this out.
- Ad-hoc is meaningfully better than unsigned. macOS 15.1 hard-blocks
  applications carrying *no* signature at all; an ad-hoc signature keeps the
  normal "Open Anyway" path available.
- **Homebrew is not an option.** Homebrew ended support for casks that fail
  Gatekeeper checks on 1 September 2026 and removed the `--no-quarantine`
  flag, so ReviewBar cannot ship through the official tap while unnotarized.
- Each build has a different ad-hoc signature, so macOS may treat an updated
  copy as a new app and re-ask for notification permission after an update.

The pipeline still supports notarization, and turns it on by itself the moment
the secrets below exist — nothing in the workflow needs editing to switch. If
that ever happens, the release notes drop the warning section automatically.

| Secrets present | Result | What users see |
| --- | --- | --- |
| none (today) | ad-hoc signature | one-time "Open Anyway", or no warning via the install script |
| certificate only | Developer ID signature | still warns, because the ticket is missing |
| certificate + notary key | signed, notarized, stapled | opens normally |

## Getting a Developer ID certificate

Only relevant if the project ever takes on the $99/year membership; releases
work without it. A free Apple ID cannot issue Developer ID certificates, and
there is no unpaid route to notarization — that is an Apple restriction, not a
limitation of this setup.

1. **Enroll** at [developer.apple.com/programs](https://developer.apple.com/programs/).
   Enrollment as an individual usually clears within a day or two.

2. **Create the certificate.** In Xcode: *Settings → Accounts → your Apple ID →
   Manage Certificates → + → Developer ID Application*. Xcode generates the key
   pair and installs it into your login keychain.

   Confirm it landed:

   ```sh
   security find-identity -v -p codesigning
   ```

   You want the line reading `Developer ID Application: Your Name (TEAMID)`.
   That whole string is your `MACOS_SIGN_IDENTITY`.

3. **Export it for CI.** In *Keychain Access*, find the `Developer ID
   Application` certificate, expand it to confirm it has a private key, then
   right-click → *Export* → `.p12`, and set a strong password. Base64 it:

   ```sh
   base64 -i DeveloperID.p12 | pbcopy
   ```

   Keep the `.p12` and its password somewhere safe — losing the private key
   means revoking and reissuing.

4. **Create a notarization key.** At
   [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api),
   create an API key with the **Developer** role. Download the `.p8` — App Store
   Connect lets you download it exactly once. Note the *Key ID* and the *Issuer
   ID* shown on that page.

   ```sh
   base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
   ```

## Repository secrets

Set these under *Settings → Secrets and variables → Actions*:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the exported `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | the password you set when exporting |
| `MACOS_SIGN_IDENTITY` | `Developer ID Application: Your Name (TEAMID)` |
| `NOTARY_KEY` | base64 of the App Store Connect `.p8` |
| `NOTARY_KEY_ID` | the key's ID |
| `NOTARY_ISSUER_ID` | the issuer UUID from the same page |

Signing and notarization are checked independently, so adding the certificate
secrets alone is a valid intermediate step.

## Signing a release locally

```sh
MACOS_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_KEY_PATH=~/keys/AuthKey_XXXXXXXX.p8 \
NOTARY_KEY_ID=XXXXXXXX \
NOTARY_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx \
scripts/package-release.sh 0.1.0
```

Verify the result before publishing:

```sh
codesign --verify --strict --verbose=2 dist/ReviewBar.app
spctl --assess --type execute --verbose=2 dist/ReviewBar.app
xcrun stapler validate dist/ReviewBar.app
```

`spctl` reporting `accepted / source=Notarized Developer ID` is the goal.

## Why Release and not Debug

`make bundle` builds Debug for development convenience, and Debug carries the
`com.apple.security.get-task-allow` entitlement, which notarization rejects.
Anything distributed must come from `scripts/package-release.sh`, which always
builds Release.
