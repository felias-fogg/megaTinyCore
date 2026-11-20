#!/usr/bin/env python3
"""
Check that the avrdude a user gets can actually be used with this core: that it
reads the configuration file the core passes, and that it knows every programmer
and every part the core asks for. A core is usually tried out with one board and
one way of uploading, so a configuration avrdude cannot parse, or a programmer
renamed in a new avrdude version, can go unnoticed for several releases.

    python3 extras/check_avrdude.py --root megaavr --avrdude ~/Library/Arduino15/packages/megaTinyCore/tools/avrdude/8.3
    python3 extras/check_avrdude.py --root megaavr --index package_..._index.json --version 8.3

With --avrdude, the avrdude in that folder is used (the folder that holds bin/ and
etc/, as the board manager installs it). With --index and --version, the tool is
downloaded from the URL the board manager index gives for this computer (or for
--host), checked against its checksum and unpacked into a temporary folder: that
is exactly the avrdude a user of that index gets.

No hardware is needed and none is touched. Every programmer is called with -n
(write nothing) and a port that matches no device, so avrdude gets as far as
looking for the device and stops there; anything it says before that, about the
configuration, an unknown programmer or missing USB support, is a problem. Parts
are checked against the list avrdude prints with -p ?, because avrdude only looks
at the part after it has found the programmer.
"""

import argparse
import hashlib
import json
import os
import platform as host_platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_core import properties, board_ids  # pylint: disable=wrong-import-position

# A port no device can match: a USB programmer looks for this serial number and
# finds nothing, a serial one tries to open a file of that name and cannot.
NO_DEVICE = "usb:ffff0000ffff"

# What avrdude says when it got as far as looking for the device.
REACHED_THE_PORT = re.compile(r"no device found|cannot open port|unable to open port|"
                              r"no USB HID devices found|could not find USB device",
                              re.IGNORECASE)

PROBLEMS: list = []


def problem(text: str) -> None:
    """Record something that keeps users from uploading."""
    PROBLEMS.append(text)


def expand(template: str, values: dict, depth: int = 0) -> list:
    """
    Every string a template can become, where values maps a property to the
    values it takes on this board (from the board itself or any menu option).
    """
    match = re.search(r"\{([^{}]+)\}", template)
    if not match or depth > 10:
        return [template]
    results = []
    for value in sorted(values.get(match.group(1), {match.group(0)})):
        replaced = template[:match.start()] + value + template[match.end():]
        results.extend(expand(replaced, values, depth + 1))
    return results


def board_values(boards: dict, board: str) -> dict:
    """property -> set of values it takes on this board, directly or through a menu"""
    values: dict = {}
    for key, value in boards.items():
        if key.startswith(f"{board}.menu."):
            prop = key.split(".", 4)[4] if key.count(".") >= 4 else None
        elif key.startswith(f"{board}."):
            prop = key[len(board) + 1:]
        else:
            continue
        if prop:
            values.setdefault(prop, set()).add(value)
    return values


def parts_asked_for(boards: dict, platform: dict) -> dict:
    """part as passed with -p -> the boards that ask for it"""
    template = re.search(r"-p\s*(\{[^}]+\}|\S+)", platform.get("tools.avrdude.program.pattern", ""))
    template_text = template.group(1) if template else "{build.mcu}"
    wanted: dict = {}
    for board in board_ids(boards):
        values = board_values(boards, board)
        for part in expand(template_text, values):
            if "{" not in part:
                wanted.setdefault(part, set()).add(board)
    return wanted


def programmers_asked_for(boards: dict, programmers: dict) -> dict:
    """programmer as passed with -c -> where it comes from (programmer or board entry)"""
    wanted: dict = {}
    names = {k[:-len(".name")] for k in programmers if k.endswith(".name") and k.count(".") == 1}
    for name in sorted(names):
        if programmers.get(f"{name}.program.tool") != "avrdude":
            continue
        for key in (f"{name}.program.protocol", f"{name}.protocol"):
            if key in programmers:
                wanted.setdefault(programmers[key], set()).add(f"programmer {name}")
    for key, protocol in boards.items():
        if not key.endswith(".upload.protocol"):
            continue
        board = key.split(".")[0]
        scope = key[:-len("upload.protocol")]
        tool = boards.get(f"{scope}upload.tool") or boards.get(f"{board}.upload.tool")
        if tool == "avrdude":
            wanted.setdefault(protocol, set()).add(f"board {board}")
    return wanted


