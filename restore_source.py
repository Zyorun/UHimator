"""Reassemble the three browser-uploadable parts and extract their verified source."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
import stat
import zipfile


def restore(repository, destination):
    repository, destination = Path(repository).resolve(), Path(destination).resolve()
    manifest = json.loads((repository / "source-payload.json").read_text(encoding="utf-8"))
    if manifest.get("format") != 1 or not 1 <= len(manifest["parts"]) <= 10:
        raise ValueError("Unsupported or malformed payload manifest")
    source_root = manifest["source_root"]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", source_root):
        raise ValueError("Invalid source root")
    # Fail instead of overwriting a previous working tree or another directory.
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination / "source.zip"
    full_hash = hashlib.sha256()
    total = 0
    try:
        with archive.open("xb") as output:
            for index, part in enumerate(manifest["parts"], 1):
                if part["name"] != f"mineimator-source.zip.{index:03}":
                    raise ValueError("Invalid part name/order")
                path = repository / part["name"]
                if path.is_symlink() or not path.is_file() or path.stat().st_size != part["bytes"]:
                    raise ValueError(f"Missing or incomplete upload: {part['name']}")
                digest = hashlib.sha256()
                with path.open("rb") as source:
                    while block := source.read(1024 * 1024):
                        total += len(block)
                        digest.update(block)
                        full_hash.update(block)
                        output.write(block)
                if digest.hexdigest() != part["sha256"]:
                    raise ValueError(f"Corrupt upload: {part['name']}")
        if total != manifest["archive_bytes"] or full_hash.hexdigest() != manifest["archive_sha256"]:
            raise ValueError("Reassembled source hash/size does not match")
        with zipfile.ZipFile(archive) as source:
            if sum(info.file_size for info in source.infolist()) > 600 * 1024 * 1024:
                raise ValueError("Unexpectedly large source archive")
            for info in source.infolist():
                name = PurePosixPath(info.filename)
                if (name.is_absolute() or ".." in name.parts or "\\" in info.filename or ":" in info.filename
                        or not name.parts or name.parts[0] != source_root
                        or stat.S_ISLNK(info.external_attr >> 16)):
                    raise ValueError(f"Unsafe archive entry: {info.filename}")
            source.extractall(destination)
        project = destination / source_root
        required = ["Scripts/Build-Windows.ps1", "Scripts/Generate-Cpp.ps1",
                    "Scripts/Prepare-WindowsDependencies.ps1", "GmProject/Mine-imator.yyp"]
        if any(not (project / entry).is_file() for entry in required):
            raise ValueError("Required build files are missing from the source")
        print(f"Verified {len(manifest['parts'])} parts ({total:,} bytes). Source: {project}")
        return project
    except Exception:
        archive.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", default=".")
    parser.add_argument("--destination", default="work")
    args = parser.parse_args()
    restore(args.repository, args.destination)
