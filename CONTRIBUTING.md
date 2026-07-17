# Contributing to protocol-apps

## Opening changes

As described in the [README](./README.md#contributing), there are two ways to
contribute:

- Open issues to report bugs and typos, or to suggest new ideas.
- Request to become an official contributor by emailing hello@zama.ai.

Becoming an approved contributor involves signing our Contributor License
Agreement (CLA). Only approved contributors can send pull requests.

## Commit signing (required)

All commits pushed to any branch of this repository must be **cryptographically
signed** (GPG, SSH, or S/MIME). Unsigned commits are rejected at push time — on
feature branches as well as `main` — so set up signing before you push.

Set up signing on every machine you push from:

- **GPG:**
  <https://docs.github.com/en/authentication/managing-commit-signature-verification/generating-a-new-gpg-key>
- **SSH:**
  <https://docs.github.com/en/authentication/managing-commit-signature-verification/about-commit-signature-verification#ssh-commit-signature-verification>
- **Enable auto-signing** so every commit is signed without extra flags:

  ```bash
  # GPG
  git config --global commit.gpgsign true
  git config --global user.signingkey <your-key-id>

  # or SSH
  git config --global gpg.format ssh
  git config --global user.signingkey ~/.ssh/id_ed25519.pub
  git config --global commit.gpgsign true
  ```

Verify with `git log --show-signature -3` — every recent commit should print a
`Good signature` line.

If a pull request contains any unsigned commits, please rebase locally with
signing enabled and force-push before requesting review:

```bash
git rebase --exec 'git commit --amend --no-edit -S' origin/main
git push --force-with-lease
```
