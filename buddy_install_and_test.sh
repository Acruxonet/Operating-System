#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCHIVE=${BUDDY_ARCHIVE:-$SCRIPT_DIR/buddy_solution.tar.gz}

find_repo() {
  for candidate in \
    "${XV6_REPO:-}" \
    "$HOME/xv6-riscv" \
    "/root/xv6-riscv" \
    "$PWD/xv6-riscv"
  do
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

if [ ! -f "$ARCHIVE" ]; then
  echo "ERROR: missing $ARCHIVE" >&2
  exit 1
fi
if [ -z "$REPO" ]; then
  echo "ERROR: cannot find xv6-riscv. Set XV6_REPO=/path/to/xv6-riscv." >&2
  exit 1
fi
if [ -z "$TOOLPREFIX" ]; then
  echo "ERROR: RISC-V GCC toolchain was not found." >&2
  exit 1
fi
if [ -z "$QEMU" ]; then
  echo "ERROR: qemu-system-riscv64 was not found." >&2
  exit 1
fi
if [ -z "$PYTHON" ]; then
  echo "ERROR: python3 was not found." >&2
  exit 1
fi

TMP_DIR=$(mktemp -d /tmp/buddy-solution.XXXXXX)
BUILD_LOG=/tmp/xv6-buddy-build.log
TEST_LOG=/tmp/xv6-buddy-test.log
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

echo '[1/4] Installing buddy solution...'
tar -tzf "$ARCHIVE" | grep -Eq '^kernel/buddy\.c$' || {
  echo 'ERROR: archive does not contain kernel/buddy.c' >&2
  exit 1
}
tar -tzf "$ARCHIVE" | grep -Eq '^kernel/file\.c$' || {
  echo 'ERROR: archive does not contain kernel/file.c' >&2
  exit 1
}
tar -tzf "$ARCHIVE" | grep -Eq '^kernel/kalloc\.c$' || {
  echo 'ERROR: archive does not contain kernel/kalloc.c' >&2
  exit 1
}
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

cd "$REPO"
if [ "${BUDDY_SKIP_CHECKOUT:-0}" != 1 ] && [ -d .git ]; then
  current_branch=$(git branch --show-current)
  if [ "$current_branch" != lazy ]; then
    git diff -- kernel/buddy.c kernel/file.c kernel/kalloc.c > /tmp/xv6-buddy-preinstall.patch || true
    git checkout -- kernel/buddy.c kernel/file.c kernel/kalloc.c
  fi
  git checkout lazy >/dev/null 2>&1 || {
    echo 'ERROR: cannot switch to the lazy branch. Commit or stash existing changes first.' >&2
    exit 1
  }
fi

cp "$TMP_DIR/kernel/buddy.c" kernel/buddy.c
cp "$TMP_DIR/kernel/file.c" kernel/file.c
cp "$TMP_DIR/kernel/kalloc.c" kernel/kalloc.c
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

echo '[2/4] Building xv6...'
make TOOLPREFIX="$TOOLPREFIX" CFLAGS="$CFLAGS" clean >"$BUILD_LOG" 2>&1 || build_failed
make TOOLPREFIX="$TOOLPREFIX" CFLAGS="$CFLAGS" -j4 kernel/kernel fs.img >>"$BUILD_LOG" 2>&1 || build_failed

echo '[3/4] Running alloctest...'
echo '[4/4] Running usertests...'

XV6_REPO=$REPO XV6_QEMU=$QEMU XV6_TEST_LOG=$TEST_LOG "$PYTHON" <<'PY'
import os
import selectors
import subprocess
import sys
import time

repo = os.environ["XV6_REPO"]
qemu = os.environ["XV6_QEMU"]
log_path = os.environ["XV6_TEST_LOG"]

base_command = [
    qemu,
    "-machine", "virt",
    "-bios", "none",
    "-kernel", "kernel/kernel",
    "-m", "3G",
    "-smp", "3",
    "-nographic",
    "-drive", "file=fs.img,if=none,format=raw,id=x0",
    "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
]


def run_tests(cpu_args):
    command = base_command[:1] + cpu_args + base_command[1:]
    process = subprocess.Popen(
        command,
        cwd=repo,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        bufsize=0,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    with open(log_path, "ab") as log:
        def read_until(marker, timeout):
            output = bytearray()
            deadline = time.monotonic() + timeout
            while marker not in output:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("timed out waiting for xv6 output")
                if process.poll() is not None:
                    raise RuntimeError(f"QEMU exited with status {process.returncode}")
                events = selector.select(min(1.0, remaining))
                if not events:
                    continue
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    raise RuntimeError("QEMU closed its output")
                log.write(chunk)
                log.flush()
                output.extend(chunk)
            return bytes(output)

        def send(command_text):
            process.stdin.write(command_text.encode("ascii") + b"\n")
            process.stdin.flush()

        try:
            read_until(b"\n$ ", 45)
            send("alloctest")
            alloc_output = read_until(b"\n$ ", 300)
            for expected in (b"filetest: OK", b"memtest: OK"):
                if expected not in alloc_output:
                    raise RuntimeError(f"alloctest did not report {expected.decode()}")

            send("usertests")
            user_output = read_until(b"\n$ ", 600)
            if b"ALL TESTS PASSED" not in user_output:
                raise RuntimeError("usertests did not report ALL TESTS PASSED")
            return True, None
        except Exception as exc:
            return False, exc
        finally:
            selector.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


open(log_path, "wb").close()
attempts = [(["-cpu", "rv64,pmp=false"], "PMP compatibility mode"), ([], "default CPU mode")]
last_error = None
for cpu_args, label in attempts:
    with open(log_path, "ab") as log:
        log.write(("\n=== " + label + " ===\n").encode())
    passed, last_error = run_tests(cpu_args)
    if passed:
        break
else:
    print(f"ERROR: {last_error}", file=sys.stderr)
    try:
        with open(log_path, "rb") as saved:
            lines = saved.read().decode("utf-8", "replace").splitlines()
        print("Last xv6 output:", file=sys.stderr)
        print("\n".join(lines[-100:]), file=sys.stderr)
    except Exception:
        pass
    sys.exit(1)

print("=" * 54)
print("BUDDY LAB: ALL TESTS PASSED")
print("alloctest: filetest OK, memtest OK")
print("usertests: ALL TESTS PASSED")
print("Ready for Submit Evaluation")
print("=" * 54)
PY
