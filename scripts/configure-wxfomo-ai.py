#!/usr/bin/env python3
"""Interactively configure the local MiniMax credential."""

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
    return parser


def main(argv=None):
    arguments = _parser().parse_args(argv)
    if arguments.test_connection:
        try:
            credential = load_credential(arguments.credentials)
            result = MiniMaxClient(credential.api_key).test_connection()
        except FileNotFoundError:
            print("{0} 连接失败: credential_unavailable".format(DEFAULT_MODEL))
            return 1
        except (CredentialError, OSError):
            print("{0} 连接失败: credential_unavailable".format(DEFAULT_MODEL))
            return 1
        except MiniMaxError as error:
            print("{0} 连接失败: {1}".format(DEFAULT_MODEL, error.code))
            return 1
        request_id = result.get("providerRequestId")
        suffix = " ({0})".format(request_id) if request_id else ""
        print("{0} 连接成功{1}".format(result.get("model", DEFAULT_MODEL), suffix))
        return 0

    try:
        first = getpass.getpass("MiniMax API key: ")
        second = getpass.getpass("Confirm MiniMax API key: ")
    except (EOFError, KeyboardInterrupt):
        print("Credential was not saved.")
        return 1
    if first != second:
        print("Credentials did not match.")
        return 1
    try:
        save_credential(arguments.credentials, first)
    except (CredentialError, OSError):
        print("Credential was not saved.")
        return 1
    print("Credential saved.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
