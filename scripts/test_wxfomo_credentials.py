import contextlib
import getpass
import importlib.util
import io
import os
import stat
import sys
import tempfile
import unittest
from unittest import mock


try:
    from scripts.wxfomo_lan.credentials import (
        CredentialError,
        credential_status,
        load_credential,
        save_credential,
    )
except ImportError as error:
    CredentialError = None
    credential_status = None
    load_credential = None
    save_credential = None
    CREDENTIAL_IMPORT_ERROR = error
else:
    CREDENTIAL_IMPORT_ERROR = None


def _load_configure_module():
    path = os.path.join(os.path.dirname(__file__), "configure-wxfomo-ai.py")
    spec = importlib.util.spec_from_file_location("configure_wxfomo_ai", path)
    module = importlib.util.module_from_spec(spec)
    script_directory = os.path.dirname(path)
    sys.path.insert(0, script_directory)
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(script_directory)
    return module


class CredentialTests(unittest.TestCase):
    def test_provider_switch_preserves_other_key_and_never_falls_back(self):
        import json
        save_credential(self.path, 'dummy-original-key')
        save_credential(self.path, 'dummy-deepseek-key', provider='deepseek')
        configured = load_credential(self.path)
        self.assertEqual(configured.provider, 'deepseek')
        self.assertEqual(configured.api_key, 'dummy-deepseek-key')
        with open(self.path) as handle:
            value = json.load(handle)
        self.assertEqual(value['miniMaxAPIKey'], 'dummy-original-key')
        self.assertNotIn('dummy-deepseek-key', repr(configured))
        value.pop('deepSeekAPIKey')
        with open(self.path, 'w') as handle:
            json.dump(value, handle)
        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_legacy_configuration_defaults_to_minimax(self):
        save_credential(self.path, 'dummy-key')
        self.assertEqual(load_credential(self.path).provider, 'minimax')

    def test_unknown_provider_is_rejected_before_writing(self):
        with self.assertRaises(CredentialError):
            save_credential(self.path, 'dummy-key', provider='unknown')
        self.assertFalse(os.path.exists(self.path))

    def test_settings_uses_last_successful_model_without_reading_credentials(self):
        from scripts.wxfomo_lan.analysis import AnalysisRepository
        repository = AnalysisRepository('synthetic-only')
        status = dict(credential_status='configured', last_provider_success_at=None, last_error_code=None)
        with mock.patch.object(repository, '_rows', side_effect=[(None, [status]), (None, [{'model': 'deepseek-v4-flash'}])]), \
             mock.patch('builtins.open', side_effect=AssertionError('must not open credentials')):
            actual = repository.settings_status()
        self.assertEqual(actual['model'], 'deepseek-v4-flash')
        self.assertEqual(actual['modelBasis'], 'last_successful_report')
        self.assertEqual(actual['protocol'], 'openai_compatible')

    def setUp(self):
        if CREDENTIAL_IMPORT_ERROR is not None:
            self.fail("credential module is missing: {0}".format(CREDENTIAL_IMPORT_ERROR))
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(
            self.temporary_directory.name, "private", "minimax.json"
        )

    def tearDown(self):
        if hasattr(self, "temporary_directory"):
            parent = os.path.dirname(self.path)
            if os.path.isdir(parent) and not os.path.islink(parent):
                os.chmod(parent, 0o700)
            self.temporary_directory.cleanup()

    def test_save_creates_private_directory_and_file(self):
        save_credential(self.path, "dummy-plan-key")

        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700
        )
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)
        self.assertEqual(load_credential(self.path).api_key, "dummy-plan-key")

    def test_save_enforces_private_modes_under_restrictive_umask(self):
        previous_umask = os.umask(0o777)
        try:
            try:
                save_credential(self.path, "dummy-plan-key")
            except CredentialError:
                self.fail("save must enforce final modes independently of umask")
        finally:
            os.umask(previous_umask)

        self.assertEqual(
            stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode), 0o700
        )
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode), 0o600)

    def test_world_readable_credentials_are_rejected(self):
        save_credential(self.path, "dummy-plan-key")
        os.chmod(self.path, 0o644)

        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_symlink_credentials_are_rejected(self):
        target = os.path.join(self.temporary_directory.name, "target.json")
        with open(target, "w") as output:
            output.write('{"miniMaxAPIKey":"dummy-target-key"}')
        os.chmod(target, 0o600)
        os.mkdir(os.path.dirname(self.path), 0o700)
        os.symlink(target, self.path)

        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_non_regular_credentials_are_rejected_before_open(self):
        os.mkdir(os.path.dirname(self.path), 0o700)
        os.mkfifo(self.path, 0o600)

        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_multiply_linked_credentials_are_rejected(self):
        save_credential(self.path, "dummy-plan-key")
        os.link(self.path, os.path.join(os.path.dirname(self.path), "second-link"))

        with self.assertRaises(CredentialError):
            load_credential(self.path)

    def test_credentials_not_owned_by_current_user_are_rejected(self):
        save_credential(self.path, "dummy-plan-key")

        with mock.patch(
            "scripts.wxfomo_lan.credentials.os.geteuid",
            return_value=os.stat(self.path).st_uid + 1,
        ):
            with self.assertRaises(CredentialError):
                load_credential(self.path)

    def test_unsafe_existing_parent_is_rejected(self):
        os.mkdir(os.path.dirname(self.path), 0o755)

        with self.assertRaises(CredentialError):
            save_credential(self.path, "dummy-plan-key")

    def test_save_rejects_unsafe_parent_created_during_mkdir_race(self):
        parent = os.path.dirname(self.path)
        real_mkdir = os.mkdir

        def competing_mkdir(path, mode):
            real_mkdir(path, 0o777)
            os.chmod(path, 0o777)
            raise FileExistsError()

        outcome = "accepted"
        with mock.patch(
            "scripts.wxfomo_lan.credentials.os.mkdir",
            side_effect=competing_mkdir,
        ):
            try:
                save_credential(self.path, "dummy-race-key")
            except CredentialError:
                outcome = "rejected"

        self.assertEqual(
            (
                outcome,
                stat.S_IMODE(os.stat(parent).st_mode),
                os.path.lexists(self.path),
            ),
            ("rejected", 0o777, False),
        )

    def test_symlink_parent_is_rejected(self):
        real_parent = os.path.join(self.temporary_directory.name, "real-private")
        os.mkdir(real_parent, 0o700)
        os.symlink(real_parent, os.path.dirname(self.path))

        with self.assertRaises(CredentialError):
            save_credential(self.path, "dummy-plan-key")

    def test_unsafe_existing_destination_is_not_overwritten(self):
        save_credential(self.path, "dummy-original-key")
        os.chmod(self.path, 0o644)

        with self.assertRaises(CredentialError):
            save_credential(self.path, "dummy-replacement-key")
        os.chmod(self.path, 0o600)
        self.assertEqual(load_credential(self.path).api_key, "dummy-original-key")

    def test_blank_credentials_are_rejected(self):
        with self.assertRaises(CredentialError):
            save_credential(self.path, "  \n ")

    def test_revision_is_stable_safe_file_metadata(self):
        save_credential(self.path, "dummy-plan-key")

        first = load_credential(self.path)
        second = load_credential(self.path)
        metadata = os.stat(self.path)
        expected = "{0}:{1}:{2}:{3}".format(
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mtime_ns,
            metadata.st_size,
        )
        self.assertEqual(first.revision, expected)
        self.assertEqual(second.revision, expected)
        self.assertNotIn(first.api_key, repr(first.revision))

    def test_status_distinguishes_missing_valid_and_invalid(self):
        self.assertEqual(credential_status(self.path), "missing")
        save_credential(self.path, "dummy-plan-key")
        self.assertEqual(credential_status(self.path), "configured")
        os.chmod(self.path, 0o644)
        self.assertEqual(credential_status(self.path), "invalid")


