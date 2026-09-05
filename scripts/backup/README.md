# The second copy

`pull-second-copy.sh` runs on a machine that is **not the box**, and pulls the backup
repository from the Hugging Face bucket to local storage. It exists because the bucket has
no versioning and no lifecycle rules, so a write-capable token on the box can erase the
backup history in one command (spec §10.2, threat T5). RAID0 makes that the only copy of
everything.

## Operations

These are the answers spec §10.2 requires, not suggestions. Where a value is a policy
rather than a measurement, it says so.

| | |
|-|-|
| **Owner** | The machine's operator, by name, in `notes/` -- not "the system". This file does not name a person because the repository is public; the note does |
| **Runs on** | A laptop or desktop the operator uses daily, so a failure is seen. Not a machine in the same room as the box on the same power circuit |
| **Schedule** | Daily. This sets the window in which a wipe can go unnoticed, and is the number to argue about if any is |
| **The box's own schedule** | Nightly `restic backup` (§10.3). This was previously unstated, which meant the RPO below could not be defined |
| **Recovery-point objective** | Bucket: up to 24 h of work. Second copy: up to 48 h, since a nightly backup then waits for the next daily pull. Policy, not measurement: it follows from the two intervals above |
| **Retention** | The second copy accumulates. `copy` never deletes at the destination, and `--immutable` never overwrites, so blobs the box prunes stay here. Prune the second copy deliberately, from this machine, with `restic forget --prune` against the *local* path -- never from the box, which has no route to it |
| **Capacity** | The script refuses to start below `CDL_PULL_MIN_FREE_GB` (default 20). Set it to at least twice the repository size; a second copy that silently stops for want of space is worse than none, because it is believed in |
| **Failure alert** | The script exits nonzero and prints one line. Give `CDL_PULL_NOTIFY` a command that puts that line somewhere a human looks (a notifier, a chat webhook, `mail`). cron mails stderr by default; that is enough if the mail is read |
| **Run record** | `pull-runs.jsonl` beside the destination, one line per run: started, result, detail, seconds. The quarterly check reads this, not memory |
| **Restore test** | Quarterly, **from the second copy**, not from the bucket: `restic -r /path/to/second-copy/restic restore latest --target /tmp/x`. That is the copy nobody exercises and therefore the one most likely to be broken |

## Trust boundary

- This machine holds **its own** Hugging Face token, scoped to the one bucket, in its own
  `rclone.conf` (mode 0600; the script refuses anything more permissive).
- The box's token is never on this machine. The box has no credential for, and no route
  to, this machine's storage.
- The restic password is **not** needed here. Every restic file is named by the SHA-256 of
  its content, so integrity is verified without it. The password lives with the person.

## What is measured, and what is not

`tests/net-second-copy.sh` runs against the real bucket and asserts the copy survives:

| Event | Outcome |
|-|-|
| The bucket is wiped | Restore from the second copy is byte-identical |
| Pull from the wiped bucket | Nothing deleted locally |
| A bucket file is replaced with different content | Pull refuses; local file untouched |
| A bucket file is replaced with **same size and same mtime** | rclone sees no difference and skips it, so it never enters the second copy. The local file stays good |
| A local file rots, mtime unchanged | Detected by content hash; the run fails and says the copy is not trustworthy |

**The boundary in that fourth row is deliberate.** The puller does not audit the bucket; it
keeps a copy it can vouch for. Whether the *bucket* is intact is the box's question, and
`restic check --read-data` on the box answers it.

**Two rclone findings that shaped the script**, both measured against the HF gateway:

- `--checksum` makes things **worse**. The gateway returns no content hash, and rclone
  treats "no hash" as "same", so same-size corruption passes. The script does not use it.
- `--immutable` compares size and mtime. rclone sets the local mtime to the remote's on
  pull, so any overwrite in the bucket changes the remote mtime and is caught -- unless the
  attacker preserves it, which is why the content-hash check exists and always runs.

## Running it

```bash
# once: this machine's own token, in its own config
install -m 0600 /dev/null ~/.config/cdl/rclone.conf
cat > ~/.config/cdl/rclone.conf <<'CONF'
[hf]
type = s3
provider = Other
endpoint = https://s3.hf.co/<namespace>
access_key_id = <this machine's key>
secret_access_key = <this machine's secret>
region = us-east-1
force_path_style = true
list_version = 2
CONF

# daily
RCLONE_CONFIG=~/.config/cdl/rclone.conf \
CDL_PULL_REMOTE=hf:<bucket>/restic \
CDL_PULL_DEST=/Volumes/Backup/cdl-second-copy/restic \
CDL_PULL_NOTIFY=/usr/local/bin/notify-me \
  scripts/backup/pull-second-copy.sh
```

On macOS put that in a `launchd` agent; on Linux a `systemd --user` timer or cron. Either
way the notify command is the part that makes it an alert rather than a log.
