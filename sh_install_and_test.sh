#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCHIVE=${SH_ARCHIVE:-$SCRIPT_DIR/sh_solution.tar.gz}

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
    echo 'ERROR: git is required to clone the xv6 sh branch.' >&2
    exit 1
  }
  REPO=$HOME/xv6-riscv
  if [ ! -d "$REPO/.git" ]; then
    echo '[0/3] Cloning the xv6 sh branch...'
    git clone --branch sh https://github.com/matlapo/xv6-riscv.git "$REPO"
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

TMP_DIR=$(mktemp -d /tmp/xv6-sh-solution.XXXXXX)
BUILD_LOG=/tmp/xv6-sh-build.log
TEST_LOG=/tmp/xv6-sh-test.log
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

echo '[1/3] Installing simple shell...'
for source in Makefile user/nsh.c; do
  tar -tzf "$ARCHIVE" | grep -Fxq "$source" || {
    echo "ERROR: archive does not contain $source" >&2
    exit 1
  }
done
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

cd "$REPO"
if [ "${SH_SKIP_CHECKOUT:-0}" != 1 ] && [ -d .git ]; then
  current_ref=$(git symbolic-ref --quiet HEAD 2>/dev/null || true)
  if [ "$current_ref" != refs/heads/sh ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      GIT_AUTHOR_NAME='Xv6 lab backup' \
      GIT_AUTHOR_EMAIL='xv6-lab-backup@localhost' \
      GIT_COMMITTER_NAME='Xv6 lab backup' \
      GIT_COMMITTER_EMAIL='xv6-lab-backup@localhost' \
        git stash save 'Saved automatically before sh lab' >/dev/null
      echo 'Existing tracked changes saved in git stash.'
    fi
    if git show-ref --verify --quiet refs/heads/sh; then
      git checkout sh >/dev/null
    else
      git checkout -b sh origin/sh >/dev/null
    fi
  fi
fi

cp "$TMP_DIR/Makefile" Makefile
cp "$TMP_DIR/user/nsh.c" user/nsh.c
git diff --check >/dev/null 2>&1 || {
  echo 'ERROR: installed source failed git diff --check.' >&2
  exit 1
}

BASE_CFLAGS='-Wall -Werror -O -fno-omit-frame-pointer -ggdb -MD -mcmodel=medany -ffreestanding -fno-common -nostdlib -mno-relax -I. -fno-stack-protector -fno-pie -no-pie'
if "${TOOLPREFIX}gcc" -Wno-error=infinite-recursion -E -x c /dev/null >/dev/null 2>&1; then
  CFLAGS="$BASE_CFLAGS -Wno-error=infinite-recursion"
else
  CFLAGS=$BASE_CFLAGS
fi

build_failed() {
  echo 'ERROR: xv6 build failed. Last output:' >&2
  tail -80 "$BUILD_LOG" >&2 || true
  exit 1
}

echo '[2/3] Building xv6 and testsh...'
make TOOLPREFIX="$TOOLPREFIX" CFLAGS="$CFLAGS" clean >"$BUILD_LOG" 2>&1 || build_failed
make TOOLPREFIX="$TOOLPREFIX" CFLAGS="$CFLAGS" -j4 kernel/kernel fs.img >>"$BUILD_LOG" 2>&1 || build_failed

echo '[3/3] Running testsh in QEMU...'
XV6_REPO=$REPO XV6_QEMU=$QEMU XV6_TEST_LOG=$TEST_LOG "$PYTHON" <<'PY'
import os
import selectors
import subprocess
import sys
import time

repo = os.environ["XV6_REPO"]
qemu = os.environ["XV6_QEMU"]
log_path = os.environ["XV6_TEST_LOG"]
command = [
    qemu, "-machine", "virt", "-cpu", "rv64,pmp=false", "-bios", "none",
    "-kernel", "kernel/kernel", "-m", "128M", "-smp", "3", "-nographic",
    "-drive", "file=fs.img,if=none,format=raw,id=x0",
    "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
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
    process.stdin.write(b"testsh nsh\n")
    process.stdin.flush()
    read_until(b"$ ", 180, offset)
    result = bytes(output[offset:])
    if b"passed all tests" not in result:
        raise RuntimeError("testsh did not report that all tests passed")
except Exception as exc:
    print("ERROR: %s" % exc, file=sys.stderr)
    lines = output.decode("utf-8", "replace").splitlines()
    print("Last xv6 output:", file=sys.stderr)
    print("\n".join(lines[-100:]), file=sys.stderr)
    sys.exit(1)
finally:
    selector.close()
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()

print("=" * 54)
print("SHELL LAB: ALL TESTS PASSED")
print("testsh: simple commands, redirection, pipes, fd reuse: OK")
print("Ready for Submit Evaluation")
print("=" * 54)
PY
