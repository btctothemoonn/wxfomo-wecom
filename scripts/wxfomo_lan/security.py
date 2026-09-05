"""Local bearer-token storage and validation."""

import hmac
import os
import re
import secrets
import stat
import urllib.parse


_URL_PATTERN = re.compile(r"https?://[^\s<>\"']+", re.IGNORECASE)
PUBLIC_SOURCE_HOSTS = frozenset(
    {
        "arbiscan.io",
        "basescan.org",
        "birdeye.so",
        "bscscan.com",
        "dexscreener.com",
        "etherscan.io",
        "fomo.family",
        "geckoterminal.com",
        "gmgn.ai",
        "optimistic.etherscan.io",
        "polygonscan.com",
        "pump.fun",
        "snowtrace.io",
        "solscan.io",
        "www.birdeye.so",
        "www.geckoterminal.com",
    }
)
_CREDENTIAL_TEXT_MARKERS = (
    "authorization", "bearer-", "bearer%20", "api_key", "apikey", "access_token",
    "password", "passwd", "secret=", "session=", "signature=",
)


def _open_private_directory(directory):
    if not os.path.lexists(directory):
        try:
            os.mkdir(directory, mode=0o700)
        except FileExistsError:
            pass
        except OSError:
            raise ValueError("token_directory_not_private")
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(directory, flags)
    except OSError:
        raise ValueError("token_directory_not_private")
    current = os.fstat(descriptor)
    if not stat.S_ISDIR(current.st_mode) or stat.S_IMODE(current.st_mode) != 0o700:
        os.close(descriptor)
        raise ValueError("token_directory_not_private")
    return descriptor


def _token_status(directory_descriptor, filename):
    try:
        return os.stat(filename, dir_fd=directory_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError:
        raise ValueError("token_file_not_regular")


def _read_existing_token(directory_descriptor, filename, expected):
    if not stat.S_ISREG(expected.st_mode) or expected.st_nlink != 1:
        raise ValueError("token_file_not_regular")
    flags = os.O_RDONLY | getattr(os, "O_NONBLOCK", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(filename, flags, dir_fd=directory_descriptor)
    except OSError:
        raise ValueError("token_file_not_regular")
    try:
        current = os.fstat(descriptor)
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or current.st_dev != expected.st_dev
            or current.st_ino != expected.st_ino
        ):
            raise ValueError("token_file_not_regular")
        with os.fdopen(descriptor, "r", encoding="utf-8") as stream:
            descriptor = None
            token = stream.read().strip()
            if not token:
                raise ValueError("token_file_empty")
            os.fchmod(stream.fileno(), 0o600)
            if stat.S_IMODE(os.fstat(stream.fileno()).st_mode) != 0o600:
                raise ValueError("token_file_not_private")
    finally:
        if descriptor is not None:
            os.close(descriptor)
    return token


def ensure_access_token(path):
    """Return the token at *path*, creating a private token file if needed."""
    absolute_path = os.path.abspath(path)
    directory = os.path.dirname(absolute_path)
    filename = os.path.basename(absolute_path)
    if not filename:
        raise ValueError("token_file_not_regular")
    directory_descriptor = _open_private_directory(directory)
    try:
        current = _token_status(directory_descriptor, filename)
        if current is not None:
            return _read_existing_token(directory_descriptor, filename, current)

        token = secrets.token_urlsafe(32)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(filename, flags, 0o600, dir_fd=directory_descriptor)
        except OSError:
            raise ValueError("token_file_create_conflict")
        try:
            os.fchmod(descriptor, 0o600)
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                descriptor = None
                stream.write(token + "\n")
                stream.flush()
                os.fsync(stream.fileno())
        except Exception:
            if descriptor is not None:
                os.close(descriptor)
            try:
                os.unlink(filename, dir_fd=directory_descriptor)
            except OSError:
                pass
            raise
        current = _token_status(directory_descriptor, filename)
        if current is None:
            raise ValueError("token_file_create_conflict")
        return _read_existing_token(directory_descriptor, filename, current)
    finally:
        os.close(directory_descriptor)


def authorized(header_value, token):
    """Return whether an Authorization header has the configured bearer token."""
    prefix = "Bearer "
    return bool(header_value and header_value.startswith(prefix)) and hmac.compare_digest(
        header_value[len(prefix):], token
    )


def public_https_url(value):
    """Return a credential-free public HTTPS URL, or None when unsafe."""
    if not isinstance(value, str) or not value:
        return None
    try:
        parsed = urllib.parse.urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except (UnicodeError, ValueError):
        return None
    if parsed.scheme.lower() != "https" or not hostname or port not in (None, 443):
        return None
    if parsed.query or parsed.fragment:
        return None
    if parsed.username is not None or parsed.password is not None:
        return None
    normalized_host = hostname.lower()
    if normalized_host not in PUBLIC_SOURCE_HOSTS:
        return None
    if re.search(r"%(?![0-9A-Fa-f]{2})", parsed.path):
        return None
    try:
        urllib.parse.unquote_to_bytes(parsed.path).decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return None
    decoded_tail = urllib.parse.unquote(
        "{}?{}#{}".format(parsed.path, parsed.query, parsed.fragment)
    ).lower()
    if any(marker in decoded_tail for marker in _CREDENTIAL_TEXT_MARKERS):
        return None
    return urllib.parse.urlunsplit(parsed)


def public_https_links(text, maximum=10):
    """Extract only explicit, display-safe source URLs already present in text."""
    if not isinstance(text, str):
        return []
    result = []
    for match in _URL_PATTERN.finditer(text):
        candidate = match.group(0).rstrip(".,;:!?)]}")
        safe = public_https_url(candidate)
        if safe is not None and safe not in result:
            result.append(safe)
        if len(result) >= maximum:
            break
    return result
