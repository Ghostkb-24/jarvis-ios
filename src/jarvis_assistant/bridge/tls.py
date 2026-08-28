from __future__ import annotations

import hashlib
import ipaddress
import os
import tempfile
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import UTC, datetime, timedelta
from pathlib import Path

from cryptography import x509
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from cryptography.x509.oid import NameOID

from jarvis_assistant.bridge.device_store import CredentialBackend


class BridgeTLSIdentityError(RuntimeError):
    """Raised when an established TLS identity cannot be loaded safely."""


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
        stored_key = credential_backend.get_password(cls.CREDENTIAL_SERVICE, bridge_id)
        certificate_exists = path.exists()

        if not certificate_exists and stored_key is None:
            return cls._create(path, credential_backend, bridge_id, hosts)
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
