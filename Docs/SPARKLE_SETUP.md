# Sparkle auto-update setup

End-to-end runbook for getting Humdrum's Sparkle 2 integration online.
Do this **once**, in order. The code side is already wired — what's
left is the infrastructure: keys, GitHub Actions, the appcast, and
making the repo public so end users' Macs can actually hit the feed.

> **Order matters.** Don't publish a release (step 5) until steps 1–4
> are done, and don't flip the repo to public (step 6) until you've
> verified there are no secrets in history.

---

## Prerequisites

You'll need:

- A Mac with the Developer ID signing cert + notary profile already
  working (`./build-app.sh` currently succeeds end-to-end → you're fine).
- Admin access to the GitHub repo.
- Apple Developer account credentials (Apple ID, Team ID, an
  app-specific password).
- `gh` CLI installed and authenticated (`brew install gh && gh auth login`).

---

## 1. Generate Sparkle's ed25519 signing key

Sparkle 2 verifies every downloaded update against an ed25519 signature
in the appcast. The private key stays on your machine + in GitHub
secrets; the **public** key goes into `Info.plist`.

```bash
# Install Sparkle's tools (one-time). Homebrew is easiest:
brew install --cask sparkle

# Or grab the tools bundle from a Sparkle release:
#   https://github.com/sparkle-project/Sparkle/releases
# Unzip, and you'll find `bin/generate_keys` and `bin/sign_update`.

# Generate the keypair. Sparkle stashes the PRIVATE key in your login
# keychain automatically and prints the PUBLIC key to stdout.
generate_keys
```

The output looks like:

```
A key has been generated and saved in your keychain. Add the public key
to your Info.plist in a SUPublicEDKey entry as:

  abc123…verylongbase64string==
```

**Do two things with this output:**

1. Copy the public key string and paste it into `Info.plist` as the
   value of `SUPublicEDKey` (replacing the `REPLACE_WITH_YOUR_SPARKLE_ED_PUBLIC_KEY`
   placeholder).
2. Export the private key for CI. Still in the Sparkle tools directory:
   ```bash
   generate_keys -x sparkle_ed25519.private
   cat sparkle_ed25519.private
   ```
   Copy the full contents (including the `-----BEGIN...` / `-----END...`
   markers). You'll paste this into GitHub Secrets in step 3.

> ⚠️ The private key is also in your login keychain under "Sparkle
> Ed25519" — don't delete it. It's what `sign_update` uses when you
> run it locally.

## 2. Pick where the appcast will live

The `SUFeedURL` in `Info.plist` currently points to
`https://aaronellis.github.io/humdrum/appcast.xml`. This works if the
repo is named `humdrum` and you turn on **GitHub Pages** → serve from
the `gh-pages` branch.

If you prefer a different URL (custom domain, Netlify, S3, CloudFront),
update `Info.plist` now **before** your first release. Changing it
later means a mandatory manual update for anyone who installed an
earlier build.

### Enable GitHub Pages

1. Push a placeholder `gh-pages` branch:
   ```bash
   git checkout --orphan gh-pages
   git rm -rf .
   echo "<h1>Humdrum updates</h1>" > index.html
   git add index.html
   git commit -m "init gh-pages"
   git push origin gh-pages
   git checkout main
   ```
2. GitHub → repo → **Settings → Pages**. Source: `gh-pages`, folder: `/`.
   Wait ~30s for the first deploy. You should see
   `https://<user>.github.io/<repo>/` go live.

## 3. Add GitHub Secrets

Repo → **Settings → Secrets and variables → Actions → New repository secret**.
Add each of these:

| Name | Value | Where it comes from |
|---|---|---|
| `APPLE_ID` | `aaron.j.ellis@gmail.com` (your Apple ID) | Apple account |
| `APPLE_TEAM_ID` | 10-char team ID (e.g. `ABCDE12345`) | `security find-identity -v -p codesigning` — the ID is inside the parentheses |
| `APPLE_APP_SPECIFIC_PASSWORD` | 4×4 password (`xxxx-xxxx-xxxx-xxxx`) | https://appleid.apple.com → Sign-In & Security → App-Specific Passwords → Generate |
| `DEVELOPER_ID_P12_BASE64` | Base64 of your Developer ID Application .p12 export | See export steps below |
| `DEVELOPER_ID_P12_PASSWORD` | The password you set when exporting the .p12 | You set this in Keychain Access |
| `SPARKLE_ED_PRIVATE_KEY` | Full contents of `sparkle_ed25519.private` | Step 1 above |

### Exporting your Developer ID cert to a .p12

```bash
# Keychain Access → login keychain → My Certificates. Right-click the
# "Developer ID Application: Your Name (TEAMID)" entry → Export…
#   • File format: Personal Information Exchange (.p12)
#   • Set a strong password — this becomes DEVELOPER_ID_P12_PASSWORD
#
# Then base64-encode it for the secret:
base64 -i ~/Desktop/DeveloperID.p12 | pbcopy
# Now paste into the DEVELOPER_ID_P12_BASE64 secret.
rm ~/Desktop/DeveloperID.p12        # don't leave the .p12 on disk
```

### Quick verification

```bash
gh secret list
# Should show all six names. Values are hidden — that's fine.
```

## 4. Create the release pipeline

Copy the YAML below to `.github/workflows/release.yml`. It runs on any
tag matching `v*.*.*`, builds + signs + notarizes + staples the app,
signs the zip with the Sparkle ed25519 key, publishes a GitHub Release
with the zip as an asset, and updates `appcast.xml` on the `gh-pages`
branch.

```yaml
name: release

on:
  push:
    tags:
      - 'v*.*.*'

jobs:
  build-and-release:
    runs-on: macos-14
    permissions:
      contents: write   # needed for gh release create + gh-pages push

    steps:
      - name: Checkout
        uses: actions/checkout@v4
        with:
          fetch-depth: 0     # version bumping reads git history

      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode_15.4.app

      - name: Import Developer ID signing cert
        env:
          P12_BASE64:    ${{ secrets.DEVELOPER_ID_P12_BASE64 }}
          P12_PASSWORD:  ${{ secrets.DEVELOPER_ID_P12_PASSWORD }}
        run: |
          set -euo pipefail
          KEYCHAIN=build.keychain
          KEYCHAIN_PW=$(openssl rand -hex 16)
          security create-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
          security default-keychain -s "$KEYCHAIN"
          security unlock-keychain -p "$KEYCHAIN_PW" "$KEYCHAIN"
          security set-keychain-settings -lut 7200 "$KEYCHAIN"

          echo "$P12_BASE64" | base64 --decode > /tmp/cert.p12
          security import /tmp/cert.p12 -k "$KEYCHAIN" \
            -P "$P12_PASSWORD" -T /usr/bin/codesign
          security set-key-partition-list -S apple-tool:,apple:,codesign: \
            -s -k "$KEYCHAIN_PW" "$KEYCHAIN"
          rm /tmp/cert.p12

      - name: Set up notarytool credentials
        env:
          APPLE_ID:   ${{ secrets.APPLE_ID }}
          TEAM_ID:    ${{ secrets.APPLE_TEAM_ID }}
          APP_PW:     ${{ secrets.APPLE_APP_SPECIFIC_PASSWORD }}
        run: |
          xcrun notarytool store-credentials humdrum-notary \
            --apple-id "$APPLE_ID" \
            --team-id  "$TEAM_ID" \
            --password "$APP_PW"

      - name: Build + sign + notarize + staple
        env:
          NOTARY_PROFILE: humdrum-notary
        run: ./build-app.sh

      - name: Install Sparkle tools
        run: |
          brew update
          brew install --cask sparkle
          # Homebrew drops sign_update into /opt/homebrew/Caskroom/sparkle/*/bin
          SIGN_UPDATE=$(find /opt/homebrew/Caskroom/sparkle -name sign_update | head -n1)
          echo "SIGN_UPDATE=$SIGN_UPDATE" >> "$GITHUB_ENV"

      - name: Sparkle-sign the zip
        env:
          ED_PRIVATE_KEY: ${{ secrets.SPARKLE_ED_PRIVATE_KEY }}
        run: |
          set -euo pipefail
          echo "$ED_PRIVATE_KEY" > /tmp/sparkle.key
          # sign_update prints e.g.:
          #   sparkle:edSignature="..." length="..."
          SIG_LINE=$("$SIGN_UPDATE" -f /tmp/sparkle.key Humdrum.zip)
          rm /tmp/sparkle.key
          echo "SPARKLE_SIG=$SIG_LINE" >> "$GITHUB_ENV"

      - name: Read version from the bundle
        run: |
          SHORT=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
                    Humdrum.app/Contents/Info.plist)
          BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' \
                    Humdrum.app/Contents/Info.plist)
          echo "SHORT_VERSION=$SHORT" >> "$GITHUB_ENV"
          echo "BUILD_VERSION=$BUILD" >> "$GITHUB_ENV"

      - name: Publish GitHub Release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "$GITHUB_REF_NAME" Humdrum.zip \
            --title "Humdrum $GITHUB_REF_NAME" \
            --notes "Auto-generated release. See appcast.xml for update details."

      - name: Checkout gh-pages
        uses: actions/checkout@v4
        with:
          ref: gh-pages
          path: gh-pages

      - name: Update appcast.xml
        run: |
          set -euo pipefail
          cd gh-pages
          DOWNLOAD_URL="https://github.com/${GITHUB_REPOSITORY}/releases/download/${GITHUB_REF_NAME}/Humdrum.zip"
          ZIP_SIZE=$(stat -f%z ../Humdrum.zip)
          PUB_DATE=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

          # First release? Scaffold the file.
          if [ ! -f appcast.xml ]; then
            cat > appcast.xml <<EOF
          <?xml version="1.0" encoding="utf-8"?>
          <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
            <channel>
              <title>Humdrum Updates</title>
              <link>https://github.com/${GITHUB_REPOSITORY}</link>
              <description>Latest Humdrum releases.</description>
              <language>en</language>
            </channel>
          </rss>
          EOF
          fi

          # Prepend a new <item> under <channel>. Using python to avoid
          # brittle sed/awk gymnastics on XML.
          python3 <<PY
          import xml.etree.ElementTree as ET
          import re, sys, os

          ET.register_namespace('sparkle', 'http://www.andymatuschak.org/xml-namespaces/sparkle')
          tree = ET.parse('appcast.xml')
          channel = tree.find('channel')

          item = ET.Element('item')
          ET.SubElement(item, 'title').text = "Version ${SHORT_VERSION}"
          ET.SubElement(item, 'pubDate').text = "${PUB_DATE}"
          ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}version').text = "${BUILD_VERSION}"
          ET.SubElement(item, '{http://www.andymatuschak.org/xml-namespaces/sparkle}shortVersionString').text = "${SHORT_VERSION}"

          # Parse the `sparkle:edSignature="…" length="…"` line into attrs.
          sig_line = os.environ['SPARKLE_SIG'].strip()
          attrs = dict(re.findall(r'(\w+(?::\w+)?)="([^"]+)"', sig_line))
          attrs['url'] = "${DOWNLOAD_URL}"
          attrs['length'] = "${ZIP_SIZE}"
          attrs['type'] = 'application/octet-stream'
          ET.SubElement(item, 'enclosure', attrib=attrs)

          channel.insert(0, item)   # newest first
          tree.write('appcast.xml', encoding='utf-8', xml_declaration=True)
          PY

          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add appcast.xml
          git commit -m "release: ${GITHUB_REF_NAME}"
          git push origin gh-pages
```

### Cutting a release

The ritual has four steps, in order. Skipping any of them produces a
worse release — the workflow doesn't enforce them, by design (the
shaping is a human decision), but the result is visible in the Sparkle
update sheet your users see.

