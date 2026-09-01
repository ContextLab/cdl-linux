# Hardware captures

Output of `scripts/capture-hardware.sh` lands here and is **gitignored**.

Captures contain serial numbers, MAC addresses, filesystem UUIDs and hostnames. D1 commits to
keeping personal data out of a publishable artifact, so nothing in this directory is committed.

When a captured fact needs to appear in a specification, quote the *fact* and redact the identifier:
write "two 1 TB NVMe drives, both 512e/4Kn" rather than pasting the `nvme list` block.
