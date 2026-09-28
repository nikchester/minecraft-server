# Contributing

## Change delivery

1. Start each feature, bug fix, or other change on its own branch created from
   the latest `dev`. Keep unrelated changes in separate branches and pull requests.
2. Run the applicable checks locally (below). Open a pull request from the
   change branch into `dev` only after local tests pass.
3. Wait for the `dev` pull request's required CI checks and the repository
   owner's approval before merging it into `dev`. Confirm the resulting `dev`
   CI run succeeds as well.
4. Only after `dev` is green, open a pull request from `dev` into `main`.
   The repository owner reviews and approves this pull request manually before
   it is merged. Do not merge to `main` or trigger production deployment on
   the owner's behalf.

Production deployment is tied to `main`; a successful local or `dev` test run
does not by itself authorize a production rollout.

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
integration command (`bash test/local/run-all.sh`) for pull requests and pushes
to `main` and `dev`. The integration job has no production credentials and
does not connect to Discord or other production services. DiscordSRV is checked
for local startup only; live bot authentication and chat/voice behavior remain
manual verification in `test/paper-local/`.

Test architecture and rationale live in `SPEC.md` §11 and §12.5. Harness
mechanics and scenario-writing guidance live in `test/local/README.md`.