**1. Review what's going in.**

```bash
# What changed since the previous tag?
PREV=$(git describe --tags --abbrev=0 --match 'v*.*.*' 2>/dev/null || true)
git log --oneline ${PREV:-HEAD~50}..HEAD
git diff --stat ${PREV:-HEAD~50}..HEAD
```

Read both. Note the user-facing themes — new features, behavior
changes, notable fixes — and which commits are internal-only (CI
work, refactors, doc tweaks).

**2. Write user-facing release notes.**

Drop them at `RELEASE_NOTES/<tag>.md`. Treat this like a
mini-launch announcement, not a changelog dump:

- Lead with what's *new* — the feature a user could try right now.
- Group by theme, not by commit.
- Use plain, value-forward language — *"Push-to-talk: hold ⌥Space to
  speak, release to paste"*, not *"feat(mutter): PTT activation
  surface"*.
- Bold the feature names so they scan.
- End with a `**Full Changelog**:` link to
  `https://github.com/<repo>/commits/<tag>` — Sparkle's update sheet
  shows this for the curious.

If you find yourself stuck, ask Claude to draft from the `git log`
output — it's good at the shaping pass and you edit-to-taste from
there. See `RELEASE_NOTES/v0.2.0.md` for the inaugural example.

The release workflow prefers `RELEASE_NOTES/<tag>.md` if present and
falls back to a raw commit log if missing — falling back is the
**should-not-happen** path; the CI run will emit a warning when it
does.

