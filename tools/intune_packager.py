#!/usr/bin/env python3
"""Packt eine Homebrew-Cask-App als .intunemac und lädt sie in Intune.

Verwendung (lokal oder in CI):
  python tools/intune_packager.py --cask google-chrome     --output-dir output     --display-name "Google Chrome"     --publisher "Google"

Benötigte Umgebungsvariablen für den Intune Upload:
  INTUNE_TENANT_ID, INTUNE_CLIENT_ID

Authentifizierungsoptionen:
  - INTUNE_ACCESS_TOKEN (bevorzugt, via GitHub OIDC/Federated Credentials)
  - INTUNE_CLIENT_SECRET (Legacy-Client-Secret als Fallback)
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import logging
import mimetypes
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable, Optional
from urllib import parse, request

from Crypto.Cipher import AES
from Crypto.Hash import HMAC, SHA256
from Crypto.Util.Padding import pad

LOG_FORMAT = "[%(levelname)s] %(message)s"
logging.basicConfig(level=logging.INFO, format=LOG_FORMAT)
LOGGER = logging.getLogger("intune-packager")

DEFAULT_MIN_OS = {
    "v10_15": True,
    "v11_0": True,
    "v12_0": True,
}
CHUNK_SIZE = 4 * 1024 * 1024  # 4 MiB
BLOCK_SIZE = 8 * 1024 * 1024  # 8 MiB for Azure Block Blob uploads
INTUNE_ICON_MIME_TYPES = {"image/png", "image/jpeg"}


@dataclass
class BrewCask:
    token: str
    version: str
    app_names: list[str]
    desc: str
    homepage: str
    bundle_version: Optional[str]
    bundle_short_version: Optional[str]


class CommandError(RuntimeError):
    pass


def normalize_base64(value: Optional[str]) -> Optional[str]:
    if not value:
        return None
    raw = value.strip()
    if "," in raw:
        raw = raw.split(",", 1)[1]
    if not raw:
        return None
    # Validate early so the workflow fails before creating the app object.
    base64.b64decode(raw, validate=True)
    return raw


def run(cmd: Iterable[str], *, cwd: Optional[Path] = None, check: bool = True) -> subprocess.CompletedProcess:
    LOGGER.debug("Running command: %s", " ".join(cmd))
    result = subprocess.run(
        list(cmd),
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if check and result.returncode != 0:
        raise CommandError(
            f"Command {' '.join(cmd)} failed with exit code {result.returncode}:\n{result.stderr.strip()}"
        )
    return result


def ensure_tool_executable(path: Path) -> None:
    mode = path.stat().st_mode
    path.chmod(mode | stat.S_IEXEC)


def generate_key() -> bytes:
    return os.urandom(32)


def generate_iv() -> bytes:
    return os.urandom(16)


def encrypt_package_for_intune(source: Path) -> tuple[Path, dict[str, str], int, int]:
    encryption_key = generate_key()
    mac_key = generate_key()
    iv = generate_iv()
    mac_length = len(mac_key)
    buffer_size = 1024 * 1024

    fd, temp_name = tempfile.mkstemp(suffix=".intune.enc")
    os.close(fd)
    encrypted_path = Path(temp_name)

    try:
        with source.open("rb") as src, encrypted_path.open("wb") as target:
            target.write(b"\x00" * (mac_length + len(iv)))
            cipher = AES.new(encryption_key, AES.MODE_CBC, iv)

            buffer = src.read(buffer_size)
            if not buffer:
                target.write(cipher.encrypt(pad(b"", AES.block_size)))
            else:
                while True:
                    next_chunk = src.read(buffer_size)
                    if next_chunk:
                        target.write(cipher.encrypt(buffer))
                        buffer = next_chunk
                    else:
                        target.write(cipher.encrypt(pad(buffer, AES.block_size)))
                        break

        with encrypted_path.open("r+b") as final:
            final.seek(mac_length)
            final.write(iv)
            final.seek(mac_length)
            mac_calc = HMAC.new(mac_key, digestmod=SHA256)
            while True:
                data = final.read(buffer_size)
                if not data:
                    break
                mac_calc.update(data)
            mac_value = mac_calc.digest()
            final.seek(0)
            final.write(mac_value)

        digest_calc = hashlib.sha256()
        with source.open("rb") as original:
            while True:
                data = original.read(buffer_size)
                if not data:
                    break
                digest_calc.update(data)

        encryption_info = {
            "encryptionKey": base64.b64encode(encryption_key).decode(),
            "macKey": base64.b64encode(mac_key).decode(),
            "initializationVector": base64.b64encode(iv).decode(),
            "mac": base64.b64encode(mac_value).decode(),
            "profileIdentifier": "ProfileVersion1",
            "fileDigest": base64.b64encode(digest_calc.digest()).decode(),
            "fileDigestAlgorithm": "SHA256",
        }

        plain_size = source.stat().st_size
        encrypted_size = encrypted_path.stat().st_size
        return encrypted_path, encryption_info, plain_size, encrypted_size
    except Exception:
        if encrypted_path.exists():
            encrypted_path.unlink()
        raise


def wait_for_file_processing(
    client: "IntuneClient", file_uri: str, stage: str, attempts: int = 240, wait_seconds: int = 5
) -> dict:
    # Use lowercase first letter to match Azure's actual state names
    success_state = f"{stage[0].lower()}{stage[1:]}Success"
    pending_state = f"{stage[0].lower()}{stage[1:]}Pending"
    failure_states = {f"{stage[0].lower()}{stage[1:]}Failed", f"{stage[0].lower()}{stage[1:]}TimedOut"}

    LOGGER.info("Warte auf Status '%s' für %s", success_state, stage)
    while attempts > 0:
        try:
            file_info = client._graph_request("GET", file_uri)
        except RuntimeError as exc:
            message = str(exc)
            if "ResourceNotFound" in message or "404" in message:
                time.sleep(wait_seconds)
                attempts -= 1
                continue
            raise
        state = file_info.get("uploadState")
        LOGGER.info("Aktueller Upload-Status: %s (erwartet: %s, Versuche übrig: %d)", state, success_state, attempts)
        if state == success_state:
            LOGGER.info("Status erfolgreich erreicht: %s", success_state)
            return file_info
        if state in failure_states:
            raise RuntimeError(f"File upload state ist {state}")
        time.sleep(wait_seconds)
        attempts -= 1
    raise RuntimeError(f"File request did not complete in der vorgesehenen Zeit. Letzter Status: {state}")


def fetch_cask_metadata(cask_id: str) -> BrewCask:
    result = run(["brew", "info", "--cask", "--json=v2", cask_id])
    payload = json.loads(result.stdout)
    casks = payload.get("casks", [])
    if not casks:
        raise ValueError(f"Keine Cask-Metadaten für {cask_id} gefunden")
    cask = casks[0]
    artifacts = cask.get("artifacts", [])
    app_names: list[str] = []
    for artifact in artifacts:
        if "app" in artifact:
            items = artifact["app"]
            if isinstance(items, list):
                app_names.extend(items)
            elif isinstance(items, str):
                app_names.append(items)
    if not app_names:
        raise ValueError(
            f"Cask {cask_id} enthält kein 'app' Artefakt – nur .pkg Casks werden unterstützt."
        )
    return BrewCask(
        token=cask["token"],
        version=cask["version"],
        app_names=app_names,
        desc=cask.get("desc", ""),
        homepage=cask.get("homepage", ""),
        bundle_version=cask.get("bundle_version"),
        bundle_short_version=cask.get("bundle_short_version"),
    )


def install_cask(cask_id: str) -> None:
    LOGGER.info("Installiere Homebrew Cask %s", cask_id)
    run(["brew", "install", "--cask", cask_id])


def resolve_caskroom_path(cask_id: str, version: str) -> Path:
    prefix = run(["brew", "--prefix"]).stdout.strip()
    base = Path(prefix)
    caskroom = base / "Caskroom"
    if not caskroom.exists():
        # Apple Silicon Runner
        caskroom = Path("/opt/homebrew/Caskroom")
    path = caskroom / cask_id / version
    if not path.exists():
        raise FileNotFoundError(f"Erwarteter Caskroom Pfad nicht gefunden: {path}")
    return path


@dataclass
class BundleMetadata:
    bundle_id: str
    bundle_name: str
    version: str


def read_bundle_metadata(app_path: Path) -> BundleMetadata:
    info_plist = app_path / "Contents" / "Info.plist"
    if not info_plist.exists():
        raise FileNotFoundError(f"Keine Info.plist gefunden unter {info_plist}")
    with info_plist.open("rb") as handle:
        info = plistlib.load(handle)
    bundle_id = info.get("CFBundleIdentifier")
    if not bundle_id:
        raise ValueError(f"CFBundleIdentifier fehlt in {info_plist}")
    bundle_name = info.get("CFBundleName") or info.get("CFBundleDisplayName") or app_path.stem
    version = info.get("CFBundleShortVersionString") or info.get("CFBundleVersion")
    if not version:
        raise ValueError(f"Konnte Version nicht aus Info.plist lesen ({info_plist})")
    return BundleMetadata(bundle_id=bundle_id, bundle_name=bundle_name, version=str(version))


def build_pkg(app_path: Path, metadata: BundleMetadata, output_dir: Path) -> Path:
    LOGGER.info("Erzeuge temporäres pkg für %s", metadata.bundle_name)
    with tempfile.TemporaryDirectory() as tmp_root:
        root = Path(tmp_root) / "root" / "Applications"
        root.mkdir(parents=True, exist_ok=True)
        destination = root / app_path.name
        LOGGER.debug("Kopiere App nach %s", destination)
        if destination.exists():
            shutil.rmtree(destination)
        shutil.copytree(app_path, destination, symlinks=True)

        output_dir.mkdir(parents=True, exist_ok=True)
        pkg_path = output_dir / f"{metadata.bundle_name.replace(' ', '')}-{metadata.version}.pkg"
        if pkg_path.exists():
            pkg_path.unlink()
        run(
            [
                "pkgbuild",
                "--root",
                str(root.parent),
                "--identifier",
                metadata.bundle_id,
                "--version",
                metadata.version,
                "--install-location",
                "/Applications",
                str(pkg_path),
            ]
        )
    LOGGER.info("PKG erstellt: %s", pkg_path)
    return pkg_path


def sign_pkg(pkg_path: Path, identity: str) -> Path:
    LOGGER.info("Signiere PKG mit Identität '%s'", identity)
    signed_path = pkg_path.with_suffix(".signed.pkg")
    if signed_path.exists():
        signed_path.unlink()
    run([
        "productsign",
        "--sign",
        identity,
        str(pkg_path),
        str(signed_path),
    ])
    shutil.move(str(signed_path), str(pkg_path))
    return pkg_path


def check_pkg_signature(pkg_path: Path) -> None:
    try:
        result = run(["pkgutil", "--check-signature", str(pkg_path)], check=False)
    except FileNotFoundError:
        LOGGER.warning("pkgutil nicht gefunden, kann Signatur von %s nicht prüfen", pkg_path)
        return
    output = (result.stdout + result.stderr).strip()
    if "No signature" in output or "Status: unsigned" in output:
        LOGGER.warning(
            "PKG %s ist nicht signiert. Intune akzeptiert nur Pakete mit 'Developer ID Installer' Signatur.",
            pkg_path,
        )
    else:
        LOGGER.info("Signaturprüfung erfolgreich: %s", pkg_path)


def convert_icon_to_png(icon_path: Path) -> bytes:
    with tempfile.TemporaryDirectory() as tmpdir:
        temp_dir = Path(tmpdir)
        png_path = temp_dir / "icon.png"
        try:
            run([
                "sips",
                "-s",
                "format",
                "png",
                str(icon_path),
                "--out",
                str(png_path),
            ])
        except (CommandError, FileNotFoundError):
            iconset_dir = temp_dir / "icon.iconset"
            try:
                run([
                    "iconutil",
                    "-c",
                    "iconset",
                    str(icon_path),
                    "-o",
                    str(iconset_dir),
                ])
            except (CommandError, FileNotFoundError) as exc:
                raise RuntimeError(
                    f"Icon konnte nicht nach PNG konvertiert werden: {icon_path}"
                ) from exc
            if not iconset_dir.exists():
                raise RuntimeError(
                    f"Icon-Konvertierung hat kein iconset erzeugt: {icon_path}"
                )
            png_candidates = sorted(
                iconset_dir.glob("*.png"),
                key=lambda candidate: candidate.stat().st_size,
                reverse=True,
            )
            if not png_candidates:
                raise RuntimeError(
                    f"Keine PNG-Dateien nach Icon-Konvertierung gefunden: {icon_path}"
                )
            source_png = png_candidates[0]
            png_path = temp_dir / "icon.png"
            shutil.copy(source_png, png_path)
        if not png_path.exists():
            raise RuntimeError(f"PNG Icon wurde nicht erzeugt: {png_path}")

        # Resize to an Intune-friendly size (max 256px) and ensure PNG output
        try:
            run([
                "sips",
                "-s",
                "format",
                "png",
                "-Z",
                "256",
                str(png_path),
                "--out",
                str(png_path),
            ])
        except (CommandError, FileNotFoundError):
            # Ignore resize issues; best-effort optimisation
            pass

        png_bytes = png_path.read_bytes()
        if not png_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
            raise RuntimeError("Konvertiertes Icon ist keine gültige PNG-Datei")
        return png_bytes


def load_icon_payload(icon_path: Optional[Path]) -> Optional[dict[str, str]]:
    """Load and validate icon for Intune upload.

    Intune requirements:
    - Format: PNG or JPEG
    - Max size: 1 MB (base64 encoded)
    - Recommended dimensions: 256x256px or smaller
    """
    if not icon_path:
        return None
    if not icon_path.exists():
        raise FileNotFoundError(f"Icon-Datei nicht gefunden: {icon_path}")

    mime_type, _ = mimetypes.guess_type(str(icon_path))
    if mime_type in INTUNE_ICON_MIME_TYPES:
        raw_bytes = icon_path.read_bytes()
    else:
        raw_bytes = convert_icon_to_png(icon_path)
        mime_type = "image/png"

    mime_type = mime_type or "image/png"

    # Validate icon size (Intune has a 1MB limit for base64 encoded icons)
    MAX_ICON_SIZE = 1 * 1024 * 1024  # 1 MB
    if len(raw_bytes) > MAX_ICON_SIZE:
        LOGGER.warning(
            "Icon size (%d bytes) exceeds recommended limit of %d bytes. Icon may be rejected by Intune.",
            len(raw_bytes),
            MAX_ICON_SIZE,
        )
        # Don't fail, but warn - let Intune reject it if needed

    content = base64.b64encode(raw_bytes).decode()

    # Additional check on base64 size
    if len(content) > MAX_ICON_SIZE:
        LOGGER.error(
            "Base64 encoded icon size (%d bytes) exceeds Intune limit of %d bytes. Skipping icon.",
            len(content),
            MAX_ICON_SIZE,
        )
        return None  # Skip icon instead of failing

    return {
        "@odata.type": "#microsoft.graph.mimeContent",
        "type": mime_type,
        "value": content,
    }


@dataclass
class IntuneConfig:
    tenant_id: str
    client_id: str
    client_secret: Optional[str] = None
    access_token: Optional[str] = None
    graph_url: str = "https://graph.microsoft.com"
    api_version: str = "beta"


class IntuneClient:
    def __init__(self, config: IntuneConfig):
        self.config = config
        self._token: Optional[str] = config.access_token

    @property
    def token(self) -> str:
        if self._token is None:
            self._token = self._acquire_token()
        return self._token

    def _acquire_token(self) -> str:
        if self.config.access_token:
            LOGGER.info("Verwende bereitgestelltes Intune Access Token")
            return self.config.access_token

        if not self.config.client_secret:
            raise RuntimeError(
                "Fehlende Intune Authentifizierung. Stellen Sie entweder INTUNE_ACCESS_TOKEN oder INTUNE_CLIENT_SECRET bereit."
            )

        LOGGER.info("Fordere Azure AD Token an")
        token_url = (
            f"https://login.microsoftonline.com/{self.config.tenant_id}/oauth2/v2.0/token"
        )
        data = parse.urlencode(
            {
                "client_id": self.config.client_id,
                "scope": "https://graph.microsoft.com/.default",
                "client_secret": self.config.client_secret,
                "grant_type": "client_credentials",
            }
        ).encode()
        req = request.Request(token_url, data=data, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        with request.urlopen(req) as resp:
            payload = json.load(resp)
        access_token = payload.get("access_token")
        if not access_token:
            raise RuntimeError("Kein access_token in Azure AD Antwort erhalten")
        self.config.access_token = access_token
        return access_token

    def _graph_request(self, method: str, endpoint: str, *, data=None, headers=None, expected=200):
        url = f"{self.config.graph_url}/{self.config.api_version}/{endpoint.lstrip('/')}"
        req = request.Request(url, method=method.upper())
        req.add_header("Authorization", f"Bearer {self.token}")
        req.add_header("Content-Type", "application/json")
        if headers:
            for key, value in headers.items():
                req.add_header(key, value)
        if data is not None:
            body = json.dumps(data).encode()
            req.data = body
        try:
            with request.urlopen(req) as resp:
                status = resp.status
                body = resp.read()
        except request.HTTPError as exc:  # type: ignore[attr-defined]
            error_body = exc.read().decode(errors="ignore") if hasattr(exc, "read") else ""
            raise RuntimeError(
                f"Anfrage an {url} fehlgeschlagen ({exc.code}): {error_body or exc.reason}"
            ) from exc
        except Exception as exc:
            raise RuntimeError(f"Anfrage an {url} fehlgeschlagen: {exc}")
        if status not in ([expected] if isinstance(expected, int) else expected):
            raise RuntimeError(
                f"Graph Anfrage {method} {url} schlug fehl ({status}): {body.decode(errors='ignore')}"
            )
        if body:
            return json.loads(body)
        return {}

    def create_mac_app(self, metadata: BundleMetadata, params: dict, file_name: str) -> str:
        LOGGER.info("Erzeuge Platzhalter in Intune für %s", metadata.bundle_name)
        payload = {
            "@odata.type": "#microsoft.graph.macOSPkgApp",
            "displayName": params.get("displayName", metadata.bundle_name),
            "description": params.get("description", metadata.bundle_name),
            "publisher": params.get("publisher", "Homebrew"),
            "bundleId": metadata.bundle_id,
            "buildNumber": metadata.version,
            "versionNumber": metadata.version,
            "primaryBundleId": metadata.bundle_id,
            "primaryBundleVersion": metadata.version,
            "ignoreVersionDetection": False,
            "fileName": file_name,
            "includedApps": [
                {
                    "@odata.type": "#microsoft.graph.macOSIncludedApp",
                    "bundleId": metadata.bundle_id,
                    "bundleVersion": metadata.version,
                }
            ],
            "childApps": [
                {
                    "bundleId": metadata.bundle_id,
                    "buildNumber": metadata.version,
                    "versionNumber": metadata.version,
                }
            ],
            "minimumSupportedOperatingSystem": params.get(
                "minimumSupportedOperatingSystem", DEFAULT_MIN_OS
            ),
        }
        icon_payload = params.get("largeIcon")
        if icon_payload:
            payload["largeIcon"] = icon_payload
        pre_install_script = params.get("preInstallScript")
        if pre_install_script:
            payload["preInstallScript"] = {
                "@odata.type": "#microsoft.graph.macOSAppScript",
                "scriptContent": pre_install_script,
            }
        post_install_script = params.get("postInstallScript")
        if post_install_script:
            payload["postInstallScript"] = {
                "@odata.type": "#microsoft.graph.macOSAppScript",
                "scriptContent": post_install_script,
            }
        response = self._graph_request("POST", "/deviceAppManagement/mobileApps", data=payload, expected=201)
        app_id = response.get("id")
        if not app_id:
            raise RuntimeError("Graph Antwort enthält keine App-ID")
        return app_id

    def create_content_version(self, app_id: str) -> str:
        endpoint = (
            f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions"
        )
        payload = {"@odata.type": "#microsoft.graph.mobileAppContent"}
        response = self._graph_request("POST", endpoint, data=payload, expected=201)
        content_version = response.get("id")
        if not content_version:
            raise RuntimeError("Graph Antwort enthält keine Content-Version-ID")
        return content_version

    def add_content_file(
        self, app_id: str, content_version: str, file_name: str, size: int, size_encrypted: int
    ) -> dict:
        endpoint = (
            f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions/{content_version}/files"
        )
        payload = {
            "@odata.type": "#microsoft.graph.mobileAppContentFile",
            "name": file_name,
            "size": size,
            "sizeEncrypted": size_encrypted,
            "uploadState": "azureStorageUriRequestPending",
            "isCommitted": False,
            "isDependency": False,
            "isFrameworkFile": False,
            "manifest": None,
        }
        response = self._graph_request("POST", endpoint, data=payload, expected=201)
        file_id = response.get("id")
        if not file_id:
            raise RuntimeError("Graph Antwort enthält keine Datei-ID")
        return response

    def create_upload_session(self, app_id: str, content_version: str, file_id: str) -> dict:
        endpoint = (
            f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions/{content_version}/files/{file_id}/microsoft.graph.createUploadSession"
        )
        return self._graph_request("POST", endpoint, data={}, expected=[200, 201])

    def renew_upload_url(self, app_id: str, content_version: str, file_id: str) -> dict:
        endpoint = (
            f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions/{content_version}/files/{file_id}/microsoft.graph.renewUpload"
        )
        return self._graph_request("POST", endpoint, data={}, expected=[200, 204])

    def commit_file(
        self,
        app_id: str,
        content_version: str,
        file_id: str,
        file_digest: str,
        encryption_info: Optional[dict] = None,
    ) -> None:
        endpoint = (
            f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions/{content_version}/files/{file_id}/commit"
        )
        payload_info = {
            "fileDigest": file_digest,
            "fileDigestAlgorithm": "SHA256",
            "profileIdentifier": "ProfileVersion1",
        }
        if encryption_info:
            payload_info.update({
                "encryptionKey": encryption_info.get("encryptionKey"),
                "initializationVector": encryption_info.get("initializationVector"),
                "mac": encryption_info.get("mac"),
                "macKey": encryption_info.get("macKey"),
                "profileIdentifier": encryption_info.get("profileIdentifier", "ProfileVersion1"),
            })
        payload = {"fileEncryptionInfo": payload_info}
        self._graph_request("POST", endpoint, data=payload, expected=[200, 204])

    def commit_app_content(
        self,
        app_id: str,
        content_version: str,
        file_name: str,
        file_id: str,
        file_size: int,
    ) -> None:
        payload = {
            "@odata.type": "#microsoft.graph.macOSPkgApp",
            "committedContentVersion": content_version,
        }
        endpoint = f"/deviceAppManagement/mobileApps/{app_id}"
        self._graph_request("PATCH", endpoint, data=payload, expected=[200, 204])


def upload_file(upload_url: str, file_path: Path) -> None:
    """Upload file to Azure Storage using Block Blob API."""
    LOGGER.info("Lade Paket zu Intune hoch (%s)", file_path)
    file_size = file_path.stat().st_size
    file_size_mb = file_size / (1024 * 1024)
    LOGGER.info("Dateigröße: %.2f MB", file_size_mb)

    total_blocks = (file_size + BLOCK_SIZE - 1) // BLOCK_SIZE
    LOGGER.info("Upload in %d Blöcken (je %d MB)", total_blocks, BLOCK_SIZE // (1024 * 1024))

    block_ids = []
    max_retries = 3

    with file_path.open("rb") as handle:
        for block_num in range(total_blocks):
            # Generate unique block ID
            block_id_str = f"{block_num:06d}"
            block_id_bytes = block_id_str.encode("utf-8")
            block_id_b64 = base64.b64encode(block_id_bytes).decode("utf-8")
            block_ids.append(block_id_b64)

            # Read block data
            block_data = handle.read(BLOCK_SIZE)
            if not block_data:
                break

            block_len = len(block_data)
            progress = ((block_num + 1) / total_blocks) * 100

            # Upload block with retries
            block_uploaded = False
            for retry in range(max_retries):
                try:
                    # Construct block URL
                    separator = "&" if "?" in upload_url else "?"
                    block_url = f"{upload_url}{separator}comp=block&blockid={parse.quote(block_id_b64)}"

                    req = request.Request(block_url, data=block_data, method="PUT")
                    req.add_header("Content-Type", "application/octet-stream")
                    req.add_header("Content-Length", str(block_len))
                    req.add_header("x-ms-blob-type", "BlockBlob")

                    with request.urlopen(req, timeout=300) as resp:
                        if resp.status not in (200, 201, 202):
                            raise RuntimeError(
                                f"Block upload fehlgeschlagen (Status {resp.status}): {resp.read().decode(errors='ignore')}"
                            )

                    LOGGER.info(
                        "Block %d/%d hochgeladen (%.1f%%, %d bytes)",
                        block_num + 1,
                        total_blocks,
                        progress,
                        block_len,
                    )
                    block_uploaded = True
                    break

                except Exception as exc:
                    if retry < max_retries - 1:
                        LOGGER.warning(
                            "Block %d Upload-Versuch %d/%d fehlgeschlagen: %s. Wiederhole...",
                            block_num + 1,
                            retry + 1,
                            max_retries,
                            exc,
                        )
                        time.sleep(2 ** retry)  # Exponential backoff
                    else:
                        raise RuntimeError(f"Block {block_num + 1} Upload nach {max_retries} Versuchen fehlgeschlagen") from exc

            if not block_uploaded:
                raise RuntimeError(f"Block {block_num + 1} konnte nicht hochgeladen werden")

    # Commit block list
    LOGGER.info("Alle Blöcke hochgeladen. Committe Block-Liste...")
    block_list_xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
    for block_id in block_ids:
        block_list_xml += f"<Latest>{block_id}</Latest>"
    block_list_xml += "</BlockList>"

    separator = "&" if "?" in upload_url else "?"
    commit_url = f"{upload_url}{separator}comp=blocklist"

    req = request.Request(commit_url, data=block_list_xml.encode("utf-8"), method="PUT")
    req.add_header("Content-Type", "application/xml")
    req.add_header("Content-Length", str(len(block_list_xml)))

    with request.urlopen(req, timeout=300) as resp:
        if resp.status not in (200, 201):
            raise RuntimeError(
                f"Block-List Commit fehlgeschlagen (Status {resp.status}): {resp.read().decode(errors='ignore')}"
            )

    LOGGER.info("Upload abgeschlossen und committed")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package Homebrew Cask or uploaded macOS package to Intune")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--cask", help="Homebrew Cask Token")
    source.add_argument("--pkg-file", help="Path to an uploaded .pkg file")
    source.add_argument("--dmg-file", help="Path to an uploaded .dmg file")
    parser.add_argument("--output-dir", default="output", help="Zielordner für Artefakte")
    parser.add_argument("--display-name", default=None, help="Anzeigename in Intune")
    parser.add_argument("--publisher", default=None, help="Publisher in Intune")
    parser.add_argument("--description", default=None, help="Beschreibung in Intune")
    parser.add_argument("--app-version", default=None, help="Version for uploaded custom PKG/DMG packages")
    parser.add_argument("--bundle-id", default=None, help="Primary bundle id for uploaded custom PKG packages")
    parser.add_argument("--bundle-name", default=None, help="Primary bundle name for uploaded custom PKG packages")
    parser.add_argument("--icon-file", default=None, help="Pfad zu einem PNG/JPG Icon")
    parser.add_argument("--pre-install-script-b64", default=None, help="Base64-kodiertes Pre-Install-Script")
    parser.add_argument("--post-install-script-b64", default=None, help="Base64-kodiertes Post-Install-Script")
    parser.add_argument(
        "--skip-upload", action="store_true", help="Nur Paket erstellen, nicht in Intune hochladen"
    )
    parser.add_argument(
        "--generate-footprint-report",
        action="store_true",
        help="Footprint-Analyse generieren (installiert und deinstalliert App zur Analyse)",
    )
    return parser.parse_args(argv)


def load_intune_config() -> IntuneConfig:
    tenant_id = os.environ.get("INTUNE_TENANT_ID") or os.environ.get("AZURE_TENANT_ID", "")
    client_id = os.environ.get("INTUNE_CLIENT_ID") or os.environ.get("AZURE_CLIENT_ID", "")
    client_secret = os.environ.get("INTUNE_CLIENT_SECRET") or None
    access_token = (
        os.environ.get("INTUNE_ACCESS_TOKEN")
        or os.environ.get("AZURE_ACCESS_TOKEN")
        or None
    )

    missing_core = [
        name
        for name, value in (("INTUNE_TENANT_ID", tenant_id), ("INTUNE_CLIENT_ID", client_id))
        if not value
    ]
    if missing_core:
        raise RuntimeError(
            "Fehlende Intune Konfiguration ({}).".format("/".join(missing_core))
        )

    if not access_token and not client_secret:
        raise RuntimeError(
            "Fehlende Intune Authentifizierung. Stellen Sie INTUNE_ACCESS_TOKEN oder INTUNE_CLIENT_SECRET bereit."
        )

    return IntuneConfig(
        tenant_id=tenant_id,
        client_id=client_id,
        client_secret=client_secret,
        access_token=access_token,
    )


def normalize_display_name(base_name: str, version: str) -> str:
    candidate = base_name.strip()
    if version and version not in candidate:
        candidate = f"{candidate} {version}"
    return candidate


def slug(value: str) -> str:
    normalized = "".join(ch.lower() if ch.isalnum() else "." for ch in value)
    return ".".join(part for part in normalized.split(".") if part) or "custom"


def metadata_from_args(args: argparse.Namespace, source_path: Path) -> BundleMetadata:
    name = args.bundle_name or args.display_name or source_path.stem
    version = args.app_version or "1.0.0"
    bundle_id = args.bundle_id or f"com.moderndevmgmt.custom.{slug(name)}"
    return BundleMetadata(bundle_id=bundle_id, bundle_name=name, version=version)


def copy_pkg_for_upload(source: Path, output_dir: Path) -> Path:
    if not source.exists():
        raise FileNotFoundError(f"PKG-Datei nicht gefunden: {source}")
    output_dir.mkdir(parents=True, exist_ok=True)
    target = output_dir / source.name
    if source.resolve() != target.resolve():
        shutil.copy2(source, target)
    return target


def first_payload_from_dmg(dmg_path: Path, output_dir: Path, fallback_metadata: BundleMetadata) -> tuple[Path, BundleMetadata]:
    if not dmg_path.exists():
        raise FileNotFoundError(f"DMG-Datei nicht gefunden: {dmg_path}")
    LOGGER.info("Mounte DMG %s", dmg_path)
    attach = run(["hdiutil", "attach", "-nobrowse", "-readonly", "-plist", str(dmg_path)])
    payload = plistlib.loads(attach.stdout.encode("utf-8"))
    mount_points = [
        entity.get("mount-point")
        for entity in payload.get("system-entities", [])
        if entity.get("mount-point")
    ]
    if not mount_points:
        raise RuntimeError(f"DMG konnte nicht gemountet werden: {dmg_path}")
    mounted_paths = [Path(point) for point in mount_points]
    try:
        for mount_point in mounted_paths:
            app_candidates = sorted(mount_point.rglob("*.app"))
            if app_candidates:
                metadata = read_bundle_metadata(app_candidates[0])
                pkg_output_dir = output_dir / metadata.bundle_id
                return build_pkg(app_candidates[0], metadata, pkg_output_dir), metadata
        for mount_point in mounted_paths:
            pkg_candidates = sorted(mount_point.rglob("*.pkg"))
            if pkg_candidates:
                return copy_pkg_for_upload(pkg_candidates[0], output_dir), fallback_metadata
    finally:
        for mount_point in mounted_paths:
            run(["hdiutil", "detach", str(mount_point)], check=False)
    raise RuntimeError(f"DMG enthält keine unterstützte .app oder .pkg Payload: {dmg_path}")


def resolve_package_source(args: argparse.Namespace) -> tuple[Path, BundleMetadata, Optional[BrewCask]]:
    output_dir = Path(args.output_dir)
    if args.cask:
        cask = fetch_cask_metadata(args.cask)
        install_cask(args.cask)
        cask_path = resolve_caskroom_path(cask.token, cask.version)
        app_path = None
        for app_name in cask.app_names:
            candidate = cask_path / app_name
            if candidate.exists():
                app_path = candidate
                break
        if not app_path:
            raise FileNotFoundError(
                f"Konnte kein App Bundle für {args.cask} finden. Erwartete eine der folgenden Dateien: {', '.join(cask.app_names)}"
            )
        metadata = read_bundle_metadata(app_path)
        pkg_output_dir = output_dir / metadata.bundle_id
        return build_pkg(app_path, metadata, pkg_output_dir), metadata, cask

    if args.pkg_file:
        source = Path(args.pkg_file)
        metadata = metadata_from_args(args, source)
        return copy_pkg_for_upload(source, output_dir / metadata.bundle_id), metadata, None

    source = Path(args.dmg_file)
    metadata = metadata_from_args(args, source)
    pkg_path, resolved_metadata = first_payload_from_dmg(source, output_dir / metadata.bundle_id, metadata)
    return pkg_path, resolved_metadata, None


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    # Generate footprint report if requested
    if args.generate_footprint_report and args.cask:
        LOGGER.info("Generiere Footprint-Analyse für %s...", args.cask)
        try:
            # Import footprint analyzer
            script_dir = Path(__file__).parent
            footprint_script = script_dir / "analyze_app_footprint.py"

            if not footprint_script.exists():
                LOGGER.warning("Footprint-Analyseskript nicht gefunden: %s", footprint_script)
            else:
                # Run footprint analysis
                report_path = Path(args.output_dir) / f"{args.cask}_footprint_report.txt"
                result = run(
                    [
                        "python3",
                        str(footprint_script),
                        "--cask", args.cask,
                        "--output", str(report_path),
                    ],
                    check=False,
                )
                if result.returncode == 0:
                    LOGGER.info("Footprint-Bericht erstellt: %s", report_path)
                else:
                    LOGGER.warning("Footprint-Analyse fehlgeschlagen: %s", result.stderr)
        except Exception as exc:
            LOGGER.warning("Footprint-Analyse konnte nicht erstellt werden: %s", exc)
    elif args.generate_footprint_report:
        LOGGER.info("Footprint-Analyse wird nur für Homebrew Casks unterstützt; überspringe Custom Package.")

    pkg_path, metadata, cask = resolve_package_source(args)
    check_pkg_signature(pkg_path)
    LOGGER.info("Verwende erzeugtes PKG direkt für Intune Upload (kein Wrapping)")
    intune_pkg_path = pkg_path

    icon_payload = load_icon_payload(Path(args.icon_file)) if args.icon_file else None

    if args.skip_upload:
        LOGGER.info("--skip-upload gesetzt, beende ohne Intune Upload")
        return 0

    config = load_intune_config()
    client = IntuneClient(config)
    display_name = normalize_display_name(args.display_name or metadata.bundle_name, metadata.version)
    description = args.description or (cask.desc if cask else None) or metadata.bundle_name
    publisher = args.publisher or ("Homebrew" if cask else "Modern Dev Mgmt")

    # Build params dict, only including icon if it exists
    app_params = {
        "displayName": display_name,
        "description": description,
        "publisher": publisher,
    }
    if icon_payload:
        app_params["largeIcon"] = icon_payload
    pre_install_script = normalize_base64(args.pre_install_script_b64)
    if pre_install_script:
        app_params["preInstallScript"] = pre_install_script
    post_install_script = normalize_base64(args.post_install_script_b64)
    if post_install_script:
        app_params["postInstallScript"] = post_install_script

    app_id = client.create_mac_app(
        metadata,
        app_params,
        file_name=intune_pkg_path.name,
    )

    try:
        encrypted_pkg_path, encryption_info, plain_file_size, encrypted_file_size = encrypt_package_for_intune(
            intune_pkg_path
        )
    except Exception as exc:
        LOGGER.error("Verschlüsselung fehlgeschlagen: %s", exc)
        raise

    if not encryption_info:
        raise RuntimeError("Keine Verschlüsselungsinformationen verfügbar")

    file_name = intune_pkg_path.name
    app_details = client._graph_request("GET", f"/deviceAppManagement/mobileApps/{app_id}")
    LOGGER.info("App Details Keys: %s", list(app_details.keys()))
    content_version = client.create_content_version(app_id)
    LOGGER.info("Content Version erstellt: %s", content_version)
    client._graph_request(
        "GET",
        f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions",
    )
    file_info = client.add_content_file(app_id, content_version, file_name, plain_file_size, encrypted_file_size)
    file_id = file_info.get("id")
    if not file_id:
        raise RuntimeError("Konnte Datei-ID für Upload nicht auslesen")
    LOGGER.info("Dateiinfo: %s", file_info)
    file_uri = (
        f"/deviceAppManagement/mobileApps/{app_id}/microsoft.graph.macOSPkgApp/contentVersions/{content_version}/files/{file_id}"
    )

    upload_url = file_info.get("azureStorageUri")
    if not upload_url:
        # Wait for Azure Storage URI to be generated
        LOGGER.info("Azure Storage URI noch nicht verfügbar, warte auf Generierung...")
        file_info = wait_for_file_processing(client, file_uri, "AzureStorageUriRequest", attempts=60, wait_seconds=5)
        upload_url = file_info.get("azureStorageUri")

    if not upload_url:
        raise RuntimeError(
            "Azure Storage URI konnte nicht ermittelt werden. "
            "Bitte prüfen Sie die Intune-Konfiguration und versuchen Sie es erneut."
        )

    try:
        upload_file(upload_url, encrypted_pkg_path)
        client.commit_file(
            app_id,
            content_version,
            file_id,
            encryption_info["fileDigest"],
            encryption_info=encryption_info,
        )
        wait_for_file_processing(client, file_uri, "CommitFile")
        client.commit_app_content(app_id, content_version, file_name, file_id, plain_file_size)
    finally:
        if encrypted_pkg_path and encrypted_pkg_path.exists():
            encrypted_pkg_path.unlink()

    LOGGER.info("Deployment Paket erfolgreich nach Intune hochgeladen (App-ID: %s)", app_id)
    github_output = os.environ.get("GITHUB_OUTPUT")
    if github_output:
        with open(github_output, "a", encoding="utf-8") as handle:
            handle.write(f"app_id={app_id}\n")
            handle.write(f"app_name={display_name}\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Exception as exc:
        LOGGER.error("%s", exc)
        sys.exit(1)
