#!/usr/bin/env python3
"""Run the authenticated, read-only wxFomo LAN server."""

import argparse
import ipaddress
import os
import socket
import ssl
import sys

from wxfomo_lan.security import ensure_access_token
from wxfomo_lan.server import PUBLIC_ASSETS, ServerOptions, create_server


APPLICATION_SUPPORT = os.path.expanduser("~/Library/Application Support")
LAN_SUPPORT = os.path.join(APPLICATION_SUPPORT, "wxFomo LAN")
WX_FOMO_SUPPORT = os.path.join(APPLICATION_SUPPORT, "wxFomo")
REPOSITORY_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATIC_ROOT = os.path.join(REPOSITORY_ROOT, "web", "wxfomo-lan")
GROUP_CONFIG = os.path.expanduser("~/.config/wxfomo/wecom-groups.txt")


def path_overlaps_static_root(path):
    """Return whether a sensitive path resolves lexically or physically under public assets."""
    try:
        static_identity = os.stat(STATIC_ROOT)
    except OSError:
        static_identity = None
    try:
        sensitive_identity = os.stat(path)
    except OSError:
        sensitive_identity = None
    if sensitive_identity is not None:
        for filename in {asset[0] for asset in PUBLIC_ASSETS.values()}:
            try:
                asset_identity = os.stat(os.path.join(STATIC_ROOT, filename))
            except OSError:
                continue
            if (sensitive_identity.st_dev, sensitive_identity.st_ino) == (
                asset_identity.st_dev,
                asset_identity.st_ino,
            ):
                return True
    for normalizer in (os.path.abspath, os.path.realpath):
        root = os.path.normcase(normalizer(STATIC_ROOT))
        candidate = os.path.normcase(normalizer(path))
        try:
            if os.path.commonpath((root, candidate)) == root:
                return True
        except ValueError:
            # Different Windows drives cannot overlap.
            continue
        if static_identity is None:
            continue
        ancestor = candidate
        while True:
            try:
                identity = os.stat(ancestor)
            except OSError:
                pass
            else:
                if (identity.st_dev, identity.st_ino) == (
                    static_identity.st_dev,
                    static_identity.st_ino,
                ):
                    return True
            parent = os.path.dirname(ancestor)
            if parent == ancestor:
                break
            ancestor = parent
    return False


def build_parser():
    parser = argparse.ArgumentParser(description="Serve the wxFomo read-only LAN workbench.")
    parser.add_argument("--allow-lan", action="store_true")
    parser.add_argument("--host", metavar="HOST", default="127.0.0.1")
    parser.add_argument("--port", metavar="PORT", type=int, default=8765)
    parser.add_argument(
        "--database", metavar="PATH", default=os.path.join(LAN_SUPPORT, "messages.sqlite3")
    )
    parser.add_argument("--notification-database", metavar="PATH")
    parser.add_argument("--group-config", metavar="PATH", default=GROUP_CONFIG)
    parser.add_argument(
        "--workspace-database",
        metavar="PATH",
        default=os.path.join(WX_FOMO_SUPPORT, "workspace.sqlite3"),
    )
    parser.add_argument(
        "--configuration",
        metavar="PATH",
        default=os.path.join(WX_FOMO_SUPPORT, "configuration-center.json"),
    )
    parser.add_argument(
        "--token-file", metavar="PATH", default=os.path.join(LAN_SUPPORT, "access-token")
    )
    parser.add_argument("--tls-cert", metavar="PATH")
    parser.add_argument("--tls-key", metavar="PATH")
    return parser


def parse_options(arguments=None):
    parser = build_parser()
    parsed = parser.parse_args(arguments)
    requested_host = parsed.host or "0.0.0.0"
    try:
        addresses = []
        for result in socket.getaddrinfo(
            requested_host, 0, socket.AF_INET, socket.SOCK_STREAM
        ):
            address = result[4][0]
            if address not in addresses:
                addresses.append(address)
    except socket.gaierror:
        parser.error("--host could not be resolved to an IPv4 bind address")
    if not addresses:
        parser.error("--host could not be resolved to an IPv4 bind address")
    if not parsed.allow_lan and any(
        not ipaddress.ip_address(address).is_loopback for address in addresses
    ):
        parser.error("every non-loopback --host requires --allow-lan")
    # Bind the numeric address that was authorized instead of resolving a hostname again.
    parsed.host = addresses[0]
    if bool(parsed.tls_cert) != bool(parsed.tls_key):
        parser.error("--tls-cert and --tls-key must be provided together")
    sensitive_paths = (
        parsed.notification_database,
        parsed.database,
        parsed.workspace_database,
        parsed.configuration,
        parsed.group_config,
        parsed.token_file,
        parsed.tls_key,
    )
    if any(path and path_overlaps_static_root(path) for path in sensitive_paths):
        parser.error("sensitive data paths must be outside the public static root")
    return parsed


def main(arguments=None):
    parsed = parse_options(arguments)
    token = ensure_access_token(parsed.token_file)
    options = ServerOptions(
        host=parsed.host,
        port=parsed.port,
        token=token,
        static_root=STATIC_ROOT,
        message_database=parsed.database,
        group_config_path=parsed.group_config,
        workspace_database=parsed.workspace_database,
        configuration_path=parsed.configuration,
        notification_database=parsed.notification_database or "",
        token_path=parsed.token_file,
        tls_key_path=parsed.tls_key or "",
    )
    server = create_server(options)
    if parsed.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(parsed.tls_cert, parsed.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
