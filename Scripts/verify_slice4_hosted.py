#!/usr/bin/env python3
"""Run the local Slice 4 hosted, database, infrastructure, and static checks.

This entrypoint is deliberately offline with respect to provider configuration:
it removes inherited AWS/CDK/ROOMSCAN settings and gives CDK only checked-in,
synthetic values.  It does not deploy, bootstrap, or mutate a shared service.
"""

from __future__ import annotations

from dataclasses import dataclass
import argparse
import base64
import binascii
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any, Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]
NODE24_BIN = "/Users/philipnora/.nvm/versions/node/v24.15.0/bin"
EXPECTED_NODE_VERSION = "v24.15.0"
OFFLINE_ACCOUNT_ID = "444444444444"
SECRET_CANARY = "roomscan-secret-canary"
GENERATED_OUTPUT_PATHS: tuple[tuple[str, ...], ...] = (
    ("HostedService", "dist"),
    ("HostedService", ".test-dist"),
    ("HostedService", "infra", "dist"),
    ("HostedService", "infra", ".test-dist"),
    ("HostedService", "infra", "cdk.out"),
)
ARTIFACT_SECRET_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("private key", re.compile(r"-----BEGIN (?:EC |RSA )?PRIVATE KEY-----", re.ASCII)),
    ("AWS access key", re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b", re.ASCII)),
    ("Stripe API secret", re.compile(r"\bsk_(?:live|test)_[A-Za-z0-9_-]{12,}\b", re.ASCII)),
    ("Stripe webhook secret", re.compile(r"\bwhsec_[A-Za-z0-9_-]{12,}\b", re.ASCII)),
    ("authorization bearer value", re.compile(r"\bBearer\s+[A-Za-z0-9._~-]{20,}\b", re.ASCII)),
    ("secret canary", re.compile(re.escape(SECRET_CANARY), re.ASCII)),
)


@dataclass(frozen=True)
class CommandStep:
    label: str
    cwd: Path
    command: tuple[str, ...]


class VerificationFailure(RuntimeError):
    """A required oracle failed after its output was captured."""