**3. Bump the version + tag.**

```bash
# Bump the short version in Info.plist manually (e.g. 0.2.0 → 0.3.0).
# CFBundleVersion is auto-bumped by build-app.sh, don't touch it.

git add Info.plist RELEASE_NOTES/v0.3.0.md
git commit -m "release 0.3.0"
git tag v0.3.0
git push origin main v0.3.0
```

**4. Watch + verify.**

In the **Actions** tab, follow the release run. On success:
- A new GitHub Release appears with `Humdrum.zip` attached and your
  curated notes as the body.
- `gh-pages/appcast.xml` has a new `<item>` for this version
  (existing same-version items are de-duped automatically).
- `https://<user>.github.io/<repo>/appcast.xml` serves the update
  feed.

Existing users' copies of Humdrum will pick up the new version on
their next scheduled check, or via **App menu → Check for
Updates…**.

## 5. Smoke-test the updater locally

Before flipping the repo to public, verify that Sparkle actually
validates and installs updates end-to-end:

1. Build locally with `./build-app.sh` and install the resulting
   `Humdrum.app` to `/Applications`.
2. Run it. Open **App menu → Check for Updates…**. With no published
   release yet you should see "You're up to date!" — this confirms
   Sparkle can fetch the appcast URL and the public key lines up.