def resolve_tool_paths(platform: dict, root: str, tool: str) -> tuple:
    """The avrdude binary and the configuration file, as the IDE would build them."""
    known = {"runtime.platform.path": root, "runtime.tools.avrdude.path": tool}
    local = {k[len("tools.avrdude."):]: v for k, v in platform.items()
             if k.startswith("tools.avrdude.")}

    def resolve(text: str, depth: int = 0) -> str:
        if depth > 10:
            return text
        return re.sub(r"\{([^{}]+)\}",
                      lambda m: resolve(local[m.group(1)], depth + 1) if m.group(1) in local
                      else known.get(m.group(1), m.group(0)), text)

    command = resolve(local.get("cmd.path", "{path}/bin/avrdude"))
    if os.name == "nt" and not command.endswith(".exe"):
        command += ".exe"
    config = resolve(local.get("config.path", "{path}/etc/avrdude.conf"))
    return command, config


def known_parts(command: str, config: str) -> set:
    """The names avrdude accepts with -p: the id and the names in the description."""
    out = subprocess.run([command, "-C", config, "-p", "?"], capture_output=True,
                         text=True, errors="replace", check=False)
    text = "\n".join(line for line in (out.stdout + out.stderr).splitlines()
                     if "fails to specify prog_modes" not in line)
    if "Valid parts are" not in text:
        problem("avrdude does not list its parts with this configuration:\n      "
                + "\n      ".join(text.strip().splitlines()[:5]))
        return set()
    names = set()
    for line in text.splitlines():
        match = re.match(r"\s+(\S+)\s+=\s+(.*?)(\s+\(.*\))?$", line)
        if match:
            names.add(match.group(1).lower())
            names.update(n.strip().lower() for n in match.group(2).split(","))
    return names


def try_programmer(command: str, config: str, programmer: str, part: str) -> str:
    """'' if avrdude got as far as looking for the device, else what it said."""
    out = subprocess.run([command, "-C", config, "-n", "-c", programmer, "-p", part,
                          "-P", NO_DEVICE], capture_output=True, text=True,
                         errors="replace", check=False, timeout=60)
    text = "\n".join(line for line in (out.stdout + out.stderr).splitlines()
                     if line.strip() and "fails to specify prog_modes" not in line)
    if REACHED_THE_PORT.search(text):
        return ""
    return text or f"no output, exit code {out.returncode}"


def host_name() -> str:
    """The host string of the board manager index for this computer."""
    machine = host_platform.machine().lower()
    if sys.platform == "darwin":
        return "x86_64-apple-darwin12"            # the arm64 Macs run it through Rosetta
    if sys.platform.startswith("win"):
        return "i686-mingw32"
    return {"x86_64": "x86_64-linux-gnu", "amd64": "x86_64-linux-gnu",
            "aarch64": "aarch64-linux-gnu", "arm64": "aarch64-linux-gnu",
            "armv7l": "arm-linux-gnueabihf"}.get(machine, "i686-linux-gnu")


