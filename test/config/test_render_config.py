import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
RENDERER = ROOT / "scripts" / "render-config.py"


class RenderConfigTests(unittest.TestCase):
    def render(self, source_text: str, *, env=None, secret_dir=None, env_file=None, suffix=".properties"):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / f"source{suffix}"
            output = root / "out" / "rendered.properties"
            source.write_text(source_text, encoding="utf-8")
            command = [sys.executable, str(RENDERER), "--source", str(source), "--output", str(output)]
            if secret_dir:
                command += ["--secret-dir", str(secret_dir)]
            if env_file:
                command += ["--env-file", str(env_file)]
            result = subprocess.run(command, env=env, text=True, capture_output=True)
            rendered = output.read_text(encoding="utf-8") if output.exists() else None
            mode = output.stat().st_mode & 0o777 if output.exists() else None
            return result, rendered, mode

    def test_environment_secret_is_rendered(self):
        env = os.environ.copy()
        env["RCON_PASSWORD"] = "local-test-secret"
        result, rendered, mode = self.render("rcon.password={{RCON_PASSWORD}}\n", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered, "rcon.password=local-test-secret\n")
        if os.name == "posix":
            self.assertEqual(mode, 0o600)

    def test_local_env_file_is_rendered(self):
        with tempfile.TemporaryDirectory() as directory:
            env_file = Path(directory) / ".env"
            env_file.write_text('RCON_PASSWORD="local value"\n', encoding="utf-8")
            result, rendered, _ = self.render("rcon.password={{RCON_PASSWORD}}\n", env_file=env_file)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered, "rcon.password=local value\n")

    def test_runtime_secret_file_is_rendered(self):
        with tempfile.TemporaryDirectory() as directory:
            secret_dir = Path(directory)
            (secret_dir / "rcon_password").write_text("production-fixture", encoding="utf-8")
            result, rendered, _ = self.render("rcon.password={{RCON_PASSWORD}}\n", secret_dir=secret_dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered, "rcon.password=production-fixture\n")

    def test_missing_secret_fails_without_output(self):
        result, rendered, _ = self.render("rcon.password={{RCON_PASSWORD}}\n", env={})
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(rendered)
        self.assertIn("missing secret RCON_PASSWORD", result.stderr)

    def test_newline_secret_is_rejected(self):
        env = os.environ.copy()
        env["RCON_PASSWORD"] = "first\nsecond"
        result, rendered, _ = self.render("rcon.password={{RCON_PASSWORD}}\n", env=env)
        self.assertNotEqual(result.returncode, 0)
        self.assertIsNone(rendered)
        self.assertIn("contains a newline", result.stderr)

    def test_yaml_secret_escapes_single_quotes(self):
        env = os.environ.copy()
        env["AUTHME_MAIL_PASSWORD"] = "value'with'quotes"
        result, rendered, _ = self.render(
            "mailPassword: '{{AUTHME_MAIL_PASSWORD}}'\n",
            env=env,
            suffix=".yml",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(rendered, "mailPassword: 'value''with''quotes'\n")



if __name__ == "__main__":
    unittest.main()