def offline_environment(root: Path, inherited: Mapping[str, str] | None = None) -> dict[str, str]:
    """Return a provider-credential-free environment for every local command.

    Do not preserve unknown `ROOMSCAN_*` values: a typo must not silently make
    an offline synth behave like an operator-configured synth.
    """

    source = dict(os.environ if inherited is None else inherited)
    environment = {
        key: value
        for key, value in source.items()
        if not (
            key.startswith("ROOMSCAN_")
            or key.startswith("AWS_")
            or key.startswith("CDK_")
        )
    }
    original_path = source.get("PATH", "")
    environment["PATH"] = (
        f"{NODE24_BIN}{os.pathsep}{original_path}" if original_path else NODE24_BIN
    )
    environment.update(
        {
            "AWS_EC2_METADATA_DISABLED": "true",
            "AWS_REGION": "us-east-1",
            "AWS_DEFAULT_REGION": "us-east-1",
            "CDK_DEFAULT_ACCOUNT": OFFLINE_ACCOUNT_ID,
            "CDK_DEFAULT_REGION": "us-east-1",
            "CI": "true",
            "ROOMSCAN_ACCOUNT_ID": OFFLINE_ACCOUNT_ID,
            "ROOMSCAN_STAGE": "dev",
            "ROOMSCAN_REGION": "us-east-1",
            "ROOMSCAN_AVAILABILITY_ZONES": "us-east-1a,us-east-1b",
            "ROOMSCAN_ACCOUNT_TOPOLOGY_FILE": str(
                root / "HostedService" / "infra" / "test" / "fixtures" / "account-topology.json"
            ),
            "ROOMSCAN_OPERATOR_OWNER": "roomscan-platform-owner",
            "ROOMSCAN_NOTIFICATION_EMAIL": "platform-alerts@example.invalid",
            "ROOMSCAN_SERVICE_DOMAIN": "api.example.invalid",
            "ROOMSCAN_COGNITO_DOMAIN_PREFIX": "roomscan-dev-professional-auth",
            "ROOMSCAN_APPLE_CLIENT_ID": "invalid.example.roomscan.service",
            "ROOMSCAN_APPLE_TEAM_ID": "TESTTEAM01",
            "ROOMSCAN_APPLE_KEY_ID": "TESTKEY001",
            "ROOMSCAN_APPLE_PRIVATE_KEY_SECRET_ARN": (
                "arn:aws:secretsmanager:us-east-1:444444444444:"
                "secret:roomscan-apple-reference-000001"
            ),
            "ROOMSCAN_PROVIDER_SECRETS_KMS_KEY_ARN": (
                "arn:aws:kms:us-east-1:444444444444:"
                "key/00000000-0000-4000-8000-000000000001"
            ),
            "ROOMSCAN_STRIPE_WEBHOOK_SECRET_ARN": (
                "arn:aws:secretsmanager:us-east-1:444444444444:"
                "secret:roomscan-stripe-webhook-reference-000001"
            ),
            "ROOMSCAN_STRIPE_API_SECRET_ARN": (
                "arn:aws:secretsmanager:us-east-1:444444444444:"
                "secret:roomscan-stripe-api-reference-000001"
            ),
            "ROOMSCAN_STRIPE_DEFAULT_ACCOUNT_ID": "acct_0000000000000000",
            "ROOMSCAN_STRIPE_API_VERSION": "2025-06-30.basil",
            "ROOMSCAN_STRIPE_PRICE_PLAN_MAP_JSON": (
                '[{"priceId":"price_test0001",'
                '"planKey":"professional-test-only"}]'
            ),
            "ROOMSCAN_MAGIC_DELIVERY_KEY_ID": "magic-envelope-local-test-v1",
            "ROOMSCAN_POLICY_VALUES_STATUS": "local-test-values-v1",
            "ROOMSCAN_SES_IDENTITY_ARN": (
                "arn:aws:ses:us-east-1:444444444444:identity/example.invalid"
            ),
            "ROOMSCAN_SES_CONFIGURATION_SET_NAME": "roomscan-transactional-dev",
            "ROOMSCAN_SES_SENDER_ADDRESS": "professional@example.invalid",
            "ROOMSCAN_AURORA_MIN_ACU": "0.5",
            "ROOMSCAN_AURORA_MAX_ACU": "2",
            "ROOMSCAN_AURORA_BACKUP_RETENTION_DAYS": "7",
        }
    )
    return environment


def command_plan(root: Path, evidence_directory: Path, *, install: bool) -> list[CommandStep]:
    """Return the ordered fail-fast local verification plan.

    `evidence_directory` is accepted here to make artifact ownership explicit;
    command output is captured there by ``run_verification``.
    """

    del evidence_directory
    service = root / "HostedService"
    database = service / "db"
    infrastructure = service / "infra"
    steps: list[CommandStep] = [
        CommandStep(
            "Task 7 orchestration self-tests",
            root,
            (
                "python3",
                "-B",
                "-m",
                "unittest",
                "Scripts/test_verify_slice4_hosted.py",
                "Scripts/test_verify_slice4_static_controls.py",
                "Scripts/test_inspect_ios_artifact.py",
                "Scripts/test_slice4_ci_contract.py",
            ),
        )
    ]
    if install:
        steps.extend(
            [
                CommandStep("hosted service lockfile install", service, ("npm", "ci")),
                CommandStep("database lockfile install", database, ("npm", "ci")),
                CommandStep("infrastructure lockfile install", infrastructure, ("npm", "ci")),
            ]
        )
    steps.extend(
        [
            CommandStep("hosted service typecheck", service, ("npm", "run", "typecheck")),
            CommandStep("hosted service security tests", service, ("npm", "test")),
            CommandStep("hosted service build", service, ("npm", "run", "build")),
            CommandStep("PostgreSQL 16 role and RLS integration", database, ("npm", "test")),
            CommandStep("infrastructure typecheck", infrastructure, ("npm", "run", "typecheck")),
            CommandStep("infrastructure assertions", infrastructure, ("npm", "test")),
            CommandStep("infrastructure mutation controls", infrastructure, ("npm", "run", "test:mutations")),
            CommandStep(
                "offline infrastructure synth and bundle inspection",
                infrastructure,
                ("npm", "run", "verify"),
            ),
            CommandStep(
                "guest and secret scanner positive controls",
                root,
                ("python3", "-B", "Scripts/verify_slice4_static_controls.py"),
            ),
        ]
    )
    return steps