def fetch_tool(index_file: str, version: str, packager: str, host: str, into: str) -> str:
    """Download avrdude as the index offers it, check it, unpack it; return its folder."""
    with open(index_file, encoding="utf-8") as src:
        index = json.load(src)
    tools = [t for p in index["packages"] if not packager or p["name"] == packager
             for t in p.get("tools", []) if t["name"] == "avrdude" and t["version"] == version]
    if not tools:
        problem(f"the index has no avrdude {version}"
                + (f" from packager {packager}" if packager else ""))
        return ""
    systems = [s for s in tools[0]["systems"] if s["host"] == host]
    if not systems:
        problem(f"avrdude {version} in the index has nothing for {host}")
        return ""
    system = systems[0]
    archive = os.path.join(into, system["archiveFileName"])
    print(f"  downloading {system['url']}")
    with urllib.request.urlopen(system["url"], timeout=120) as response, \
         open(archive, "wb") as dst:
        shutil.copyfileobj(response, dst)
    algorithm, _, expected = system["checksum"].partition(":")
    with open(archive, "rb") as src:
        digest = hashlib.new(algorithm.replace("-", "").lower(), src.read()).hexdigest()
    if digest != expected.lower():
        problem(f"{system['archiveFileName']} does not match the checksum in the index")
        return ""
    unpacked = os.path.join(into, "unpacked")
    if archive.endswith(".zip"):
        with zipfile.ZipFile(archive) as packed:
            packed.extractall(unpacked)
    else:
        with tarfile.open(archive) as packed:
            packed.extractall(unpacked, filter="data")
    for folder, _, files in os.walk(unpacked):
        if os.path.basename(folder) == "bin" and ("avrdude" in files or "avrdude.exe" in files):
            tool = os.path.dirname(folder)
            # zip does not keep the execute bit
            binary = os.path.join(folder, "avrdude")
            if os.path.exists(binary):
                os.chmod(binary, 0o755)
            return tool
    problem(f"{system['archiveFileName']} has no bin/avrdude")
    return ""


def check(root: str, tool: str) -> None:
    """Run the checks against the avrdude in the folder tool."""
    boards = properties(os.path.join(root, "boards.txt"))
    platform = properties(os.path.join(root, "platform.txt"))
    programmers = properties(os.path.join(root, "programmers.txt"))
    command, config = resolve_tool_paths(platform, os.path.abspath(root), tool)
    print(f"  avrdude:       {command}")
    print(f"  configuration: {config}")
    for path, what in ((command, "avrdude"), (config, "the configuration file")):
        if not os.path.isfile(path):
            problem(f"{what} is not where platform.txt says: {path}")
    if PROBLEMS:
        return

    parts = parts_asked_for(boards, platform)
    names = known_parts(command, config)
    if names:
        for part, users in sorted(parts.items()):
            if part.lower() not in names:
                problem(f"avrdude does not know part '{part}' (boards {', '.join(sorted(users))})")
        print(f"  {len(parts)} part(s) checked")
    if PROBLEMS:
        return

    asked = programmers_asked_for(boards, programmers)
    a_part = sorted(parts)[0]
    for programmer, users in sorted(asked.items()):
        said = try_programmer(command, config, programmer, a_part)
        if said:
            problem(f"programmer '{programmer}' ({', '.join(sorted(users))}) does not get "
                    "as far as the port:\n      " + "\n      ".join(said.splitlines()[:4]))
    print(f"  {len(asked)} programmer(s) checked")

    # The classification has to hold for this avrdude: a programmer that cannot
    # exist must be reported, or every 'passed' above means nothing.
    if not try_programmer(command, config, "no-such-programmer", a_part):
        problem("avrdude did not complain about a programmer that does not exist, so "
                "this check cannot tell a good programmer from a bad one")


def main() -> int:
    """Check one avrdude against the core and report."""
    parser = argparse.ArgumentParser(description="check that avrdude can upload with this core")
    parser.add_argument("--root", help="the core's folder (default: the one above this)")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--avrdude", metavar="DIR", help="the avrdude tool folder (with bin/ and etc/)")
    source.add_argument("--index", metavar="FILE", help="board manager index to take avrdude from")
    parser.add_argument("--version", help="the avrdude version in the index")
    parser.add_argument("--packager", help="the package in the index (default: any)")
    parser.add_argument("--host", default=host_name(), help="the host in the index "
                        f"(default here: {host_name()})")
    args = parser.parse_args()
    if args.index and not args.version:
        parser.error("--index needs --version")

    root = args.root or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    print(f"checking avrdude for {root}")
    with tempfile.TemporaryDirectory() as scratch:
        tool = args.avrdude
        if args.index:
            tool = fetch_tool(args.index, args.version, args.packager, args.host, scratch)
        if tool:
            check(root, os.path.abspath(os.path.expanduser(tool)))

    for text in PROBLEMS:
        print(f"  PROBLEM: {text}")
    if PROBLEMS:
        print(f"{len(PROBLEMS)} problem(s)")
        return 1
    print("no problems found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