class ConfigureCredentialTests(unittest.TestCase):
    def setUp(self):
        if CREDENTIAL_IMPORT_ERROR is not None:
            self.fail("credential module is missing: {0}".format(CREDENTIAL_IMPORT_ERROR))
        self.configure = _load_configure_module()
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.path = os.path.join(
            self.temporary_directory.name, "private", "minimax.json"
        )

    def tearDown(self):
        if hasattr(self, "temporary_directory"):
            self.temporary_directory.cleanup()

    def test_cli_default_matches_launcher_private_credentials_path(self):
        expected = os.path.expanduser(
            "~/Library/Application Support/wxFomo LAN/ai-credentials.json"
        )
        self.assertEqual(
            self.configure._parser().parse_args([]).credentials,
            expected,
        )

    def test_cli_reads_twice_with_getpass_and_never_prints_key(self):
        output = io.StringIO()
        with mock.patch.object(
            getpass,
            "getpass",
            side_effect=["dummy-plan-key", "dummy-plan-key"],
        ) as prompt:
            with contextlib.redirect_stdout(output):
                self.assertEqual(
                    self.configure.main(["--credentials", self.path]), 0
                )

        self.assertEqual(prompt.call_count, 2)
        self.assertEqual(output.getvalue(), "Credential saved.\n")
        self.assertNotIn("dummy-plan-key", output.getvalue())
        self.assertEqual(load_credential(self.path).api_key, "dummy-plan-key")

    def test_cli_mismatch_does_not_save(self):
        output = io.StringIO()
        with mock.patch.object(
            getpass,
            "getpass",
            side_effect=["dummy-first-key", "dummy-second-key"],
        ):
            with contextlib.redirect_stdout(output):
                self.assertEqual(
                    self.configure.main(["--credentials", self.path]), 1
                )

        self.assertEqual(output.getvalue(), "Credentials did not match.\n")
        self.assertFalse(os.path.lexists(self.path))
        self.assertNotIn("dummy-first-key", output.getvalue())
        self.assertNotIn("dummy-second-key", output.getvalue())

    def test_cli_ignores_environment_key_and_still_prompts_twice(self):
        output = io.StringIO()
        environment = {"MINIMAX_API_KEY": "dummy-environment-key"}
        with mock.patch.dict(os.environ, environment, clear=True):
            with mock.patch.object(
                getpass,
                "getpass",
                side_effect=["dummy-prompt-key", "dummy-prompt-key"],
            ) as prompt:
                with contextlib.redirect_stdout(output):
                    self.assertEqual(
                        self.configure.main(["--credentials", self.path]), 0
                    )

        self.assertEqual(prompt.call_count, 2)
        self.assertEqual(load_credential(self.path).api_key, "dummy-prompt-key")
        self.assertNotIn("dummy-environment-key", output.getvalue())

    def test_cli_rejects_key_argument(self):
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit) as raised:
                self.configure.main(
                    ["--credentials", self.path, "--api-key", "dummy-argument-key"]
                )

        self.assertEqual(raised.exception.code, 2)
        self.assertFalse(os.path.lexists(self.path))

    def test_connection_check_calls_provider_only_when_explicitly_requested(self):
        save_credential(self.path, "dummy-plan-key")
        output = io.StringIO()
        client = mock.Mock()
        client.test_connection.return_value = {
            "model": "MiniMax-M2.7",
            "providerRequestId": "provider-request-1",
        }
        with mock.patch.object(
            self.configure, "MiniMaxClient", return_value=client
        ) as client_type:
            with contextlib.redirect_stdout(output):
                self.assertEqual(
                    self.configure.main(
                        ["--credentials", self.path, "--test-connection"]
                    ),
                    0,
                )

        client_type.assert_called_once_with("dummy-plan-key")
        client.test_connection.assert_called_once_with()
        self.assertEqual(
            output.getvalue(),
            "MiniMax-M2.7 连接成功 (provider-request-1)\n",
        )
        self.assertNotIn("dummy-plan-key", output.getvalue())

    def test_connection_failure_prints_only_stable_error_code(self):
        save_credential(self.path, "dummy-plan-key")
        output = io.StringIO()
        client = mock.Mock()
        client.test_connection.side_effect = self.configure.MiniMaxError(
            "rate_limited", True, 60.0
        )
        with mock.patch.object(self.configure, "MiniMaxClient", return_value=client):
            with contextlib.redirect_stdout(output):
                result = self.configure.main(
                    ["--credentials", self.path, "--test-connection"]
                )

        self.assertEqual(result, 1)
        self.assertEqual(output.getvalue(), "MiniMax-M2.7 连接失败: rate_limited\n")
        self.assertNotIn("dummy-plan-key", output.getvalue())


if __name__ == "__main__":
    unittest.main()
