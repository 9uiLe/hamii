#!/usr/bin/env python3
"""Throwaway Simulator TCP session probe; builds no production Preview Host."""

import json
from pathlib import Path
import plistlib
import socket
import statistics
import subprocess
import time

ROOT = Path(__file__).resolve().parents[5]
SOURCE = Path(__file__).with_name("SocketHost.swift")
APP = ROOT / ".build/spikes/SocketProbe.app"
DEVICE_SET = ROOT / ".build/spikes/simulator-devices"
DEVICE_FILE = ROOT / ".build/spikes/socket-device-id"
BUNDLE = "app.hamii.transport-spike"
SDK = Path("/Applications/Xcode-26.5.0.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator26.5.sdk")


def command(*args, timeout=120, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=timeout)


def sim(*args, **kwargs):
    return command("xcrun", "simctl", "--set", str(DEVICE_SET), *args, **kwargs)


def build():
    APP.mkdir(parents=True, exist_ok=True)
    (APP / "Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BUNDLE, "CFBundleName": "SocketProbe", "CFBundleExecutable": "SocketProbe",
        "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "0.1", "CFBundleVersion": "1",
        "MinimumOSVersion": "17.0", "UILaunchScreen": {},
    }))
    command(str(Path.home() / ".swiftly/bin/swiftc"), "-sdk", str(SDK), "-target", "arm64-apple-ios17.0-simulator",
            "-parse-as-library", "-o", str(APP / "SocketProbe"), str(SOURCE))
    command("codesign", "--force", "--sign", "-", "--timestamp=none", str(APP))


def receive_line(stream):
    line = stream.readline()
    if not line:
        raise RuntimeError("Host closed connection")
    return json.loads(line)


def exchange(stream, message):
    start = time.perf_counter()
    stream.write(json.dumps(message, separators=(",", ":")).encode() + b"\n")
    stream.flush()
    ack = receive_line(stream)
    return ack, round((time.perf_counter() - start) * 1000, 3)


def main():
    build()
    DEVICE_SET.mkdir(parents=True, exist_ok=True)
    if DEVICE_FILE.exists():
        device = DEVICE_FILE.read_text().strip()
    else:
        device = sim("create", "hamii Socket Spike", "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
                     "com.apple.CoreSimulator.SimRuntime.iOS-26-5").stdout.strip()
        DEVICE_FILE.write_text(device + "\n")
    sim("boot", device, check=False)
    sim("bootstatus", device, "-b", timeout=240)
    sim("install", device, str(APP))
    with socket.socket() as server:
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 34123))
        server.listen(2)
        server.settimeout(15)
        sim("launch", device, BUNDLE)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(10)
            stream = connection.makefile("rwb", buffering=0)
            hello = receive_line(stream)
            if hello.get("kind") != "hello":
                raise RuntimeError(f"Unexpected hello: {hello}")
            timings = []
            ack, elapsed = exchange(stream, {"kind": "snapshot", "schema": 1, "id": 0, "surface": "A", "revision": 0, "text": "start"})
            if not ack["accepted"] or ack["revision"] != 0:
                raise RuntimeError(f"Snapshot rejected: {ack}")
            timings.append(elapsed)
            for revision in range(1, 101):
                ack, elapsed = exchange(stream, {"kind": "patch", "schema": 1, "id": revision,
                    "surface": "A", "baseRevision": revision - 1, "revision": revision, "text": str(revision)})
                if not ack["accepted"] or ack["revision"] != revision:
                    raise RuntimeError(f"Patch {revision} rejected: {ack}")
                timings.append(elapsed)
            gap, _ = exchange(stream, {"kind": "patch", "schema": 1, "id": 101, "surface": "A",
                "baseRevision": 100, "revision": 102, "text": "gap"})
            recovered, _ = exchange(stream, {"kind": "snapshot", "schema": 1, "id": 102,
                "surface": "A", "revision": 102, "text": "resynced"})
            mismatch, _ = exchange(stream, {"kind": "patch", "schema": 2, "id": 103,
                "surface": "A", "baseRevision": 102, "revision": 103})
            surface_b, _ = exchange(stream, {"kind": "snapshot", "schema": 1, "id": 104,
                "surface": "B", "revision": 7, "text": "B"})
            if gap["reason"] != "needsSnapshot" or not recovered["accepted"] or mismatch["reason"] != "schemaMismatch" or not surface_b["accepted"]:
                raise RuntimeError(f"Session handling failed: {gap} {recovered} {mismatch} {surface_b}")
            stream.close()
        reconnects = 0
        for _ in range(9):
            connection, _ = server.accept()
            with connection:
                connection.settimeout(10)
                stream = connection.makefile("rwb", buffering=0)
                hello = receive_line(stream)
                if hello.get("revisions", {}).get("A") != 102 or hello.get("revisions", {}).get("B") != 7:
                    raise RuntimeError(f"Reconnect lost revisions: {hello}")
                reconnects += 1
                stream.close()
        sim("terminate", device, BUNDLE)
        sim("launch", device, BUNDLE)
        connection, _ = server.accept()
        with connection:
            connection.settimeout(10)
            stream = connection.makefile("rwb", buffering=0)
            restart_hello = receive_line(stream)
            ack, _ = exchange(stream, {"kind": "snapshot", "schema": 1, "id": 200, "surface": "A", "revision": 102})
            if restart_hello.get("revisions") != {} or not ack["accepted"]:
                raise RuntimeError(f"Restart recovery failed: {restart_hello} {ack}")
            stream.close()
    result = {"device": device, "runtime": "iOS 26.5", "swift": command(str(Path.home() / ".swiftly/bin/swift"), "--version").stdout.splitlines()[0],
              "initialConnection": True, "reconnects": reconnects, "restartRecovered": True,
              "patchCount": 100, "ackP50Ms": round(statistics.median(timings), 3),
              "ackP95Ms": sorted(timings)[int(len(timings) * 0.95)], "ackP99Ms": sorted(timings)[int(len(timings) * 0.99)],
              "gapRejected": True, "snapshotRecovered": True, "schemaMismatchRejected": True,
              "secondSurfaceRouted": True}
    (SOURCE.parent / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
