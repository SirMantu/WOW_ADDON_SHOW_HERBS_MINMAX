"""Builds ShowHerbsMinMax.zip for manual uploads (e.g. CurseForge).

Usage: python release.py
"""
import shutil
import zipfile
from pathlib import Path

NAME = "ShowHerbsMinMax"
FILES = ["ShowHerbsMinMax.lua", "ShowHerbsMinMax.toc", "README.md", "CHANGELOG.md", "LICENSE"]

root = Path(__file__).resolve().parent
folder = root / NAME
archive = root / f"{NAME}.zip"

try:
    # create the staging folder if it does not exist
    folder.mkdir(exist_ok=True)

    for f in FILES:
        shutil.copy2(root / f, folder / f)

    if archive.exists():
        archive.unlink()

    with zipfile.ZipFile(archive, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(folder.iterdir()):
            if f.is_file():
                z.write(f, f"{NAME}/{f.name}")

    print(f"Created {archive}")
finally:
    # clean up the staging folder
    if folder.exists():
        shutil.rmtree(folder)
