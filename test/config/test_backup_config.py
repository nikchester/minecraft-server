import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[2]
VALIDATOR = ROOT / "scripts" / "validate-backup-config.py"
# Disposable credentials, never a production config.
MARKER = "fake-credential-MUST-NOT-APPEAR"
TOKEN = json.dumps({"access_token": MARKER, "refresh_token": MARKER, "extra": 'quote"percent%value'})
CONFIG = f"[gdrive]\ntype = drive\nscope = drive.file\ntoken = {TOKEN}\n"


class BackupConfigTests(unittest.TestCase):
    def check_config(self, config, *, valid, via_env=False):
        command = [sys.executable, str(VALIDATOR)]
        env = os.environ.copy()
        # Never forward the actual workflow config to the test subprocess.
        env.pop("BACKUP_RCLONE_CONFIG", None)
        if via_env:
            env["BACKUP_RCLONE_CONFIG"] = config
            command += ["--env", "BACKUP_RCLONE_CONFIG"]
        result = subprocess.run(command, input=None if via_env else config,
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0 if valid else 1, result.stderr)
        self.assertNotIn(MARKER, result.stdout + result.stderr)
        self.assertNotIn(TOKEN, result.stdout + result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_valid_stdin_and_environment(self):
        self.check_config(CONFIG, valid=True)
        self.check_config(CONFIG, valid=True, via_env=True)

    def test_crlf_comments_and_optional_fields(self):
        self.check_config(("# disposable fixture\n; comment\n" + CONFIG).replace("\n", "\r\n"), valid=True)
        self.check_config(CONFIG + "client_id =\nroot_folder_id =\n", valid=True)
        self.check_config(CONFIG.replace("scope = drive.file\n", ""), valid=True)
        self.check_config(CONFIG.replace("[gdrive]", "[backup-drive]"), valid=True)

    def test_missing_and_ambiguous_remotes(self):
        for config in ("", " \n", CONFIG + "[other]\ntype = drive\n",
                       CONFIG + "[gdrive]\ntype = drive\n", "token = " + TOKEN):
            with self.subTest(config_length=len(config)):
                self.check_config(config, valid=False)

    def test_runtime_incompatible_headers(self):
        for header in ("[]", "[ ]", " [gdrive]", "[gdrive] # comment", "[gdrive ]", "[bad:name]"):
            with self.subTest(header=header):
                self.check_config(CONFIG.replace("[gdrive]", header), valid=False)

    def test_invalid_or_missing_type(self):
        for config in (CONFIG.replace("drive\n", "yandex\n"),
                       CONFIG.replace("type = drive\n", ""),
                       CONFIG + "type = yandex\n"):
            self.check_config(config, valid=False)

    def test_missing_invalid_or_nonrefreshable_token(self):
        for token in ("", MARKER, '{"refresh_token": "' + MARKER,
                      "null", "[]", '"' + MARKER + '"', "{}",
                      '{"refresh_token": null}', '{"refresh_token": 123}',
                      '{"refresh_token": " "}'):
            with self.subTest(token_length=len(token)):
                self.check_config(CONFIG.replace(TOKEN, token), valid=False)
        self.check_config(CONFIG.replace(f"token = {TOKEN}\n", ""), valid=False)

    def test_parser_errors_do_not_echo_secret_lines(self):
        for config in (CONFIG + MARKER, CONFIG + f"[{MARKER}:bad]\n",
                       f"[{MARKER}]\ntype = {MARKER}\ntoken = {TOKEN}\n"):
            self.check_config(config, valid=False)

    def test_workflow_preserves_secret_mapping_and_preflight_order(self):
        workflow = (ROOT / ".github/workflows/deploy.yml").read_text(encoding="utf-8")
        self.assertEqual(workflow.count("BACKUP_RCLONE_CONFIG: ${{ secrets.YANDEX_RCLONE_CONFIG }}"), 2)
        self.assertLess(workflow.index("scripts/validate-backup-config.py --env BACKUP_RCLONE_CONFIG"),
                        workflow.index("- name: Install SSH key"))
        self.assertIn('printf \'%s\' "$BACKUP_RCLONE_CONFIG" | tr -d \'\\r\' >"$secret_dir/rclone.conf"', workflow)
        # Expressions belong only in env mappings, never in shell run blocks.
        in_run = False
        for line in workflow.splitlines():
            if line.startswith("        run: |"):
                in_run = True
            elif line.strip() and not line.startswith("          "):
                in_run = False
            if in_run:
                self.assertNotIn("${{", line)


if __name__ == "__main__":
    unittest.main()
