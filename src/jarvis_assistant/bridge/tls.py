from __future__ import annotations

import atexit
import csv
import hashlib
import ipaddress
import os
import ssl
import subprocess
import tempfile
import time
from collections.abc import Callable, Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from jarvis_assistant.bridge.device_store import CredentialBackend
from jarvis_assistant.bridge.pairing import canonicalize_bridge_host, is_private_bridge_host


class BridgeTLSIdentityError(RuntimeError):
    """Raised when an established TLS identity cannot be loaded safely."""


_PRIVATE_KEY_DELETE_ATTEMPTS = 3
_PRIVATE_KEY_DELETE_RETRY_SECONDS = 0.02
_DEFERRED_PRIVATE_KEY_CLEANUP: set[Path] = set()


def create_server_ssl_context(
    identity: BridgeTLSIdentity,
    *,
    certificate_path: str | Path,
    temporary_directory: str | Path | None = None,
    context_factory: Callable[[int], Any] = ssl.SSLContext,
) -> ssl.SSLContext:
    """Load Bridge TLS material while keeping no reusable private-key file."""
    directory = Path(temporary_directory) if temporary_directory is not None else None
    if directory is not None:
        directory.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".jarvis-bridge-",
        suffix=".key",
        dir=directory,
    )
    key_path = Path(temporary_name)
    active_error: BaseException | None = None
    try:
        os.chmod(key_path, 0o600)
        _restrict_private_key_to_current_user(key_path)
        with os.fdopen(descriptor, "wb") as private_key_file:
            descriptor = -1
            private_key_file.write(identity.private_key_pem)
            private_key_file.flush()
            os.fsync(private_key_file.fileno())
        context = context_factory(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(str(certificate_path), str(key_path))
        return context
    except BaseException as error:
        active_error = error
        raise
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            _remove_temporary_private_key(key_path)
        except BridgeTLSIdentityError as cleanup_error:
            if active_error is None:
                raise
            raise BridgeTLSIdentityError(
                "could not safely clean up temporary TLS private key"
            ) from cleanup_error


def _remove_temporary_private_key(path: Path) -> None:
    if _unlink_private_key_with_retries(path):
        return
    _overwrite_and_truncate_private_key(path)
    _schedule_deferred_private_key_cleanup(path)


def _unlink_private_key_with_retries(path: Path) -> bool:
    for attempt in range(_PRIVATE_KEY_DELETE_ATTEMPTS):
        try:
            path.unlink()
            return True
        except FileNotFoundError:
            return True
        except OSError:
            if attempt + 1 < _PRIVATE_KEY_DELETE_ATTEMPTS:
                time.sleep(_PRIVATE_KEY_DELETE_RETRY_SECONDS)
    return False


def _overwrite_and_truncate_private_key(path: Path) -> None:
    try:
        with path.open("r+b", buffering=0) as private_key_file:
            byte_count = private_key_file.seek(0, os.SEEK_END)
            private_key_file.seek(0)
            while byte_count:
                chunk_size = min(byte_count, 64 * 1024)
                private_key_file.write(b"\0" * chunk_size)
                byte_count -= chunk_size
            private_key_file.flush()
            os.fsync(private_key_file.fileno())
            private_key_file.truncate(0)
            private_key_file.flush()
            os.fsync(private_key_file.fileno())
    except OSError as error:
        raise BridgeTLSIdentityError("could not sanitize temporary TLS private key") from error


def _schedule_deferred_private_key_cleanup(path: Path) -> None:
    if path in _DEFERRED_PRIVATE_KEY_CLEANUP:
        return
    _DEFERRED_PRIVATE_KEY_CLEANUP.add(path)
    atexit.register(_retry_deferred_private_key_cleanup, path)


def _retry_deferred_private_key_cleanup(path: Path) -> None:
    _unlink_private_key_with_retries(path)


def _restrict_private_key_to_current_user(path: Path) -> None:
    if os.name != "nt":
        os.chmod(path, 0o600)
        return
    system_root = Path(os.environ.get("SYSTEMROOT", r"C:\Windows"))
    whoami = system_root / "System32" / "whoami.exe"
    icacls = system_root / "System32" / "icacls.exe"
    identity = subprocess.run(
        [str(whoami), "/user", "/fo", "csv", "/nh"],
        check=True,
        capture_output=True,
        text=True,
    )
    rows = list(csv.reader(identity.stdout.splitlines()))
    if len(rows) != 1 or len(rows[0]) < 2 or not rows[0][1].startswith("S-"):
        raise BridgeTLSIdentityError("could not resolve the current Windows user SID")
    subprocess.run(
        [
            str(icacls),
            str(path),
            "/inheritance:r",
            "/grant:r",
            f"*{rows[0][1]}:(F)",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        [str(icacls), str(path), "/verify"],
        check=True,
        capture_output=True,
        text=True,
    )


@dataclass(frozen=True)
class BridgeTLSIdentity:
    CREDENTIAL_SERVICE = "jarvis-bridge-tls"
    VALIDITY = timedelta(days=365)

    certificate_pem: bytes
    certificate_sha256: str
    private_key_pem: bytes = field(repr=False)

    @classmethod
    def load_or_create(
        cls,
        *,
        certificate_path: str | Path,
        credential_backend: CredentialBackend,
        bridge_id: str,
        hosts: Iterable[str] = ("localhost",),
    ) -> BridgeTLSIdentity:
        path = Path(certificate_path)
        supplied_hosts = tuple(hosts)
        if not supplied_hosts or any(not is_private_bridge_host(host) for host in supplied_hosts):
            raise BridgeTLSIdentityError("TLS identity hosts must be private or local")
        requested_hosts = tuple(canonicalize_bridge_host(host) for host in supplied_hosts)
        stored_key = credential_backend.get_password(cls.CREDENTIAL_SERVICE, bridge_id)
        certificate_exists = path.exists()

        if not certificate_exists and stored_key is None:
            return cls._create(path, credential_backend, bridge_id, requested_hosts)
        if not certificate_exists:
            raise BridgeTLSIdentityError("TLS certificate is missing for established identity")
        if stored_key is None:
            raise BridgeTLSIdentityError("TLS private key is missing for established identity")

        try:
            certificate_pem = path.read_bytes()
            certificate = x509.load_pem_x509_certificate(certificate_pem)
        except (OSError, ValueError) as error:
            raise BridgeTLSIdentityError("TLS certificate is corrupt") from error
        try:
            private_key_pem = stored_key.encode("ascii")
            private_key = serialization.load_pem_private_key(private_key_pem, password=None)
        except (TypeError, ValueError, UnicodeEncodeError) as error:
            raise BridgeTLSIdentityError("TLS private key is corrupt") from error

        certificate_public_key = certificate.public_key()
        private_public_key = private_key.public_key()
        certificate_public_bytes = certificate_public_key.public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        private_public_bytes = private_public_key.public_bytes(
            serialization.Encoding.DER,
            serialization.PublicFormat.SubjectPublicKeyInfo,
        )
        if certificate_public_bytes != private_public_bytes:
            raise BridgeTLSIdentityError("TLS private key does not match certificate")
        cls._verify_self_signed(certificate)
        _verify_requested_hosts(certificate, requested_hosts)
        return cls._from_material(certificate, certificate_pem, private_key_pem)

    @classmethod
    def _create(
        cls,
        certificate_path: Path,
        credential_backend: CredentialBackend,
        bridge_id: str,
        hosts: Iterable[str],
    ) -> BridgeTLSIdentity:
        private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        private_key_pem = private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
        subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, f"Jarvis Bridge {bridge_id}")])
        not_valid_before = datetime.now(UTC) - timedelta(minutes=5)
        certificate = (
            x509.CertificateBuilder()
            .subject_name(subject)
            .issuer_name(subject)
            .public_key(private_key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(not_valid_before)
            .not_valid_after(not_valid_before + cls.VALIDITY)
            .add_extension(x509.SubjectAlternativeName(_subject_alternative_names(hosts)), False)
            .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
            .sign(private_key, hashes.SHA256())
        )
        certificate_pem = certificate.public_bytes(serialization.Encoding.PEM)

        credential_backend.set_password(
            cls.CREDENTIAL_SERVICE,
            bridge_id,
            private_key_pem.decode("ascii"),
        )
        _write_public_certificate(certificate_path, certificate_pem)
        return cls._from_material(certificate, certificate_pem, private_key_pem)

    @classmethod
    def _from_material(
        cls,
        certificate: x509.Certificate,
        certificate_pem: bytes,
        private_key_pem: bytes,
    ) -> BridgeTLSIdentity:
        certificate_der = certificate.public_bytes(serialization.Encoding.DER)
        return cls(
            certificate_pem=certificate_pem,
            certificate_sha256=hashlib.sha256(certificate_der).hexdigest(),
            private_key_pem=private_key_pem,
        )

    @staticmethod
    def _verify_self_signed(certificate: x509.Certificate) -> None:
        if certificate.issuer != certificate.subject:
            raise BridgeTLSIdentityError("TLS certificate is not self-signed")
        public_key = certificate.public_key()
        if not isinstance(public_key, rsa.RSAPublicKey):
            raise BridgeTLSIdentityError("TLS certificate uses an unsupported public key")
        try:
            public_key.verify(
                certificate.signature,
                certificate.tbs_certificate_bytes,
                padding.PKCS1v15(),
                certificate.signature_hash_algorithm,
            )
        except InvalidSignature as error:
            raise BridgeTLSIdentityError("TLS certificate signature is invalid") from error


def _subject_alternative_names(hosts: Iterable[str]) -> list[x509.GeneralName]:
    names: list[x509.GeneralName] = []
    seen: set[tuple[str, str]] = set()
    for host in ("localhost", "127.0.0.1", "::1", *hosts):
        try:
            address = ipaddress.ip_address(host)
        except ValueError:
            key = ("dns", host.casefold())
            name: x509.GeneralName = x509.DNSName(host)
        else:
            key = ("ip", str(address))
            name = x509.IPAddress(address)
        if key not in seen:
            names.append(name)
            seen.add(key)
    return names


def _write_public_certificate(path: Path, certificate_pem: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path: str | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary_file:
            temporary_file.write(certificate_pem)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
            temporary_path = temporary_file.name
        os.replace(temporary_path, path)
    finally:
        if temporary_path is not None:
            Path(temporary_path).unlink(missing_ok=True)


def _verify_requested_hosts(certificate: x509.Certificate, hosts: Iterable[str]) -> None:
    try:
        alternative_names = certificate.extensions.get_extension_for_class(
            x509.SubjectAlternativeName
        ).value
    except x509.ExtensionNotFound as error:
        raise BridgeTLSIdentityError("TLS certificate SAN extension is missing") from error
    certificate_hosts = {
        ("dns", canonicalize_bridge_host(name))
        for name in alternative_names.get_values_for_type(x509.DNSName)
    }
    certificate_hosts.update(
        ("ip", str(address))
        for address in alternative_names.get_values_for_type(x509.IPAddress)
    )
    requested_hosts = {_normalized_host_key(host) for host in hosts}
    if not requested_hosts.issubset(certificate_hosts):
        raise BridgeTLSIdentityError("TLS certificate SAN does not cover requested hosts")


def _normalized_host_key(host: str) -> tuple[str, str]:
    canonical_host = canonicalize_bridge_host(host)
    try:
        return ("ip", str(ipaddress.ip_address(canonical_host)))
    except ValueError:
        return ("dns", canonical_host)
