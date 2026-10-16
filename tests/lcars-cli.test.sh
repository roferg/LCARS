#!/usr/bin/env bash
# Real isolated installer + executable CLI boundaries. Run from the repo root.
set -euo pipefail
python3 - "$@" <<'PY'
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class CliTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="lcars-cli.", dir=".")
        cls.work = Path(cls.scratch.name).resolve()
        cls.prefix = cls.work / "install"
        cls.env = dict(os.environ, LCARS_INSTALL_PREFIX=str(cls.prefix),
                       LCARS_VERSION_CHECK="0")
        cls.model_log = cls.work / "model-calls"
        cls.shims = cls.work / "shims"
        cls.shims.mkdir()
        for name in ("claude", "copilot"):
            shim = cls.shims / name
            shim.write_text(
                "#!/usr/bin/env bash\n"
                'printf "%s %s\\n" "${0##*/}" "$*" >>"$CLI_MODEL_LOG"\nexit 97\n')
            shim.chmod(0o755)
        cls.env.update(PATH=str(cls.shims) + os.pathsep + cls.env["PATH"],
                       CLI_MODEL_LOG=str(cls.model_log))
        for key in ("LCARS_SKILLS_DEST", "LCARS_BIN_DEST",
                    "LCARS_COPILOT_PLUGINS_DIR", "LCARS_COPILOT_CONFIG"):
            cls.env.pop(key, None)
        # Registration is deliberately absent; the actual installer still runs.
        cls.env["LCARS_COPILOT_BIN"] = str(cls.work / "absent-copilot")
        subprocess.run(["bash", "install.sh"], env=cls.env, check=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        cls.launch = cls.prefix / "bin/lcars-launch"
        cls.foreign = cls.work / "foreign"
        cls.foreign.mkdir()
        cls.daemon_log = cls.work / "daemon.log"
        cls.daemon = cls.work / "python-stub"
        cls.daemon.write_text(
            "#!/usr/bin/env bash\n"
            'printf "daemon reached\\n" >>"$CLI_DAEMON_LOG"\n')
        cls.daemon.chmod(0o755)
        cls.env.update(LCARS_PYTHON_BIN=str(cls.daemon),
                       CLI_DAEMON_LOG=str(cls.daemon_log))

    @classmethod
    def tearDownClass(cls):
        try:
            calls = cls.model_log.read_text() if cls.model_log.exists() else ""
            print(f"CLI shim invocations: {len(calls.splitlines())}; "
                  f"--model invocations: {sum('--model' in c for c in calls.splitlines())}")
            if calls:
                raise AssertionError(f"Help invoked a model CLI:\n{calls}")
        finally:
            cls.scratch.cleanup()

    def run_cli(self, command, *args, **markers):
        env = dict(self.env)
        for key in ("CLAUDECODE", "COPILOT_RUN_APP",
                    "COPILOT_CLI_BINARY_VERSION", "COPILOT_CLI",
                    "LCARS_VIEWSCREEN_ALLOW_AI"):
            env.pop(key, None)
        env.update(markers)
        result = subprocess.run([str(command), *args], env=env,
                                cwd=self.foreign, text=True,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                timeout=10)
        return result

    def test_launch_help(self):
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                result = self.run_cli(self.launch, flag,
                                      LCARS_GIT_BIN=str(self.work / "no-git"))
                self.assertEqual(result.returncode, 0, result.stdout)
                self.assertIn("Usage:", result.stdout)
                self.assertIn("--main", result.stdout)
                self.assertIn("--stop", result.stdout)
        result = self.run_cli(self.launch, "--not-an-option")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unknown option", result.stdout)
        for flag in ("--help", "-h"):
            result = self.run_cli(self.launch, "--", flag)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(f'no mission "{flag}"', result.stdout)
            self.assertNotIn("Usage:", result.stdout)

    def test_agent_identity_and_refusal(self):
        cases = [
            ({"CLAUDECODE": "1"}, "Claude Code"),
            ({"COPILOT_RUN_APP": "1"}, "Copilot"),
            ({"COPILOT_CLI_BINARY_VERSION": "test"}, "Copilot"),
            ({"CLAUDECODE": "1", "COPILOT_RUN_APP": "1"}, "Copilot"),
            ({"CLAUDECODE": "1", "COPILOT_CLI_BINARY_VERSION": "test"}, "Copilot"),
        ]
        for command in ("lcars-viewscreen", "lcars-serve"):
            for markers, identity in cases:
                with self.subTest(command=command, markers=markers):
                    self.daemon_log.unlink(missing_ok=True)
                    result = self.run_cli(self.prefix / "bin" / command,
                                          "--open", **markers)
                    self.assertEqual(result.returncode, 3, result.stdout)
                    self.assertIn(f"inside a {identity} session", result.stdout)
                    self.assertIn("lcars-viewscreen --open", result.stdout)
                    self.assertFalse(self.daemon_log.exists())
        # Controls: a plain terminal and the existing explicit automation bypass.
        for markers in ({}, {"CLAUDECODE": "1", "COPILOT_RUN_APP": "1",
                              "LCARS_VIEWSCREEN_ALLOW_AI": "1"}):
            self.daemon_log.unlink(missing_ok=True)
            result = self.run_cli(self.prefix / "bin/lcars-viewscreen", **markers)
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertTrue(self.daemon_log.exists())

    def test_viewscreen_help(self):
        for command in ("lcars-viewscreen", "lcars-serve"):
            for args in (("--help",), ("-h",), ("--open", "--help")):
                for markers in ({}, {"CLAUDECODE": "1"},
                                {"COPILOT_CLI_BINARY_VERSION": "test"},
                                {"CLAUDECODE": "1", "COPILOT_RUN_APP": "1"}):
                    with self.subTest(command=command, args=args, markers=markers):
                        self.daemon_log.unlink(missing_ok=True)
                        result = self.run_cli(
                            self.prefix / "bin" / command, *args, **markers,
                            LCARS_SERVE_PORT="not-a-port",
                            LCARS_SERVE_ADAPTER="not-an-adapter")
                        self.assertEqual(result.returncode, 0, result.stdout)
                        self.assertIn("usage:", result.stdout.lower())
                        self.assertIn("--read-only", result.stdout)
                        self.assertNotIn("NOT started", result.stdout)
                        self.assertFalse(self.daemon_log.exists())
        result = self.run_cli(self.prefix / "bin/lcars-viewscreen", "--help",
                              LCARS_PYTHON_BIN=str(self.work / "no-python"))
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_installer_shell_contract(self):
        expected = {"lcars-viewscreen", "lcars-serve", "lcars-launch",
                    "lcars-eeh", "lcars-ech"}
        manifest = (self.prefix / "bin/.lcars-launchers").read_text().splitlines()
        self.assertEqual(set(manifest), expected)
        self.assertFalse((self.prefix / "bin/lcars").exists())
        missing = subprocess.run(
            ["bash", "-c", 'PATH="$1"; lcars status', "probe",
             str(self.prefix / "bin")], env=self.env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.assertEqual(missing.returncode, 127, missing.stdout)
        self.assertIn("lcars: command not found", missing.stdout)
        for command in expected:
            result = self.run_cli(self.prefix / "bin" / command,
                                  "--lcars-launcher-selftest")
            self.assertEqual(result.returncode, 0, result.stdout)


unittest.main()
PY
