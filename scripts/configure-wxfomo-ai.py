#!/usr/bin/env python3
"""Interactively configure the selected local AI provider without key arguments."""

import argparse
import getpass
import os

from wxfomo_lan.credentials import CredentialError, load_credential, save_credential
from wxfomo_lan.minimax import DEFAULT_MODEL, MiniMaxClient, MiniMaxError


DEFAULT_CREDENTIAL_PATH = os.path.expanduser(
    "~/Library/Application Support/wxFomo LAN/ai-credentials.json"
)


def _parser():
    parser = argparse.ArgumentParser(description="Configure local AI credentials.")
    parser.add_argument("--credentials", default=DEFAULT_CREDENTIAL_PATH, metavar="PATH")
    parser.add_argument("--test-connection", action="store_true")
    parser.add_argument('--provider', choices=('minimax', 'deepseek'), default='minimax')
    return parser


def main(argv=None):
    arguments = _parser().parse_args(argv)
    if arguments.test_connection:
        model = DEFAULT_MODEL
        try:
            credential = load_credential(arguments.credentials)
            if credential.provider == 'deepseek':
                from wxfomo_lan.deepseek import DeepSeekClient
                model = 'deepseek-v4-flash'
                client = DeepSeekClient(credential.api_key)
            else:
                client = MiniMaxClient(credential.api_key)
            result = client.test_connection()
        except FileNotFoundError:
            print("{0} 连接失败: credential_unavailable".format(DEFAULT_MODEL))
            return 1
        except (CredentialError, OSError):
            print("{0} 连接失败: credential_unavailable".format(DEFAULT_MODEL))
            return 1
        except MiniMaxError as error:
            print("{0} 连接失败: {1}".format(model, error.code))
            return 1
        request_id = result.get("providerRequestId")
        suffix = " ({0})".format(request_id) if request_id else ""
        print("{0} 连接成功{1}".format(result.get("model", DEFAULT_MODEL), suffix))
        return 0

    try:
        label = 'DeepSeek' if arguments.provider == 'deepseek' else 'MiniMax'
        first = getpass.getpass(label + " API key: ")
        second = getpass.getpass("Confirm " + label + " API key: ")
    except (EOFError, KeyboardInterrupt):
        print("Credential was not saved.")
        return 1
    if first != second:
        print("Credentials did not match.")
        return 1
    try:
        save_credential(arguments.credentials, first, provider=arguments.provider)
    except (CredentialError, OSError):
        print("Credential was not saved.")
        return 1
    print("Credential saved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
