#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCHIVE=${NET_ARCHIVE:-$SCRIPT_DIR/net_solution.tar.gz}

find_repo() {
  for candidate in "${XV6_REPO:-}" "$HOME/xv6-riscv" /root/xv6-riscv "$PWD/xv6-riscv"; do
    if [ -n "$candidate" ] && [ -f "$candidate/Makefile" ] && [ -d "$candidate/kernel" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

find_toolprefix() {
  for prefix in riscv64-unknown-elf- riscv64-linux-gnu- riscv64-elf-; do
    if command -v "${prefix}gcc" >/dev/null 2>&1; then
      printf '%s' "$prefix"
      return 0
    fi
  done
  return 1
}

REPO=$(find_repo || true)
TOOLPREFIX=${TOOLPREFIX:-$(find_toolprefix || true)}
QEMU=${QEMU:-$(command -v qemu-system-riscv64 || true)}
PYTHON=${PYTHON:-$(command -v python3 || true)}

if [ -z "$REPO" ]; then
  command -v git >/dev/null 2>&1 || {
    echo 'ERROR: git is required to clone the xv6 net branch.' >&2
    exit 1
  }
  REPO=$HOME/xv6-riscv
  if [ ! -d "$REPO/.git" ]; then
    echo '[0/3] Cloning the xv6 net branch...'
    git clone --branch net https://github.com/matlapo/xv6-riscv.git "$REPO"
  fi
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "ERROR: missing $ARCHIVE" >&2
  exit 1
fi
if [ -z "$TOOLPREFIX" ] || [ -z "$QEMU" ] || [ -z "$PYTHON" ]; then
  echo 'ERROR: RISC-V GCC, QEMU, or python3 was not found.' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d /tmp/xv6-net-solution.XXXXXX)
BUILD_LOG=/tmp/xv6-net-build.log
TEST_LOG=/tmp/xv6-net-test.log
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

echo '[1/3] Installing network solution...'
for source in kernel/defs.h kernel/e1000.c kernel/file.c kernel/sysnet.c user/user.h; do
  tar -tzf "$ARCHIVE" | grep -Fxq "$source" || {
    echo "ERROR: archive does not contain $source" >&2
    exit 1
  }
done
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

cd "$REPO"
if [ "${NET_SKIP_CHECKOUT:-0}" != 1 ] && [ -d .git ]; then
  current_ref=$(git symbolic-ref --quiet HEAD 2>/dev/null || true)
  if [ "$current_ref" != refs/heads/net ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      GIT_AUTHOR_NAME='Xv6 lab backup' \
      GIT_AUTHOR_EMAIL='xv6-lab-backup@localhost' \
      GIT_COMMITTER_NAME='Xv6 lab backup' \
      GIT_COMMITTER_EMAIL='xv6-lab-backup@localhost' \
        git stash save 'Saved automatically before net lab' >/dev/null
      echo 'Existing tracked changes saved in git stash.'
    fi
    if git show-ref --verify --quiet refs/heads/net; then
      git checkout net >/dev/null
    else
      git checkout -b net origin/net >/dev/null
    fi
  fi
fi

for source in kernel/defs.h kernel/e1000.c kernel/file.c kernel/sysnet.c user/user.h; do
  cp "$TMP_DIR/$source" "$source"
done
git diff --check >/dev/null 2>&1 || {
  echo 'ERROR: installed source failed git diff --check.' >&2
  exit 1
}

SERVERPORT=$(($(id -u) % 5000 + 25099))
FWDPORT=$(($(id -u) % 5000 + 25999))
BASE_CFLAGS='-Wall -Werror -O -fno-omit-frame-pointer -ggdb -MD -mcmodel=medany -ffreestanding -fno-common -nostdlib -mno-relax -I. -fno-stack-protector -fno-pie -no-pie'
if "${TOOLPREFIX}gcc" -Wno-error=infinite-recursion -E -x c /dev/null >/dev/null 2>&1; then
  CFLAGS="$BASE_CFLAGS -Wno-error=infinite-recursion"
else
  CFLAGS=$BASE_CFLAGS
fi
CFLAGS="$CFLAGS -DNET_TESTS_PORT=$SERVERPORT"

build_failed() {
  echo 'ERROR: xv6 build failed. Last output:' >&2
  tail -80 "$BUILD_LOG" >&2 || true
  exit 1
}

echo '[2/3] Building xv6 network tests...'
make TOOLPREFIX="$TOOLPREFIX" SERVERPORT="$SERVERPORT" CFLAGS="$CFLAGS" clean >"$BUILD_LOG" 2>&1 || build_failed
make TOOLPREFIX="$TOOLPREFIX" SERVERPORT="$SERVERPORT" CFLAGS="$CFLAGS" -j4 kernel/kernel fs.img >>"$BUILD_LOG" 2>&1 || build_failed

echo '[3/3] Running UDP socket tests in QEMU...'
XV6_REPO=$REPO XV6_QEMU=$QEMU XV6_TEST_LOG=$TEST_LOG NET_TESTS_PORT=$SERVERPORT QEMU_FWDPORT=$FWDPORT \
  "$PYTHON" <<'PY'
import os
import re
import selectors
import socket
import subprocess
import sys
import threading
import time

repo = os.environ["XV6_REPO"]
qemu = os.environ["XV6_QEMU"]
log_path = os.environ["XV6_TEST_LOG"]
port = int(os.environ["NET_TESTS_PORT"])
fwdport = int(os.environ["QEMU_FWDPORT"])

server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", port))
server.settimeout(0.5)
stopping = threading.Event()

def echo_loop():
    while not stopping.is_set():
        try:
            data, peer = server.recvfrom(4096)
            server.sendto(data, peer)
        except socket.timeout:
            continue

thread = threading.Thread(target=echo_loop, daemon=True)
thread.start()
command = [
    qemu, "-machine", "virt", "-cpu", "rv64,pmp=false", "-bios", "none", "-kernel", "kernel/kernel",
    "-m", "128M", "-smp", "1", "-nographic",
    "-drive", "file=fs.img,if=none,format=raw,id=x0",
    "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
    "-netdev", "user,id=net0,hostfwd=udp::%d-:2000" % fwdport,
    "-object", "filter-dump,id=net0,netdev=net0,file=packets.pcap",
    "-device", "e1000,netdev=net0,bus=pcie.0",
]
process = subprocess.Popen(
    command, cwd=repo, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT, bufsize=0,
)
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
output = bytearray()

def read_until(marker, timeout, start=0):
    deadline = time.monotonic() + timeout
    while marker not in output[start:]:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out waiting for xv6 output")
        if process.poll() is not None:
            raise RuntimeError("QEMU exited with status %s" % process.returncode)
        if not selector.select(min(1.0, remaining)):
            continue
        chunk = os.read(process.stdout.fileno(), 4096)
        if not chunk:
            raise RuntimeError("QEMU closed its output")
        output.extend(chunk)
        with open(log_path, "ab") as log:
            log.write(chunk)

try:
    open(log_path, "wb").close()
    read_until(b"$ ", 60)
    offset = len(output)
    process.stdin.write(b"nettests\n")
    process.stdin.flush()
    read_until(b"$ ", 300, offset)
    result = bytes(output[offset:])
    required = (
        b"testing one ping: OK" in result and
        b"testing single-process pings: OK" in result and
        b"testing multi-process pings: OK" in result
    )
    if b"all tests passed." in result and b"DNS OK" in result and required:
        print("=" * 54)
        print("NETWORK LAB: ALL TESTS PASSED")
        print("e1000 transmit/receive: OK")
        print("UDP socket single/multi-process tests: OK")
        print("DNS test: OK")
        print("Ready for Submit Evaluation")
        print("=" * 54)
    elif required and b"wrong ip address" in result:
        match = re.search(rb"DNS arecord for [^\r\n]+ is ([0-9.]+)", result)
        address = match.group(1).decode("ascii") if match else "unknown"
        print("=" * 54)
        print("NETWORK SOCKET TESTS: PASSED")
        print("e1000 transmit/receive: OK")
        print("UDP socket single/multi-process tests: OK")
        print("DNS responded with %s, but this lab's sample pins an older A record." % address)
        print("Check the course evaluator's DNS environment before submission.")
        print("=" * 54)
    else:
        raise RuntimeError("nettests did not report success")
except Exception as exc:
    print("ERROR: %s" % exc, file=sys.stderr)
    lines = output.decode("utf-8", "replace").splitlines()
    print("Last xv6 output:", file=sys.stderr)
    print("\n".join(lines[-100:]), file=sys.stderr)
    sys.exit(1)
finally:
    selector.close()
    stopping.set()
    server.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

PY