3. Cut a release (step 4 above) with a higher short version number
   than the one you installed.
4. Back in the installed app, **Check for Updates…** again. Sparkle
   should find the new version, show its release-notes sheet, and
   download + install when you confirm.

If the update is rejected with "signature does not match":
- The `SUPublicEDKey` in `Info.plist` doesn't match the private key
  CI is using. Regenerate with `generate_keys`, update both the
  plist and `SPARKLE_ED_PRIVATE_KEY` secret, re-release.

If Sparkle can't fetch the appcast:
- Confirm `SUFeedURL` matches your GitHub Pages URL exactly (no
  trailing slash, correct casing).
- `curl -I` the URL — should return 200.

## 6. Make the repo public safely

Going public means the entire git **history** becomes readable, not
just `HEAD`. Audit for leaks first.

### 6a. Audit with automated scanners

```bash
# gitleaks: catches AWS/Apple/GitHub token formats, private keys, etc.
brew install gitleaks
gitleaks detect --source . --log-opts="--all"

# trufflehog: verifies live secrets (will ping APIs to test validity).
brew install trufflehog
trufflehog git file://. --only-verified
```

Fix anything either tool flags. Common hits to watch for:
- `.env` files with API keys.
- `.p12` or `.cer` certificates committed by mistake.
- Apple app-specific passwords or team IDs in docs/scripts.
- `NOTARY_PROFILE` commits that contain the actual password inline.

### 6b. Manual sweep

```bash
# Big binary blobs that shouldn't be public (models, test fixtures):
git log --all --pretty=format: --name-only --diff-filter=A \
  | sort -u | xargs -I{} bash -c 'test -f "{}" && ls -la "{}" 2>/dev/null' \
  | awk '{ if ($5 > 5000000) print $5, $9 }' | sort -n

# Any file that ever existed with these names?
git log --all --diff-filter=A --name-only --pretty=format: \
  | grep -E '\.(p12|cer|key|env|pem)$|secrets?|password|\.local$' || echo "clean"
```

### 6c. If a secret ever landed in a commit

`git filter-repo` is the modern recommended tool (BFG works too):

```bash
brew install git-filter-repo
# Remove a path from all history:
git filter-repo --path secrets.env --invert-paths
# Or replace a regex across history:
echo "literal:the-leaked-token==>REDACTED" > /tmp/replace.txt
git filter-repo --replace-text /tmp/replace.txt
# Force-push (only safe BEFORE the repo is public):
git push --force --all origin
git push --force --tags origin
```

**If a secret was pushed, treat it as compromised regardless** —
rotate it:
- Apple app-specific password: revoke at appleid.apple.com and make a new one.
- Developer ID cert: revoke in developer.apple.com, create a new one,
  re-export a new .p12, update `DEVELOPER_ID_P12_BASE64` + password.
- Sparkle ed25519: generate a fresh pair with `generate_keys` — but
  this invalidates every prior appcast signature and existing users
  will have to re-install manually. Rotate only if absolutely forced to.

### 6d. Flip the switch

GitHub → **Settings → General → Danger Zone → Change visibility → Public**.

After going public:
- Verify `https://<user>.github.io/<repo>/appcast.xml` is reachable
  without auth (Pages on a private repo requires a Pro plan; on public
  it's free and anonymous).
- `curl -I "$SUFeedURL"` from a network that's never been signed into
  GitHub on your account.

### 6e. Lock down public-repo write paths

- Branch protection on `main`: require pull request review + status
  checks passing.
- Branch protection on `gh-pages`: allow only `github-actions[bot]`
  to push (this is the release workflow's identity).
- Repo → **Settings → Actions → General**: restrict workflow run
  approval to collaborators only.

## 7. Ongoing hygiene

- Never commit anything from `.build/`, `Humdrum.app/`, `Humdrum.zip`,
  or `.build-number`. Confirm `.gitignore` covers all of these.
- When rotating any secret, remember to update the corresponding
  GitHub Secret **and** rerun any in-flight release workflow.
- Tag releases from `main` only (the workflow assumes `checkout`
  will land you on a commit that has `Info.plist` at HEAD).

---

**Done.** After step 5's green smoke test, tagging `v0.x.y` on `main`
is the full "ship a release" ritual. Users will see the update prompt
within a day (scheduled check interval) or instantly if they hit
**Check for Updates…**.
