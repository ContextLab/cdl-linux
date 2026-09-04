#!/usr/bin/env python3
"""Boot the installed cdl-box VM, answer the LUKS prompt, and wait for SSH.

The passphrase prompt is the point. Spec §2.1 accepts that a reboot needs a human at the
machine, and §7.1 documents the offline window that creates. This driver reproduces that
sequence exactly rather than sidestepping it with a keyfile: it watches the serial console,
types the passphrase when asked, and then confirms the machine came all the way back.

A keyfile would make the harness simpler and would test something the real machine does not
do, which is the wrong trade for the one milestone whose whole subject is boot behaviour.
"""
import argparse
import os
import re
import selectors
import shutil
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def load_cfg():
    """Read lib.sh's settings rather than duplicating them."""
    out = subprocess.run(
        ["bash", "-c", f'source "{HERE}/lib.sh"; '
         'echo "$VM_WORK|$DISK0|$DISK1|$VM_MEM|$VM_CPUS|$SSH_PORT|$LUKS_PASSPHRASE|'
         '$QEMU|$QEMU_MACHINE|$QEMU_CPU"'],
        capture_output=True, text=True, check=True).stdout.strip().split("|")
    keys = ("work disk0 disk1 mem cpus ssh_port passphrase qemu machine cpu").split()
    return dict(zip(keys, out))


def find_edk2(name):
    for p in (subprocess.run(["bash", "-c", "brew --prefix qemu 2>/dev/null"],
                             capture_output=True, text=True).stdout.strip() + "/share/qemu/" + name,
              "/opt/homebrew/share/qemu/" + name,
              "/usr/local/share/qemu/" + name):
        if os.path.isfile(p):
            return p
    sys.exit(f"firmware not found: {name}")


def ssh_up(port, timeout=1.0):
    try:
        with socket.create_connection(("127.0.0.1", int(port)), timeout=timeout) as s:
            return b"SSH" in s.recv(64)
    except OSError:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--timeout", type=int, default=420, help="seconds to wait for SSH")
    ap.add_argument("--quiet", action="store_true", help="do not echo the serial console")
    args = ap.parse_args()
    cfg = load_cfg()

    if not os.path.exists(cfg["disk0"]):
        sys.exit(f"no installed disk at {cfg['disk0']}; run scripts/vm/install.sh first")

    code = find_edk2("edk2-aarch64-code.fd" if "aarch64" in cfg["qemu"] else "edk2-x86_64-code.fd")
    varsf = os.path.join(cfg["work"], "efi-vars.fd")

    cmd = [cfg["qemu"],
           "-machine", cfg["machine"], "-cpu", cfg["cpu"],
           "-smp", cfg["cpus"], "-m", cfg["mem"],
           "-drive", f"if=pflash,format=raw,readonly=on,file={code}",
           "-drive", f"if=pflash,format=raw,file={varsf}",
           "-drive", f"if=none,id=hd0,format=qcow2,file={cfg['disk0']}",
           "-device", "virtio-blk-pci,drive=hd0,serial=cdl0",
           "-drive", f"if=none,id=hd1,format=qcow2,file={cfg['disk1']}",
           "-device", "virtio-blk-pci,drive=hd1,serial=cdl1",
           "-netdev", f"user,id=net0,hostfwd=tcp::{cfg['ssh_port']}-:22",
           "-device", "virtio-net-pci,netdev=net0",
           "-nographic"]

    # Refuse to start on top of another VM holding these disks. qemu would fail to take
    # the image lock and exit, and the SSH probe below would then succeed against the OTHER
    # machine through the same port forward -- reporting a successful boot of a VM that
    # never started. That happened, and a harness that reports the wrong answer is worse
    # than one that reports nothing.
    other = subprocess.run(["pgrep", "-f", "qemu-system"], capture_output=True, text=True)
    for pid in other.stdout.split():
        cmdline = subprocess.run(["ps", "-p", pid, "-o", "command="],
                                 capture_output=True, text=True).stdout
        if "serial=cdl0" in cmdline:
            print(f"==> refusing to boot: pid {pid} is already using these disks.")
            print(f"    Stop it first:  kill {pid}")
            return 1

    print("==> booting; will answer the LUKS prompt on the serial console")
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, bufsize=0)

    # cryptsetup's wording has changed across releases, so match the stable part rather
    # than a full sentence.
    prompt = re.compile(rb"(passphrase|password).{0,40}(cryptroot|/dev/|:)", re.I)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)

    buf = b""
    sent = 0
    deadline = time.time() + args.timeout
    booted = False

    while time.time() < deadline:
        if proc.poll() is not None:
            print(f"\n==> qemu exited early with {proc.returncode}")
            break
        for _ in sel.select(timeout=1.0):
            chunk = proc.stdout.read(4096)
            if not chunk:
                continue
            buf += chunk
            if not args.quiet:
                sys.stdout.write(chunk.decode("utf-8", "replace"))
                sys.stdout.flush()
            tail = buf[-4096:]
            if sent < 3 and prompt.search(tail):
                time.sleep(0.7)          # let cryptsetup finish drawing the prompt
                proc.stdin.write(cfg["passphrase"].encode() + b"\n")
                proc.stdin.flush()
                sent += 1
                print(f"\n==> sent LUKS passphrase (attempt {sent})")
                buf = b""
        # Only trust the SSH probe while our own qemu is alive. The port forward is not
        # evidence that the forward belongs to us.
        if proc.poll() is None and ssh_up(cfg["ssh_port"]):
            booted = True
            break

    if booted and proc.poll() is None:
        print(f"\n==> SSH is up on port {cfg['ssh_port']}; passphrase prompts answered: {sent}")
        # Deliberately a PID, not a pattern. `pkill -f 'qemu.*cdl0'` matches the command
        # line of any shell that contains that string -- including the shell running the
        # pkill -- so it has twice killed a VM run it was meant to leave alone.
        print(f"==> VM left running as pid {proc.pid}. Stop it with: kill {proc.pid}")
        return 0

    if booted:
        print(f"\n==> qemu exited ({proc.returncode}) even though port "
              f"{cfg['ssh_port']} answered; that SSH was not ours")
        return 1

    print(f"\n==> did not reach SSH within {args.timeout}s (passphrase prompts answered: {sent})")
    proc.terminate()
    return 1


if __name__ == "__main__":
    if not shutil.which("qemu-system-aarch64") and not shutil.which("qemu-system-x86_64"):
        sys.exit("qemu is not installed")
    sys.exit(main())
