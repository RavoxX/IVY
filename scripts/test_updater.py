#!/usr/bin/env python3
"""macOS updater integration checks using disposable, signed app copies.

Build Debug first. Pass a signed older app with --previous-app. Optionally pass
an older Debug build whose --settings-preview doesn't acknowledge startup with
--no-ack-app to exercise rollback. No installed app or user settings are changed.
"""
import argparse
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import subprocess
import tempfile
import time
import uuid


def version(app):
    with (app / "Contents/Info.plist").open("rb") as stream:
        return plistlib.load(stream)["CFBundleShortVersionString"]


def copy_app(source, destination):
    subprocess.run(["/usr/bin/ditto", str(source), str(destination)], check=True)


def test_app_pids(receipt):
    # The receipt argument is unique to this test instance; no other app matches.
    result = subprocess.run(["/usr/bin/pgrep", "-f", re.escape(str(receipt))], capture_output=True, text=True)
    return [int(value) for value in result.stdout.splitlines() if int(value) > 1 and int(value) != os.getpid()]


def stop_test_app(receipt):
    for pid in test_app_pids(receipt):
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


def scenario(debug, previous, source, kind):
    scratch = Path(subprocess.check_output(["/usr/bin/getconf", "DARWIN_USER_TEMP_DIR"], text=True).strip()) / "IVY"
    scratch.mkdir(exist_ok=True)
    folder = scratch / ("Update-" + str(uuid.uuid4()))
    folder.mkdir(mode=0o700)
    destination = Path(tempfile.mkdtemp(prefix="ivy-updater-test-"))
    target = destination / "IVY.app"
    staged = folder / "IVY.app"
    helper = folder / "Installer.app"
    parent = None
    installer = None
    try:
        copy_app(previous, target)
        copy_app(source, staged)
        copy_app(debug, helper)
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(helper)], check=True)
        if kind == "tampered":
            with (staged / "Contents/Resources/Assets.car").open("ab") as stream:
                stream.write(b"deliberately-invalid-test-resource")
        parent = subprocess.Popen(["/bin/sleep", "30"])
        installer = subprocess.Popen([
            str(helper / "Contents/MacOS/IVY"), "--ivy-install-update-test", str(parent.pid),
            str(target), str(staged), version(source), str(folder),
        ])
        deadline = time.monotonic() + 10
        ready = folder / "installer-ready"
        while installer.poll() is None and not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        if kind == "tampered":
            installer.wait(timeout=10)
            assert not ready.exists(), "Invalid update reached the handoff"
            assert parent.poll() is None, "Parent should stay alive after failed handoff"
            assert version(target) == version(previous), "Invalid update replaced the old app"
            assert (destination / "update-error.json").exists(), "Missing failure diagnostic"
        else:
            assert ready.read_text() == str(installer.pid), "Installer did not acknowledge readiness"
            assert parent.poll() is None, "Parent exited before installer was ready"
            parent.terminate()
            parent.wait(timeout=5)
            installer.wait(timeout=40)
            if kind == "rollback":
                assert version(target) == version(previous), "Unacknowledged launch wasn't rolled back"
                assert (destination / "update-error.json").exists(), "Missing rollback diagnostic"
                assert not test_app_pids(folder / "launch-receipt.json"), "Failed new app was left running during rollback"
            else:
                assert version(target) == version(source), "Update wasn't installed"
                assert not (destination / "update-error.json").exists(), "Installer reported an error"
                assert not list(destination.glob(".IVY-backup-*.app")), "Backup wasn't released after acknowledged startup"
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(target)], check=True)
        print("PASS:", kind, flush=True)
    except Exception:
        diagnostic = destination / "update-error.json"
        if diagnostic.exists():
            print("Installer diagnostic:", diagnostic.read_text(), flush=True)
        raise
    finally:
        stop_test_app(folder / "launch-receipt.json")
        if parent and parent.poll() is None:
            parent.terminate()
            parent.wait(timeout=5)
        if installer and installer.poll() is None:
            installer.terminate()
            installer.wait(timeout=5)
        shutil.rmtree(folder, ignore_errors=True)
        shutil.rmtree(destination, ignore_errors=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--debug-app", type=Path, required=True)
    parser.add_argument("--previous-app", type=Path, required=True)
    parser.add_argument("--no-ack-app", type=Path)
    args = parser.parse_args()
    for app in [args.debug_app, args.previous_app, args.no_ack_app]:
        if app:
            assert app.suffix == ".app" and (app / "Contents/MacOS/IVY").is_file(), "Expected an IVY app bundle"
    scenario(args.debug_app, args.previous_app, args.debug_app, "install")
    scenario(args.debug_app, args.previous_app, args.debug_app, "tampered")
    if args.no_ack_app:
        scenario(args.debug_app, args.previous_app, args.no_ack_app, "rollback")


if __name__ == "__main__":
    main()
