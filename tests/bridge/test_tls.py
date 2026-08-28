from __future__ import annotations

import hashlib
import ipaddress
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtensionOID, NameOID

from jarvis_assistant.bridge.tls import BridgeTLSIdentity, BridgeTLSIdentityError


class MemoryCredentialBackend:
    def __init__(self) -> None:
        self.passwords: dict[tuple[str, str], str] = {}

    def get_password(self, service: str, username: str) -> str | None:
        return self.passwords.get((service, username))

    def set_password(self, service: str, username: str, value: str) -> None:
        self.passwords[(service, username)] = value

    def delete_password(self, service: str, username: str) -> None:
        self.passwords.pop((service, username), None)


def create_identity(
    tmp_path: Path,
    backend: MemoryCredentialBackend,
    *,
    bridge_id: str = "bridge-01",
) -> BridgeTLSIdentity:
    return BridgeTLSIdentity.load_or_create(
        certificate_path=tmp_path / f"{bridge_id}.pem",
        credential_backend=backend,
        bridge_id=bridge_id,
        hosts=("localhost", "192.168.1.20"),
    )


def test_first_creation_makes_self_signed_private_host_identity(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()

    identity = create_identity(tmp_path, backend)

    certificate_path = tmp_path / "bridge-01.pem"
    certificate = x509.load_pem_x509_certificate(certificate_path.read_bytes())
    assert certificate.issuer == certificate.subject
    assert certificate.not_valid_after_utc - certificate.not_valid_before_utc <= identity.VALIDITY
    alternative_names = certificate.extensions.get_extension_for_oid(
        ExtensionOID.SUBJECT_ALTERNATIVE_NAME
    ).value
    assert "localhost" in alternative_names.get_values_for_type(x509.DNSName)
    assert ipaddress.ip_address("192.168.1.20") in alternative_names.get_values_for_type(
        x509.IPAddress
    )
    private_key = backend.passwords[("jarvis-bridge-tls", "bridge-01")]
    assert "BEGIN PRIVATE KEY" in private_key


@pytest.mark.parametrize("host", ["8.8.8.8", "134744072", "0x08080808", "example.com"])
def test_creation_rejects_public_certificate_host(tmp_path: Path, host: str) -> None:
    with pytest.raises(BridgeTLSIdentityError, match="private"):
        BridgeTLSIdentity.load_or_create(
            certificate_path=tmp_path / "bridge.pem",
            credential_backend=MemoryCredentialBackend(),
            bridge_id="bridge-01",
            hosts=(host,),
        )


def test_reload_rejects_requested_host_missing_from_certificate_sans(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    create_identity(tmp_path, backend)

    with pytest.raises(BridgeTLSIdentityError, match="SAN"):
        BridgeTLSIdentity.load_or_create(
            certificate_path=tmp_path / "bridge-01.pem",
            credential_backend=backend,
            bridge_id="bridge-01",
            hosts=("192.168.1.21",),
        )


def test_trailing_dot_host_is_canonicalized_and_reloads_stably(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    certificate_path = tmp_path / "bridge.pem"

    first = BridgeTLSIdentity.load_or_create(
        certificate_path=certificate_path,
        credential_backend=backend,
        bridge_id="bridge-01",
        hosts=("bridge.local.",),
    )
    certificate = x509.load_pem_x509_certificate(first.certificate_pem)
    alternative_names = certificate.extensions.get_extension_for_oid(
        ExtensionOID.SUBJECT_ALTERNATIVE_NAME
    ).value

    assert "bridge.local" in alternative_names.get_values_for_type(x509.DNSName)
    second = BridgeTLSIdentity.load_or_create(
        certificate_path=certificate_path,
        credential_backend=backend,
        bridge_id="bridge-01",
        hosts=("bridge.local.",),
    )
    assert second.certificate_sha256 == first.certificate_sha256


def test_reload_migrates_legacy_trailing_dot_san_without_rotation(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    certificate_path = tmp_path / "bridge.pem"
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_key_pem = private_key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Jarvis Bridge bridge-01")])
    certificate = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(datetime.now(UTC) - timedelta(minutes=5))
        .not_valid_after(datetime.now(UTC) + timedelta(days=365))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName("bridge.local.")]), False)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), True)
        .sign(private_key, hashes.SHA256())
    )
    certificate_pem = certificate.public_bytes(serialization.Encoding.PEM)
    certificate_path.write_bytes(certificate_pem)
    stored_private_key = private_key_pem.decode("ascii")
    backend.set_password("jarvis-bridge-tls", "bridge-01", stored_private_key)
    expected_fingerprint = hashlib.sha256(
        certificate.public_bytes(serialization.Encoding.DER)
    ).hexdigest()

    loaded = BridgeTLSIdentity.load_or_create(
        certificate_path=certificate_path,
        credential_backend=backend,
        bridge_id="bridge-01",
        hosts=("bridge.local",),
    )

    assert loaded.certificate_pem == certificate_pem
    assert loaded.certificate_sha256 == expected_fingerprint
    assert certificate_path.read_bytes() == certificate_pem
    assert backend.passwords[("jarvis-bridge-tls", "bridge-01")] == stored_private_key


