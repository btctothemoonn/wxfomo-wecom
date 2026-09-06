"""Private, race-resistant storage for the explicitly selected AI provider."""

import errno
import json
import os
import secrets
import stat
from collections import namedtuple


_MAX_CREDENTIAL_BYTES = 64 * 1024
_PRIVATE_DIRECTORY_MODE = 0o700
_PRIVATE_FILE_MODE = 0o600


class CredentialError(ValueError):
    """A credential path or payload failed a local safety check."""


class Credential(namedtuple("CredentialBase", ("api_key", "revision", "provider"), defaults=('minimax',))):
    """A secret API key paired with a non-secret file metadata revision."""

    __slots__ = ()

    def __repr__(self):
        return "Credential(api_key=<redacted>, revision=<redacted>)"


def _validate_parent(metadata):
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != _PRIVATE_DIRECTORY_MODE
    ):
        raise CredentialError("credential_parent_unsafe")


def _validate_file(metadata):
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) != _PRIVATE_FILE_MODE
    ):
        raise CredentialError("credential_file_unsafe")


def _credential_location(path):
    try:
        absolute_path = os.path.abspath(os.fspath(path))
    except (TypeError, ValueError):
        raise CredentialError("credential_path_invalid")
    parent, name = os.path.split(absolute_path)
    if not name or name in (".", ".."):
        raise CredentialError("credential_path_invalid")
    return parent, name


def _safe_private_parent(path, create):
    parent, name = _credential_location(path)
    created = False
    try:
        parent_metadata = os.lstat(parent)
    except FileNotFoundError:
        if not create:
            raise
        try:
            os.mkdir(parent, _PRIVATE_DIRECTORY_MODE)
        except FileExistsError:
            pass
        except FileNotFoundError:
            raise CredentialError("credential_parent_missing")
        else:
            created = True
        parent_metadata = os.lstat(parent)

    if stat.S_ISLNK(parent_metadata.st_mode):
        raise CredentialError("credential_parent_unsafe")
    if (
        not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid != os.geteuid()
    ):
        raise CredentialError("credential_parent_unsafe")
    if created:
        try:
            os.chmod(parent, _PRIVATE_DIRECTORY_MODE, follow_symlinks=False)
        except (NotImplementedError, OSError) as error:
            raise CredentialError("credential_parent_unsafe") from error
        secured_metadata = os.lstat(parent)
        if (
            (secured_metadata.st_dev, secured_metadata.st_ino)
            != (parent_metadata.st_dev, parent_metadata.st_ino)
            or stat.S_ISLNK(secured_metadata.st_mode)
        ):
            raise CredentialError("credential_parent_changed")
        parent_metadata = secured_metadata
        _validate_parent(parent_metadata)
    else:
        _validate_parent(parent_metadata)

    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    try:
        parent_fd = os.open(parent, flags)
    except OSError as error:
        raise CredentialError("credential_parent_unsafe") from error
    try:
        if created:
            os.fchmod(parent_fd, _PRIVATE_DIRECTORY_MODE)
        opened_metadata = os.fstat(parent_fd)
        _validate_parent(opened_metadata)
        if (opened_metadata.st_dev, opened_metadata.st_ino) != (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        ):
            raise CredentialError("credential_parent_changed")
    except Exception:
        os.close(parent_fd)
        raise
    return parent_fd, name


def _entry_metadata(parent_fd, name):
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _same_file_version(first, second):
    return (
        first.st_dev,
        first.st_ino,
        first.st_mtime_ns,
        first.st_size,
    ) == (
        second.st_dev,
        second.st_ino,
        second.st_mtime_ns,
        second.st_size,
    )


def _revision(metadata):
    return "{0}:{1}:{2}:{3}".format(
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mtime_ns,
        metadata.st_size,
    )