def find_secret_canary_hits(value: Any, path: str = "$") -> list[str]:
    """Find deterministic secret-canary values through nested log-like data."""

    if isinstance(value, dict):
        return [
            hit
            for key, nested in value.items()
            for hit in find_secret_canary_hits(nested, f"{path}.{key}")
        ]
    if isinstance(value, (list, tuple)):
        return [
            hit
            for index, nested in enumerate(value)
            for hit in find_secret_canary_hits(nested, f"{path}[{index}]")
        ]
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    if isinstance(value, str) and SECRET_CANARY in value:
        return [path]
    return []


def run_secret_scanner_positive_control() -> bool:
    unsafe = {
        "request": {"authorization": "Bearer roomscan-secret-canary-value"},
        "nested": ["whsec_roomscan-secret-canary-value"],
    }
    safe = {"event": "session.revoked", "tokenDigest": "a" * 64}
    unsafe_hits = find_secret_canary_hits(unsafe)
    if len(unsafe_hits) != 2 or find_secret_canary_hits(safe):
        raise VerificationFailure("secret scanner positive control did not discriminate unsafe data")
    run_artifact_secret_scanner_positive_control()
    return True


def run_artifact_secret_scanner_positive_control() -> bool:
    """Prove the built-file detector reaches unsafe bytes and spares digests."""

    with tempfile.TemporaryDirectory(prefix="roomscan-artifact-canary-") as temporary_directory:
        root = Path(temporary_directory)
        unsafe = root / "unsafe.mjs"
        safe = root / "safe.mjs"
        unsafe.write_text('const webhook = "whsec_1234567890abcdef";\n', encoding="utf-8")
        safe.write_text('const digest = "' + ("a" * 64) + '";\n', encoding="utf-8")
        unsafe_hits = find_artifact_secret_hits([unsafe])
        safe_hits = find_artifact_secret_hits([safe])
    if (
        len(unsafe_hits) != 1
        or unsafe_hits[0]["kind"] != "Stripe webhook secret"
        or safe_hits
    ):
        raise VerificationFailure(
            "built artifact secret scanner positive control did not discriminate unsafe data"
        )
    return True


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(128 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _license_values(package_json_path: Path, lock_metadata: Mapping[str, Any]) -> list[str]:
    values: list[str] = []
    lock_license = lock_metadata.get("license")
    if isinstance(lock_license, str) and lock_license:
        values.append(lock_license)
    if package_json_path.is_file():
        try:
            package_document = json.loads(package_json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise VerificationFailure(f"cannot read installed package metadata {package_json_path}: {error}") from error
        package_license = package_document.get("license")
        if isinstance(package_license, str) and package_license:
            values.append(package_license)
        elif isinstance(package_license, Mapping) and isinstance(package_license.get("type"), str):
            values.append(package_license["type"])
    return sorted(set(values))


def _package_name_from_lock_path(lock_path: str) -> str:
    marker = "node_modules/"
    if marker not in lock_path:
        raise VerificationFailure(f"unsupported npm lock package path: {lock_path}")
    return lock_path.rsplit(marker, maxsplit=1)[1]


def _integrity_hashes(value: Any) -> list[dict[str, str]]:
    """Translate npm SRI digests into CycloneDX hash objects."""

    if value is None:
        return []
    if not isinstance(value, str) or not value.strip():
        raise VerificationFailure("npm integrity metadata must be a non-empty string")
    algorithm_names = {
        "sha1": "SHA-1",
        "sha256": "SHA-256",
        "sha384": "SHA-384",
        "sha512": "SHA-512",
    }
    hashes: list[dict[str, str]] = []
    for integrity in value.split():
        algorithm, separator, encoded = integrity.partition("-")
        if not separator or algorithm not in algorithm_names or not encoded:
            raise VerificationFailure("npm integrity metadata uses an unsupported digest")
        try:
            content = base64.b64decode(encoded, validate=True).hex()
        except (ValueError, binascii.Error) as error:
            raise VerificationFailure("npm integrity metadata is not valid base64") from error
        hashes.append({"alg": algorithm_names[algorithm], "content": content})
    return hashes


def _component_reference(*values: str) -> str:
    encoded = json.dumps(values, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return "urn:roomscan:component:" + hashlib.sha256(encoded).hexdigest()


def dependency_inventory(package_roots: Iterable[Path]) -> dict[str, Any]:
    """Build a local, deterministic CycloneDX 1.6 lockfile inventory.

    Licenses are read only from the lockfile or installed package metadata; this
    intentionally does not call a mutable third-party vulnerability service.
    """

    components: list[dict[str, Any]] = []
    for package_root in sorted((path.resolve() for path in package_roots), key=str):
        package_json_path = package_root / "package.json"
        lockfile_path = package_root / "package-lock.json"
        if not package_json_path.is_file() or not lockfile_path.is_file():
            raise VerificationFailure(f"missing deterministic npm metadata below {package_root}")
        try:
            lock_document = json.loads(lockfile_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise VerificationFailure(f"cannot parse lockfile {lockfile_path}: {error}") from error
        try:
            root_document = json.loads(package_json_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            raise VerificationFailure(f"cannot parse package metadata {package_json_path}: {error}") from error
        packages = lock_document.get("packages")
        if not isinstance(packages, Mapping) or not isinstance(packages.get(""), Mapping):
            raise VerificationFailure(f"unsupported npm lockfile structure: {lockfile_path}")
        root_metadata = packages[""]
        direct_kinds: dict[str, list[str]] = {}
        for kind in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
            declared = root_metadata.get(kind)
            if isinstance(declared, Mapping):
                for name in declared:
                    direct_kinds.setdefault(str(name), []).append(kind)
        package_name = root_document.get("name")
        if not isinstance(package_name, str) or not package_name:
            raise VerificationFailure(f"package metadata has no stable name: {package_json_path}")
        root_label = f"{package_name}@{package_root.name}"
        for lock_path, metadata in sorted(packages.items(), key=lambda item: item[0]):
            if not isinstance(lock_path, str) or not lock_path.startswith("node_modules/"):
                continue
            if not isinstance(metadata, Mapping) or not isinstance(metadata.get("version"), str):
                continue
            name = _package_name_from_lock_path(lock_path)
            installed_metadata = package_root / lock_path / "package.json"
            properties = [
                {"name": "roomscan:sourcePackage", "value": root_label},
                {"name": "roomscan:lockPath", "value": lock_path},
            ]
            if name in direct_kinds:
                properties.append(
                    {
                        "name": "roomscan:directKinds",
                        "value": ",".join(sorted(direct_kinds[name])),
                    }
                )
            component: dict[str, Any] = {
                "type": "library",
                "bom-ref": _component_reference(root_label, lock_path, metadata["version"]),
                "name": name,
                "version": metadata["version"],
                "properties": properties,
            }
            hashes = _integrity_hashes(metadata.get("integrity"))
            if hashes:
                component["hashes"] = hashes
            licenses = _license_values(installed_metadata, metadata)
            if licenses:
                component["licenses"] = [
                    {"license": {"name": license_name}} for license_name in licenses
                ]
            components.append(component)
        components.append(
            {
                "type": "file",
                "bom-ref": _component_reference(root_label, "package-lock.json"),
                "name": f"{root_label}/package-lock.json",
                "hashes": [{"alg": "SHA-256", "content": sha256_file(lockfile_path)}],
                "properties": [
                    {
                        "name": "roomscan:packageJsonSha256",
                        "value": sha256_file(package_json_path),
                    }
                ],
            }
        )
    inventory = {
        "$schema": "https://cyclonedx.org/schema/bom-1.6.schema.json",
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {"component": {"type": "application", "name": "roomscan-studio-slice4-local"}},
        "components": components,
    }
    validate_cyclonedx_1_6(inventory)
    return inventory


def validate_cyclonedx_1_6(document: Any) -> None:
    """Validate the exact standards-only CycloneDX 1.6 subset we emit offline."""

    if not isinstance(document, Mapping):
        raise VerificationFailure("CycloneDX inventory must be an object")
    allowed_top = {"$schema", "bomFormat", "specVersion", "version", "metadata", "components"}
    if set(document) != allowed_top:
        raise VerificationFailure("CycloneDX inventory has missing or non-standard top-level fields")
    if document.get("$schema") != "https://cyclonedx.org/schema/bom-1.6.schema.json":
        raise VerificationFailure("CycloneDX inventory has the wrong 1.6 schema identifier")
    if document.get("bomFormat") != "CycloneDX" or document.get("specVersion") != "1.6":
        raise VerificationFailure("CycloneDX inventory has the wrong format or version")
    if not isinstance(document.get("version"), int) or document["version"] < 1:
        raise VerificationFailure("CycloneDX inventory version must be a positive integer")
    metadata = document.get("metadata")
    if not isinstance(metadata, Mapping) or set(metadata) != {"component"}:
        raise VerificationFailure("CycloneDX metadata must contain only its root component")
    root_component = metadata.get("component")
    if (
        not isinstance(root_component, Mapping)
        or set(root_component) != {"type", "name"}
        or root_component.get("type") != "application"
        or not isinstance(root_component.get("name"), str)
        or not root_component["name"]
    ):
        raise VerificationFailure("CycloneDX root component is malformed")
    components = document.get("components")
    if not isinstance(components, list):
        raise VerificationFailure("CycloneDX components must be an array")
    allowed_component = {
        "type",
        "bom-ref",
        "name",
        "version",
        "hashes",
        "licenses",
        "properties",
    }
    hash_lengths = {"SHA-1": 40, "SHA-256": 64, "SHA-384": 96, "SHA-512": 128}
    references: set[str] = set()
    for component in components:
        if not isinstance(component, Mapping) or not set(component).issubset(allowed_component):
            raise VerificationFailure("CycloneDX component uses a non-standard field")
        if component.get("type") not in {"library", "file"}:
            raise VerificationFailure("CycloneDX component type is unsupported")
        reference = component.get("bom-ref")
        if not isinstance(reference, str) or not reference or reference in references:
            raise VerificationFailure("CycloneDX component reference is missing or duplicated")
        references.add(reference)
        if not isinstance(component.get("name"), str) or not component["name"]:
            raise VerificationFailure("CycloneDX component name is missing")
        if "version" in component and (
            not isinstance(component["version"], str) or not component["version"]
        ):
            raise VerificationFailure("CycloneDX component version is malformed")
        if "hashes" in component:
            hashes = component["hashes"]
            if not isinstance(hashes, list) or not hashes:
                raise VerificationFailure("CycloneDX hashes must be a non-empty array")
            for digest in hashes:
                if not isinstance(digest, Mapping) or set(digest) != {"alg", "content"}:
                    raise VerificationFailure("CycloneDX hash is malformed")
                algorithm = digest.get("alg")
                content = digest.get("content")
                if (
                    algorithm not in hash_lengths
                    or not isinstance(content, str)
                    or len(content) != hash_lengths[algorithm]
                    or re.fullmatch(r"[0-9a-fA-F]+", content) is None
                ):
                    raise VerificationFailure("CycloneDX hash content is malformed")
        if "licenses" in component:
            licenses = component["licenses"]
            if not isinstance(licenses, list) or not licenses:
                raise VerificationFailure("CycloneDX licenses must be a non-empty array")
            for choice in licenses:
                if not isinstance(choice, Mapping) or set(choice) != {"license"}:
                    raise VerificationFailure("CycloneDX license choice is malformed")
                license_value = choice.get("license")
                if (
                    not isinstance(license_value, Mapping)
                    or set(license_value) != {"name"}
                    or not isinstance(license_value.get("name"), str)
                    or not license_value["name"]
                ):
                    raise VerificationFailure("CycloneDX named license is malformed")
        if "properties" in component:
            properties = component["properties"]
            if not isinstance(properties, list) or not properties:
                raise VerificationFailure("CycloneDX properties must be a non-empty array")
            for property_value in properties:
                if (
                    not isinstance(property_value, Mapping)
                    or set(property_value) != {"name", "value"}
                    or not isinstance(property_value.get("name"), str)
                    or not property_value["name"]
                    or not isinstance(property_value.get("value"), str)
                ):
                    raise VerificationFailure("CycloneDX property is malformed")


def artifact_manifest(paths: Iterable[Path]) -> dict[str, Any]:
    """Hash the built artifacts rather than trusting their source inputs."""

    supplied = [path.resolve() for path in paths]
    if not supplied:
        raise VerificationFailure("artifact manifest needs at least one supplied artifact path")
    files: list[Path] = []
    for supplied_path in supplied:
        if not supplied_path.exists():
            raise VerificationFailure(f"required built artifact does not exist: {supplied_path}")
        if supplied_path.is_file():
            files.append(supplied_path)
        else:
            files.extend(path for path in supplied_path.rglob("*") if path.is_file())
    if not files:
        raise VerificationFailure("artifact manifest found no built files")
    common_root = Path(os.path.commonpath([str(path.parent) for path in files]))
    records = [
        {
            "path": str(path.relative_to(common_root)),
            "bytes": path.stat().st_size,
            "sha256": sha256_file(path),
        }
        for path in sorted(files, key=str)
    ]
    return {"schemaVersion": 1, "root": str(common_root), "artifacts": records}


def find_artifact_secret_hits(paths: Iterable[Path]) -> list[dict[str, str]]:
    """Return bounded, value-free secret findings in built text artifacts."""

    hits: list[dict[str, str]] = []
    for artifact_path in sorted((path.resolve() for path in paths), key=str):
        if not artifact_path.is_file():
            raise VerificationFailure(f"artifact secret scan requires a file: {artifact_path}")
        text = artifact_path.read_text(encoding="utf-8", errors="replace")
        for kind, pattern in ARTIFACT_SECRET_PATTERNS:
            if pattern.search(text):
                hits.append({"path": str(artifact_path), "kind": kind})
    return hits


def write_generated_evidence(root: Path, evidence_directory: Path) -> dict[str, Any]:
    """Write lockfile SBOM and built-artifact proof under the ignored run directory."""

    service = root / "HostedService"
    infrastructure = service / "infra"
    inventory = dependency_inventory([service, service / "db", infrastructure])
    _write_private(evidence_directory / "sbom.cdx.json", json.dumps(inventory, indent=2) + "\n")
    artifact_roots = [
        service / "dist",
        infrastructure / "cdk.out",
        infrastructure / "evidence" / "artifact-inspection.json",
    ]
    manifest = artifact_manifest(artifact_roots)
    files = [
        path
        for artifact_root in artifact_roots
        for path in (
            [artifact_root]
            if artifact_root.is_file()
            else sorted(candidate for candidate in artifact_root.rglob("*") if candidate.is_file())
        )
    ]
    secret_hits = find_artifact_secret_hits(files)
    if secret_hits:
        raise VerificationFailure(
            "built artifact secret scanner found unsafe material: "
            + ", ".join(f"{hit['kind']} in {hit['path']}" for hit in secret_hits)
        )
    manifest["secretScanner"] = "PASS"
    _write_private(evidence_directory / "artifact-manifest.json", json.dumps(manifest, indent=2) + "\n")
    return {
        "sbom": str(evidence_directory / "sbom.cdx.json"),
        "artifactManifest": str(evidence_directory / "artifact-manifest.json"),
        "artifactCount": len(manifest["artifacts"]),
        "artifactSecretScanner": "PASS",
    }


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def _write_private(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")
    path.chmod(0o600)


def validate_evidence_directory(root: Path, candidate: Path) -> Path:
    """Constrain in-repository evidence to `.artifacts/<run>` only."""

    lexical_root = Path(os.path.abspath(root))
    resolved_root = lexical_root.resolve()
    lexical_candidate = Path(os.path.abspath(candidate))

    try:
        relative_lexical = lexical_candidate.relative_to(lexical_root)
    except ValueError:
        relative_lexical = None
    if relative_lexical is not None:
        cursor = lexical_root
        for component in relative_lexical.parts:
            cursor /= component
            if cursor.is_symlink():
                raise VerificationFailure(
                    "artifact directory must not traverse an in-repository symbolic link"
                )

    resolved_candidate = lexical_candidate.resolve(strict=False)
    try:
        resolved_candidate.relative_to(resolved_root)
    except ValueError:
        return resolved_candidate

    allowed_root = resolved_root / ".artifacts"
    try:
        artifact_relative = resolved_candidate.relative_to(allowed_root)
    except ValueError as error:
        raise VerificationFailure(
            "in-repository artifact directory must be below ROOT/.artifacts"
        ) from error
    if not artifact_relative.parts:
        raise VerificationFailure(
            "artifact directory must be a named descendant of ROOT/.artifacts"
        )
    return resolved_candidate


def clean_generated_outputs(root: Path) -> list[str]:
    """Remove only the validated build directories owned by this verifier."""

    supplied_root = root.absolute()
    resolved_root = root.resolve()
    cleaned: list[str] = []
    for path_parts in GENERATED_OUTPUT_PATHS:
        target = resolved_root.joinpath(*path_parts)
        if target.is_symlink():
            raise VerificationFailure("generated output target must not be a symbolic link")
        try:
            target.resolve(strict=False).relative_to(resolved_root)
        except ValueError as error:
            raise VerificationFailure("generated output target escaped the repository root") from error
        if not target.exists():
            continue
        if not target.is_dir():
            raise VerificationFailure("generated output target must be a directory")
        shutil.rmtree(target)
        cleaned.append(str(supplied_root.joinpath(*path_parts)))
    return cleaned


def _require_node24(environment: Mapping[str, str]) -> str:
    try:
        completed = subprocess.run(
            ("node", "--version"),
            env=dict(environment),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
    except OSError as error:
        raise VerificationFailure("Node 24.15.0 version probe could not start") from error
    version = completed.stdout.strip()
    if completed.returncode != 0 or version != EXPECTED_NODE_VERSION:
        raise VerificationFailure("Slice 4 hosted verification requires Node 24.15.0 exactly")
    return version


def _run_step(step: CommandStep, environment: Mapping[str, str], evidence_directory: Path) -> dict[str, Any]:
    log_path = evidence_directory / "logs" / f"{_slug(step.label)}.log"
    try:
        completed = subprocess.run(
            step.command,
            cwd=step.cwd,
            env=dict(environment),
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=False,
        )
    except OSError as error:
        _write_private(
            log_path,
            json.dumps(
                {
                    "schemaVersion": 1,
                    "label": step.label,
                    "command": list(step.command),
                    "cwd": str(step.cwd),
                    "status": "START_FAILED",
                    "errorType": type(error).__name__,
                },
                indent=2,
            )
            + "\n",
        )
        raise VerificationFailure(
            f"{step.label} could not start ({type(error).__name__})"
        ) from error
    output = completed.stdout or b""
    output_digest = hashlib.sha256(output).hexdigest()
    log_record = {
        "schemaVersion": 1,
        "label": step.label,
        "command": list(step.command),
        "cwd": str(step.cwd),
        "status": "PASS" if completed.returncode == 0 else "FAIL",
        "exitCode": completed.returncode,
        "outputBytes": len(output),
        "outputSha256": output_digest,
    }
    _write_private(log_path, json.dumps(log_record, indent=2) + "\n")
    result = {
        "label": step.label,
        "command": list(step.command),
        "cwd": str(step.cwd),
        "exitCode": completed.returncode,
        "outputBytes": len(output),
        "outputSha256": output_digest,
        "log": str(log_path),
    }
    if completed.returncode != 0:
        raise VerificationFailure(
            f"{step.label} failed with exit {completed.returncode}; inspect {log_path}"
        )
    return result


def _bounded_failure(message: str) -> str:
    sanitized = " ".join(message.split())
    for _, pattern in ARTIFACT_SECRET_PATTERNS:
        sanitized = pattern.sub("[REDACTED]", sanitized)
    if len(sanitized) <= 256:
        return sanitized
    return sanitized[:253] + "..."


def run_verification(root: Path, evidence_directory: Path, *, install: bool) -> int:
    evidence_directory = validate_evidence_directory(root, evidence_directory)
    evidence_directory.mkdir(parents=True, exist_ok=False)
    results: dict[str, Any] = {
        "schemaVersion": 1,
        "root": str(root),
        "steps": [],
        "status": "running",
    }
    try:
        results["cleanedGeneratedOutputs"] = clean_generated_outputs(root)
        environment = offline_environment(root)
        results["node"] = _require_node24(environment)
        results["offlineEnvironment"] = {
            key: environment[key]
            for key in sorted(environment)
            if key.startswith("ROOMSCAN_")
            or key
            in {
                "AWS_EC2_METADATA_DISABLED",
                "CDK_DEFAULT_ACCOUNT",
                "CDK_DEFAULT_REGION",
            }
        }
        results["secretScannerPositiveControl"] = run_secret_scanner_positive_control()
        for step in command_plan(root, evidence_directory, install=install):
            result = _run_step(step, environment, evidence_directory)
            results["steps"].append(result)
        results["generatedEvidence"] = write_generated_evidence(root, evidence_directory)
        results["status"] = "PASS"
        return 0
    except VerificationFailure as error:
        results["status"] = "FAIL"
        results["failure"] = _bounded_failure(str(error))
        print(results["failure"], file=sys.stderr)
        return 1
    except Exception as error:  # defensive terminal-state boundary
        results["status"] = "FAIL"
        results["failure"] = _bounded_failure(
            f"unexpected verification failure ({type(error).__name__})"
        )
        print(results["failure"], file=sys.stderr)
        return 1
    finally:
        if results["status"] == "running":
            results["status"] = "FAIL"
            results["failure"] = "verification terminated without a final result"
        _write_private(evidence_directory / "verification.json", json.dumps(results, indent=2) + "\n")


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--artifacts-dir",
        type=Path,
        default=ROOT / ".artifacts" / "slice4-hosted",
        help="ignored directory to receive this run's logs and manifests",
    )
    parser.add_argument(
        "--skip-install",
        action="store_true",
        help="assume deterministic npm ci has already completed",
    )
    arguments = parser.parse_args(list(argv) if argv is not None else None)
    root = ROOT.resolve()
    try:
        evidence_directory = validate_evidence_directory(root, arguments.artifacts_dir)
    except VerificationFailure as error:
        parser.error(str(error))
    if evidence_directory.exists():
        parser.error(f"artifact directory already exists: {evidence_directory}")
    return run_verification(root, evidence_directory, install=not arguments.skip_install)


if __name__ == "__main__":
    raise SystemExit(main())
