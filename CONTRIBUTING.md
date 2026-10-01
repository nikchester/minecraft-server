# Contributing

## Change delivery

1. Start each feature, bug fix, or other change on its own branch created from
   the latest `dev`. Keep unrelated changes in separate branches and pull requests.
2. Run the applicable checks locally (below). Open a pull request from the
   change branch into `dev` only after local tests pass.
3. Wait for all required CI checks on the pull request to pass. A formal GitHub
   review approval is not required; the repository owner merges the pull request
   after the checks pass. CI runs once for the pull request and is not repeated
   just because the pull request was merged.
4. After the change is merged into `dev`, open a promotion pull request from
   `dev` into `main`. Wait for its required CI checks to pass, then the
   repository owner merges it. The merge into `main` starts the production
   deployment automatically. Do not merge pull requests or trigger production
   deployments on the owner's behalf.

Only a merge into protected `main` authorizes a production rollout; a successful
local test or a merge into `dev` does not.

## Before opening a pull request

Run the repository checks available in your environment:

```bash
python3 scripts/validate-repository.py
shellcheck scripts/*.sh
ansible-playbook -i ansible/inventory/production/hosts.example.yml ansible/playbooks/bootstrap.yml --syntax-check
ansible-lint ansible/
```

With Docker Desktop running, run the full integration suite:

```bash
bash test/local/run-all.sh
```

This executes the isolated operational test scenarios, then downloads the
pinned Paper and configured plugin artifacts and verifies that Paper starts
and enables each configured plugin. Containers and ephemeral test data are
removed when the run exits, including on test failure or interruption.

For quicker feedback while editing mocked deploy, backup, restore, or config
behavior, run only the offline-friendly scenarios:

```bash
bash test/local/run-fast.sh
```

The fast suite uses shimmed system services, downloads, and a Minecraft
protocol stub. It does not replace the full Paper/plugin startup check.

## CI behavior

GitHub Actions runs static validation, secret scanning, and the same complete
integration command (`bash test/local/run-all.sh`) for pull requests. Branch
protection requires `validate`, `secret-scan`, and `integration` to pass before
merge. CI does not run a duplicate set of checks after a merge. Merging into
`main` triggers the production deployment workflow directly; that merge is
allowed only after the pull request's required checks pass. The integration job
has no production credentials and does not connect to Discord or other
production services. DiscordSRV is checked for local startup only; live bot
authentication and chat/voice behavior remain manual verification in
`test/paper-local/`.

## Release notes

After a successful production deployment, GitHub Actions creates or updates the
current GitHub Release draft. Before publishing it, the repository owner must
compare the draft with the previous published stable release and ensure that it
covers every change included in `main` since that release. Include only changes
already promoted to `main`; changes that exist only in `dev` belong in a later
release. Remove duplicate entries and stale or empty template text, verify the
SemVer version and release title, and publish the draft manually. Telegram
announcements remain a separate manual step.

Test architecture and rationale live in `SPEC.md` §11 and §12.5. Harness
mechanics and scenario-writing guidance live in `test/local/README.md`.