def test_reload_preserves_certificate_fingerprint_and_private_key(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    first = create_identity(tmp_path, backend)
    first_certificate = first.certificate_pem
    first_private_key = backend.passwords[("jarvis-bridge-tls", "bridge-01")]

    second = create_identity(tmp_path, backend)

    assert second.certificate_pem == first_certificate
    assert second.certificate_sha256 == first.certificate_sha256
    assert backend.passwords[("jarvis-bridge-tls", "bridge-01")] == first_private_key


def test_fingerprint_is_lowercase_sha256_of_certificate_der(tmp_path: Path) -> None:
    identity = create_identity(tmp_path, MemoryCredentialBackend())
    certificate = x509.load_pem_x509_certificate(identity.certificate_pem)
    expected = hashlib.sha256(certificate.public_bytes(serialization.Encoding.DER)).hexdigest()

    assert identity.certificate_sha256 == expected
    assert identity.certificate_sha256 == identity.certificate_sha256.lower()


def test_certificate_file_contains_no_private_key(tmp_path: Path) -> None:
    identity = create_identity(tmp_path, MemoryCredentialBackend())

    assert b"BEGIN CERTIFICATE" in identity.certificate_pem
    assert b"PRIVATE KEY" not in (tmp_path / "bridge-01.pem").read_bytes()


def test_corrupt_certificate_fails_closed_without_rotating(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    create_identity(tmp_path, backend)
    private_key = backend.passwords[("jarvis-bridge-tls", "bridge-01")]
    certificate_path = tmp_path / "bridge-01.pem"
    certificate_path.write_bytes(b"not a certificate")

    with pytest.raises(BridgeTLSIdentityError, match="certificate"):
        create_identity(tmp_path, backend)

    assert certificate_path.read_bytes() == b"not a certificate"
    assert backend.passwords[("jarvis-bridge-tls", "bridge-01")] == private_key


def test_mismatched_private_key_fails_closed_without_rotating(tmp_path: Path) -> None:
    backend = MemoryCredentialBackend()
    create_identity(tmp_path, backend, bridge_id="bridge-01")
    create_identity(tmp_path, backend, bridge_id="bridge-02")
    mismatched_key = backend.passwords[("jarvis-bridge-tls", "bridge-02")]
    backend.passwords[("jarvis-bridge-tls", "bridge-01")] = mismatched_key

    with pytest.raises(BridgeTLSIdentityError, match="does not match"):
        create_identity(tmp_path, backend, bridge_id="bridge-01")

    assert backend.passwords[("jarvis-bridge-tls", "bridge-01")] == mismatched_key


@pytest.mark.parametrize("stored_key", [None, "not a private key"])
def test_missing_or_corrupt_private_key_fails_closed(
    tmp_path: Path,
    stored_key: str | None,
) -> None:
    backend = MemoryCredentialBackend()
    identity = create_identity(tmp_path, backend)
    key = ("jarvis-bridge-tls", "bridge-01")
    if stored_key is None:
        backend.passwords.pop(key)
    else:
        backend.passwords[key] = stored_key

    with pytest.raises(BridgeTLSIdentityError, match="private key"):
        create_identity(tmp_path, backend)

    assert (tmp_path / "bridge-01.pem").read_bytes() == identity.certificate_pem
