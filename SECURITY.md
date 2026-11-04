# Security policy

## Reporting a vulnerability

Please report security issues privately, using GitHub's **Report a vulnerability** (Security ▸
Advisories) on this repository, rather than in a public issue. Include:

- what is affected;
- how to reproduce it;
- the impact you expect.

We aim to acknowledge reports within a few working days.

## What the app does with data

- PlanOpsis Mobile runs entirely on the device. It makes no network requests and has no accounts,
  analytics or telemetry.
- Projects, captures and attachments are stored in the app's own container. Attachments and
  delivery packages are hash-verified.
- The camera is used for LiDAR scanning and for photographing plans. The photo library is read only
  through the system picker, and only for the photo the user chooses.

## Secrets policy

- **No secrets in the repository or its history.** No passwords, API keys, tokens, private keys,
  certificates or provisioning profiles. The app needs none.
- **Configuration stays local.** It goes in a `.env` file (git-ignored), with placeholders only in
  [`.env.example`](.env.example). [`.gitignore`](.gitignore) excludes `.env*`, key and certificate
  files (`*.pem`, `*.key`, `*.p8`, `*.p12`, `*.cer`) and provisioning profiles.
- **If a secret is ever committed:**
  1. Revoke or rotate it at its issuer first.
  2. Remove it from the whole history (for example with `git filter-repo`).
  3. Force-push, and ask everyone with a clone to re-clone.

  Deleting it in a new commit is not enough.

### Checking the repository

The history was last checked on 2026-11-04. Every version of every file was scanned with
[`detect-secrets`](https://github.com/Yelp/detect-secrets), plus pattern searches for cloud keys,
GitHub tokens, private-key blocks and credential assignments. Nothing was found. The only matches
were Xcode object identifiers and SHA-256 test vectors.

To repeat the check:

```sh
python3 -m venv .venv-scan && .venv-scan/bin/pip install detect-secrets
.venv-scan/bin/detect-secrets scan --all-files .      # the current tree
# Every file version in the history:
git rev-list --all --objects | awk 'NF==2' | while read sha path; do
  [ "$(git cat-file -t "$sha")" = blob ] && git cat-file -p "$sha" | grep -nEH --label="$path" \
    'BEGIN [A-Z ]*PRIVATE KEY|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|sk-[A-Za-z0-9]{20,}|xox[baprs]-' -
done
```

## Personal and customer data

Samples and test fixtures are synthetic. See the data rules in [CONTRIBUTING.md](CONTRIBUTING.md).