def _load_document(path):
    """Load one credential only after verifying its parent and file metadata."""

    parent_fd, name = _safe_private_parent(path, create=False)
    descriptor = None
    try:
        before = _entry_metadata(parent_fd, name)
        if before is None:
            raise FileNotFoundError(errno.ENOENT, "credential_not_found")
        _validate_file(before)

        flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(name, flags, dir_fd=parent_fd)
        except OSError as error:
            raise CredentialError("credential_file_unsafe") from error

        opened = os.fstat(descriptor)
        _validate_file(opened)
        if not _same_file_version(before, opened):
            raise CredentialError("credential_file_changed")

        chunks = []
        byte_count = 0
        while True:
            chunk = os.read(descriptor, min(8192, _MAX_CREDENTIAL_BYTES + 1 - byte_count))
            if not chunk:
                break
            chunks.append(chunk)
            byte_count += len(chunk)
            if byte_count > _MAX_CREDENTIAL_BYTES:
                raise CredentialError("credential_payload_invalid")

        after = os.fstat(descriptor)
        _validate_file(after)
        if not _same_file_version(opened, after):
            raise CredentialError("credential_file_changed")
        payload = b"".join(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent_fd)

    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise CredentialError("credential_payload_invalid")
    if not isinstance(decoded, dict):
        raise CredentialError("credential_payload_invalid")
    return decoded, _revision(after)


def load_credential(path):
    decoded, revision = _load_document(path)
    provider = decoded.get('provider', 'minimax')
    if provider not in ('minimax', 'deepseek'):
        raise CredentialError('credential_payload_invalid')
    api_key = decoded.get('deepSeekAPIKey' if provider == 'deepseek' else 'miniMaxAPIKey')
    if not isinstance(api_key, str) or not api_key.strip():
        raise CredentialError("credential_payload_invalid")
    return Credential(api_key.strip(), revision, provider)


def _atomic_private_write(parent_fd, name, payload):
    existing = _entry_metadata(parent_fd, name)
    if existing is not None:
        _validate_file(existing)

    temporary_name = None
    descriptor = None
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        for unused_attempt in range(128):
            candidate = ".{0}.{1}.tmp".format(name, secrets.token_hex(16))
            try:
                descriptor = os.open(
                    candidate,
                    flags,
                    _PRIVATE_FILE_MODE,
                    dir_fd=parent_fd,
                )
            except FileExistsError:
                continue
            temporary_name = candidate
            break
        if descriptor is None:
            raise CredentialError("credential_temporary_unavailable")

        os.fchmod(descriptor, _PRIVATE_FILE_MODE)
        view = memoryview(payload)
        while view:
            written = os.write(descriptor, view)
            if written <= 0:
                raise OSError("credential_write_failed")
            view = view[written:]
        os.fsync(descriptor)
        os.close(descriptor)
        descriptor = None

        os.replace(
            temporary_name,
            name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        temporary_name = None
        os.fsync(parent_fd)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass


def save_credential(path, api_key, provider='minimax'):
    """Select one provider, preserving the other key without automatic fallback."""

    if provider not in ('minimax', 'deepseek'):
        raise CredentialError('credential_provider_invalid')
    if not isinstance(api_key, str):
        raise CredentialError("credential_empty")
    value = api_key.strip()
    if not value:
        raise CredentialError("credential_empty")
    try:
        previous, unused_revision = _load_document(path)
    except FileNotFoundError:
        previous = {}
    document = {key: previous[key] for key in ('miniMaxAPIKey', 'deepSeekAPIKey') if key in previous}
    document['provider'] = provider
    document['deepSeekAPIKey' if provider == 'deepseek' else 'miniMaxAPIKey'] = value
    payload = json.dumps(document, separators=(",", ":")).encode("utf-8")
    parent_fd, name = _safe_private_parent(path, create=True)
    try:
        _atomic_private_write(parent_fd, name, payload)
    finally:
        os.close(parent_fd)


def credential_status(path):
    """Return a public local state without exposing key material or revision."""

    try:
        load_credential(path)
    except FileNotFoundError:
        return "missing"
    except (CredentialError, OSError):
        return "invalid"
    return "configured"
