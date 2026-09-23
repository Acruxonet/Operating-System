#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ARCHIVE=${MMAP_ARCHIVE:-$SCRIPT_DIR/mmap_solution.tar.gz}

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
  if ! command -v git >/dev/null 2>&1; then
    echo 'ERROR: git is required to clone the xv6 mmap branch.' >&2
    exit 1
  fi
  REPO=${HOME}/xv6-riscv
  if [ ! -d "$REPO/.git" ]; then
    echo '[0/4] Cloning the xv6 mmap branch...'
    git clone --branch mmap https://github.com/matlapo/xv6-riscv.git "$REPO"
  fi
fi

if [ ! -f "$ARCHIVE" ]; then
  echo "ERROR: missing $ARCHIVE" >&2
  exit 1
fi
if [ -z "$REPO" ] || [ -z "$TOOLPREFIX" ] || [ -z "$QEMU" ] || [ -z "$PYTHON" ]; then
  echo 'ERROR: xv6-riscv, RISC-V GCC, QEMU, or python3 was not found.' >&2
  exit 1
fi

TMP_DIR=$(mktemp -d /tmp/xv6-mmap-solution.XXXXXX)
BUILD_LOG=/tmp/xv6-mmap-build.log
TEST_LOG=/tmp/xv6-mmap-test.log
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

echo '[1/4] Installing mmap solution...'
for source in Makefile kernel/defs.h kernel/exec.c kernel/fcntl.h kernel/proc.c kernel/proc.h kernel/riscv.h kernel/syscall.c kernel/syscall.h kernel/sysfile.c kernel/trap.c kernel/vm.c user/user.h user/usys.pl; do
  tar -tzf "$ARCHIVE" | grep -Fxq "$source" || {
    echo "ERROR: archive does not contain $source" >&2
    exit 1
  }
done
tar -xzf "$ARCHIVE" -C "$TMP_DIR"

cd "$REPO"
if [ "${MMAP_SKIP_CHECKOUT:-0}" != 1 ] && [ -d .git ]; then
  current_ref=$(git symbolic-ref --quiet HEAD 2>/dev/null || true)
  if [ "$current_ref" != refs/heads/mmap ]; then
    if ! git diff --quiet || ! git diff --cached --quiet; then
      GIT_AUTHOR_NAME='Xv6 lab backup' \
      GIT_AUTHOR_EMAIL='xv6-lab-backup@localhost' \
      GIT_COMMITTER_NAME='Xv6 lab backup' \
      GIT_COMMITTER_EMAIL='xv6-lab-backup@localhost' \
        git stash save 'Saved automatically before mmap lab' >/dev/null
      echo 'Existing tracked changes saved in git stash.'
    fi
    if git show-ref --verify --quiet refs/heads/mmap; then
      git checkout mmap >/dev/null
    else
      git checkout -b mmap origin/mmap >/dev/null
    fi
  fi
fi

for source in Makefile kernel/defs.h kernel/exec.c kernel/fcntl.h kernel/proc.c kernel/proc.h kernel/riscv.h kernel/syscall.c kernel/syscall.h kernel/sysfile.c kernel/trap.c kernel/vm.c user/user.h user/usys.pl; do
  cp "$TMP_DIR/$source" "$source"
done
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

echo '[3/4] Running mmaptest...'
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
    qemu, "-machine", "virt", "-bios", "none", "-kernel", "kernel/kernel",
    "-m", "128M", "-smp", "3", "-nographic",
    "-drive", "file=fs.img,if=none,format=raw,id=x0",
    "-device", "virtio-blk-device,drive=x0,bus=virtio-mmio-bus.0",
]


def run_tests(cpu_args):
    command = base_command[:1] + cpu_args + base_command[1:]
    process = subprocess.Popen(
        command, cwd=repo, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT, bufsize=0,
    )
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output_all = bytearray()
    with open(log_path, "ab") as log:
        def read_until(marker, timeout, start=0):
            deadline = time.monotonic() + timeout
            while marker not in output_all[start:]:
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
                output_all.extend(chunk)
                log.write(chunk)
                log.flush()

        def send(command_text):
            process.stdin.write(command_text.encode("ascii") + b"\n")
            process.stdin.flush()

        def run_command(command_text, timeout):
            previous = len(output_all)
            send(command_text)
            read_until(b"$ ", timeout, previous)
            return bytes(output_all[previous:])

        try:
            read_until(b"$ ", 60)
            output = run_command("mmaptest", 300)
            for expected in (b"mmap_test OK", b"fork_test OK", b"mmaptest: all tests succeeded"):
                if expected not in output:
                    raise RuntimeError("mmaptest failed: missing %s" % expected.decode())
            output = run_command("usertests", 1200)
            if b"ALL TESTS PASSED" not in output:
                raise RuntimeError("usertests did not report ALL TESTS PASSED")
            return None
        except Exception as exc:
            return exc
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
last_error = None
for cpu_args in (["-cpu", "rv64,pmp=false"], []):
    last_error = run_tests(cpu_args)
    if last_error is None:
        break
else:
    print("ERROR: %s" % last_error, file=sys.stderr)
    with open(log_path, "rb") as saved:
        lines = saved.read().decode("utf-8", "replace").splitlines()
    print("Last xv6 output:", file=sys.stderr)
    print("\n".join(lines[-100:]), file=sys.stderr)
    sys.exit(1)

print("=" * 54)
print("MMAP LAB: ALL TESTS PASSED")
print("mmaptest: mmap_test and fork_test OK")
print("usertests: ALL TESTS PASSED")
print("Ready for Submit Evaluation")
print("=" * 54)
PY
