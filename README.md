# oVirt → Proxmox VE migration toolkit

## Why does this exist?

This toolkit was written for moving VMs from an oVirt cluster with block storage to Proxmox VE, over a few weekends with tight maintenance windows. The usual ways out of oVirt (OVA export or an export domain) copy every disk at least twice and need extra storage. Our manual per-disk procedure was faster but error-prone: detach, attach to a helper VM, find the right `/dev/dm-X`, `qemu-img convert`, `qm importdisk`, attach, set the boot disk. During the first runs, a disk was attached to the wrong slot, the staging pool filled up and paused every VM on it, and Windows VMs didn't boot without the right drivers.

This toolkit automates that procedure end to end and adds the safety checks we were missing: preflight, saved original state and one-command rollback, space limits, and progress with a realistic ETA. Every weekend batch then runs the same way, with one script in the share.

One script, `migrate.sh`, lives in the shared NFS directory together with its config. You run it on the oVirt host to export disks and on the PVE host to import them. The source disk in oVirt is never modified, so a rollback is always possible.

| Command | Runs on | What it does |
|---|---|---|
| `export <vm>...` | oVirt host | Shuts the VM down, moves its disks read-only to the datamover, checks device access, exports them to qcow2 in parallel |
| `restore <vm>...` | oVirt host | Rollback: detaches the disks from the datamover and re-attaches them to the original VM with the original interface and boot flag |
| `release <vm>...` | oVirt host | After a successful migration: detaches the disks from the datamover (they stay in oVirt, unattached) |
| `import [--start]` | PVE host | Listens for exported files, imports each one into the right VM and slot, sets the boot order. With `--start`, starts each VM once all its disks are imported. |
| `status` | either | Progress, recent rate and ETA of all exports and imports |
| `lookup <vm>...` | oVirt host | Read-only: shows a VM's disks (slot suggestion, bus, size, name, ID) and prints ready-made `disks.csv` lines with `<PVE_VMID>` as placeholder |
| `list` | either | All VMs from `disks.csv` with their full (thick) size, largest first. On PVE additionally which VMs and disks are already completely imported. |

---

## How it works

```
oVirt host (runs the datamover)                      PVE host
┌──────────────┐  detach   ┌─────────────────┐       ┌───────────────────────────────┐
│  source VM   │ ────────► │ datamover VM    │       │ /data/ovirt-export (NFS)      │
│  (shut down) │  attach   │ disks attached  │       │                               │
└──────────────┘    RO     │ read-only       │       │ <vm>-<slot>.qcow2.part        │
                           └────────┬────────┘       │   ↓ rename when complete      │
                                    │ /dev/dm-X      │ <vm>-<slot>.qcow2             │
                     qemu-img convert ─────────────► │   ↓ migrate.sh import         │
                                                     │ qm set --<slot> import-from=… │
                                                     └───────────────────────────────┘
```

## Snapshots

A disk with snapshots consists of several volumes. Exporting only the top one would give an incomplete disk, so `export` checks every VM first. If it finds snapshots, it lists them and asks whether to remove them. Removing a snapshot in oVirt merges its data into the disk: the disk and its data stay, only the restore point is gone. The script then removes them one at a time, waits for each merge (up to `SNAPSHOT_TIMEOUT`), verifies that no snapshots remain and every disk is still present, and continues with the export. Answer `N` and nothing is changed. With `-y` the regular snapshots are removed without asking. Previews, stateless snapshots and unknown types are never touched; the export stops and you handle them in oVirt.

## Why a temporary helper VM (datamover)?

- **The disks have to be readable on the export host.** On oVirt block storage, every disk is a logical volume in the storage domain's volume group, and thin disks are qcow2 images inside that LV. vdsm only activates an LV on a host while a VM running on that host uses it. Hot-attaching the disk to a running VM on the export host makes vdsm activate it there, which gives `qemu-img` a readable `/dev/dm-X` device. No manual `lvchange` is needed, and vdsm's locking isn't bypassed.
- **Read-only keeps the source safe.** The migration can't change the source disk. The original disk stays complete in oVirt, so rolling back means re-attaching it (`restore`).
- **One direct copy.** There's no export domain, no OVA and no copy inside oVirt. The data is read once into a qcow2 on the NFS share, then imported locally on PVE.
- **Any running VM on that host works as the helper.** In this setup that's the **Datamover** VM, an existing backup proxy that is built for hot-attaching foreign disks. **It must run on the host where you start `export`.**
- **Single-volume disks only.** The export reads exactly one volume per disk. Snapshot chains are detected and rejected.

---

## Files in the share

| Path | Purpose |
|---|---|
| `migrate.sh` | The script |
| `migrate.conf` | All settings (both sides); required, the script has no defaults |
| `disks.csv` | Which disk goes to which PVE VM and slot |
| `state/<vm>.disks` | Original oVirt attachment (interface, boot flag), saved before moving; used by `restore` |
| `state/disk-sizes.csv` | Disk sizes from the engine, written by `list` and `export` on the oVirt host, so `list` on PVE can show them |
| `state/<vm>.nics` | Original MAC addresses; `import` prints a hint if the PVE VM uses a different MAC |
| `logs/` | Per-disk logs plus `.start` / `.end` / `.fail` / `.size` / `.samples` / `.queued` markers |
| `*.qcow2.part` | Export in progress |
| `*.qcow2` | Export complete, waiting for import |
| `importing/`, `imported/` | Import running / import done (delete these files after verifying the VM) |
| `unmatched/` | Files without a matching line in `disks.csv` |
| `stale/` | Exports invalidated by `--restore-on-abort` (the VM runs on oVirt again); safe to delete |

## Requirements

- **oVirt host:** bash, curl, python3, qemu-img (all present on oVirt hosts), the share mounted, and an engine API user allowed to shut down VMs and manage disk attachments.
- **PVE host:** PVE 7.2 or later (for `import-from`), the share mounted or exported locally, and the target VMs already created without disks.
- **Both:** tmux. The scripts warn if they don't run inside tmux or screen.

## Configuration

### `migrate.conf`

**All settings live in `migrate.conf`; the script has no built-in defaults.** Each command checks the settings it needs before doing anything, and stops with a list of whatever is missing, empty, or not a whole number where one is expected. To use a config elsewhere (e.g. one per customer), run with `MIGRATE_CONF=/path/to/file ./migrate.sh …`.

| Setting | Needed by | Meaning |
|---|---|---|
| `ENGINE_URL`, `ENGINE_USER` | export, restore, release | oVirt engine API (`https://<engine>/ovirt-engine/api`). The script logs in via the engine's SSO token endpoint, like the oVirt SDKs. The user is `<user>@<profile>`: with oVirt 4.5 and Keycloak `admin@ovirt@internalsso`, on older setups `admin@internal`. A failed login shows the engine's own error message. |
| `ENGINE_CA` | export, restore, release | `/etc/pki/vdsm/certs/cacert.pem` on oVirt hosts, or `insecure` |
| `ENGINE_PASS_FILE` (optional) | export, restore, release | Local file on the oVirt host (chmod 600). If it's empty or missing, the script prompts. **Don't put the password in `migrate.conf`**, because the file sits on the share. |
| `DATAMOVER_VM` | export, restore, release | Name of the helper VM |
| `DM_INTERFACE`, `DEFAULT_INTERFACE` | export, restore, release | Bus on the datamover, and the restore fallback if no saved state exists |
| `SHUTDOWN_TIMEOUT`, `DEVICE_TIMEOUT` | export, restore, release | Seconds to wait for the guest shutdown and for the device to appear |
| `SNAPSHOT_TIMEOUT` | export, restore, release | Seconds to wait for one snapshot removal (merge) to finish, e.g. `7200` |
| `PAR` | export, restore, release | Parallel exports (3–4; more doesn't help once the NFS link is saturated) |
| `EXPORT_MAX_PCT` | export, restore, release, status | Limit for the export share (e.g. `95`). No export starts that could push the share above it, and running exports are aborted if it's reached anyway. |
| `STORAGE` | import, status | PVE target storage |
| `DISK_OPTS` | import | Options for every imported disk; must be defined but may be `""` |
| `MAX_POOL_PCT` | import, status | `import` waits instead of pushing the storage above this level (planned with the full disk size) |
| `POLL` | import | Seconds between checks for new files |
| `RATE_WINDOW`, `STALL_SEC` | status, list | Window for the recent rate, and the time without writes to a partial export file before `STALL?` (e.g. `300`) |

### `disks.csv`

The easiest way to fill it: run `./migrate.sh lookup <vm-name-as-in-oVirt>` on the oVirt host and copy the printed lines; replace `<PVE_VMID>` with the PVE VM ID. Slots follow the VM's current bus (`virtio_scsi` → `scsiN`, `sata` → `sataN`, `virtio` → `virtioN`), boot disk first, then by disk name. Shareable disks and direct LUNs are printed commented out, because they can't be migrated this way. A typo in the VM name gets you a list of similar names.


```
# name;pve_vmid;ovirt_disk_id;pve_slot;boot[;ovirt_vm_name]
fileserver;101;3f2a9c1e-7b4d-4e8a-9c2f-1a2b3c4d5e6f;scsi0;1
fileserver;101;8d7e6f5a-4b3c-4d2e-8f1a-0b9c8d7e6f5a;scsi1;0
termserver;102;c4b3a291-0f8e-4d7c-b6a5-948372615f0e;sata0;1;termserver.example.com
```

- **`ovirt_disk_id`** is the folder right after `images/` in `/rhev/data-center/<dc>/<sd>/images/<DISK_ID>/<VOLUME_ID>`, which is the same ID oVirt shows under Storage → Disks. You never need the volume ID; the script finds it.
- **`pve_slot`** sets the bus on PVE and the file name `<name>-<slot>.qcow2`. **Don't change it after the export has started**, or the import won't find a matching line.
- **`boot = 1`** on exactly one disk per VM.
- **Spaces around the `;` separators and Windows line endings are fine.** The script checks the whole file before every command and lists all errors at once.
- **`ovirt_vm_name`** is only needed if the oVirt VM name differs from `name`.

---

## Usage

```bash
# PVE (tmux), start first:
./migrate.sh import
./migrate.sh import --start             # also start each VM once all its disks are imported

# oVirt host (tmux):
./migrate.sh export fileserver appserver   # preflight table, confirm, shut down, move, export
./migrate.sh export fileserver -n           # dry-run: show checks and API calls only

# anywhere:
./migrate.sh status
./migrate.sh status --watch 60
./migrate.sh list                         # VMs by size; on PVE: what's already imported

# rollback / cleanup (oVirt host):
./migrate.sh restore fileserver --start
./migrate.sh release fileserver
```

**Stopping `export` safely:**
- **Ctrl-C once:** no more disks start; running exports finish. Disks that didn't start are marked "not started" (visible in `status` and to the import side).
- **Ctrl-C twice:** running exports are aborted, their partial files deleted and marked "aborted".
- **Afterwards** the script tells you what's next: rerun `export` (finished disks are skipped), or roll back with `restore`. With `--restore-on-abort` it does the rollback itself (see below).
- **Exports run in their own session,** so an SSH disconnect doesn't kill them, and the space watchdog keeps guarding until they're done. Disks still queued at that moment don't start; rerun `export` to continue. Still, run it in tmux.

**`--restore-on-abort`:** if any disk of a VM ends up not exported (Ctrl-C, space abort or an error), that VM is put back on oVirt right away: its disks are re-attached with the saved interface and boot flag, and it's started again if it was running before the export. Its already finished exports from this attempt are moved to `stale/` and marked, because the VM's data changes once it runs again; a later `export` then exports every disk again instead of mixing old and new disks, and `import --start` never starts a VM with stale disks. If a stale disk was already imported on PVE, the script warns you to remove it there.

**Stopping `import` safely:**
- **Ctrl-C once:** no new imports start. The listener shows the running imports with their progress, waits for them to finish and then exits by itself.
- **Ctrl-C twice:** the listener exits immediately. Running imports continue in the background; follow them with `status`.
- **Imports run in their own session,** so neither Ctrl-C nor an SSH disconnect can interrupt a running `qm` import. Exports that finish while the listener is stopped simply wait in the share; the next `import` picks them up.

| Option | Effect |
|---|---|
| `-y`, `--yes` | No confirmation prompts. A hard stop of a VM that doesn't shut down is never automatic: in `-y` mode the export aborts for that VM instead. |
| `-n`, `--dry-run` | `export` / `restore` / `release`: run all checks and print the API calls, change nothing |
| `-f`, `--force` | Re-export disks that were already exported |
| `-r`, `--restore-on-abort` | `export`: put VMs that couldn't be exported completely back on oVirt (see above) |
| `-s`, `--start` | `restore`: start the VM afterwards. `import`: start each VM once every disk listed for it in `disks.csv` is imported. |
| `-w`, `--watch [s]` | `status`: refresh every *s* seconds |

---

## Recommended procedure

### Once, before the first batch

1. **Make sure you have an access path that doesn't depend on any VM you'll migrate.** A working VPN to the server network, plus a jump host that stays on oVirt until the very end. Don't migrate the remote-support machine or the monitoring server early.
2. **Create the PVE VMs without disks.** Use the same CPU, RAM and NIC settings, the original MAC addresses (see `state/<vm>.nics` after the first export, or look them up in oVirt), and `ostype` `win*` for Windows.
3. **Fill in `disks.csv`** and run `export <vm> -n` once to verify that disk IDs, names and sizes match.
4. **Plan the space** (see "Space planning" below).
5. **Make sure a current backup exists** of every VM in the batch.
6. **Do a test run with a small VM.**

### Per batch

1. Start `./migrate.sh import` on PVE, in tmux. Add `--start` only if the batch contains no Windows VMs that might still need the SATA fix (see the Windows section).
2. **Windows VMs:** do the "before" steps in the Windows section below while they're still running on oVirt.
3. Run `./migrate.sh export <vm>...` on the oVirt host, in tmux. Check the preflight table (VM state, slot, boot, disk name, size), then confirm.
4. Follow progress with `./migrate.sh status --watch`. Use the recent `RATE`, not the average.
5. When the import shows `DONE` for all disks of a VM, start the PVE VM (or let `--start` do it) and run the checks below.

### After each VM

- **It works:** delete the VM's files in `imported/`, then run `./migrate.sh release <vm>`. Delete the oVirt VM and its disks by hand only later, once you're sure.
- **It doesn't work:** stop the PVE VM and run `./migrate.sh restore <vm> --start`. Remove the imported disks from the PVE VM before you try again.

### Post checks (all VMs)

- Disks and partitions present, everything from fstab mounted, applications running.
- Network: IP, gateway, DNS, and the correct VLAN tag or bridge on PVE.
- Time synchronized (see Troubleshooting).
- QEMU guest agent running, `qm set <vmid> --agent enabled=1`, then a full stop and start.
- Monitoring: rediscover the host's services in your monitoring system.
- Never run the old and the new VM at the same time (IP and MAC conflicts).

---

## Windows VMs: extra todos

**Before the export, while the VM still runs on oVirt:**
- **Install `virtio-win-guest-tools.exe`** from the virtio-win ISO. This installs the drivers and the QEMU guest agent.
- **Write down the IP configuration** (`ipconfig /all`).
- **Use `sataX` in `disks.csv` if you're not sure** the `vioscsi` driver is set to boot start (`sc.exe qc vioscsi` must show `START_TYPE: 0 BOOT_START`).

**After the import:**

Don't use `import --start` for a Windows VM whose boot disk is on `scsi0` unless you're sure `vioscsi` is set to boot start. Otherwise it boots straight into `INACCESSIBLE_BOOT_DEVICE` and automatic repair.

1. **Boot.** If you get `INACCESSIBLE_BOOT_DEVICE`, switch the disk to SATA. With the VM stopped:
   ```bash
   sed -i 's/^scsi0:/sata0:/; s/order=scsi0/order=sata0/' /etc/pve/qemu-server/<vmid>.conf
   ```
2. **Get back to VirtIO SCSI:**
   1. Hot-add a temporary 1 GB SCSI disk.
   2. In PowerShell, run `sc.exe qc vioscsi` (`sc` alone is a PowerShell alias). If it doesn't show `BOOT_START`, run:
      ```powershell
      reg.exe add HKLM\SYSTEM\CurrentControlSet\Services\vioscsi /v Start /t REG_DWORD /d 0 /f
      ```
   3. Shut down, move the boot disk back to `scsi0`, remove the temporary disk, fix the boot order.
3. **Network:**
   - Untick **Disconnect** on the PVE NIC if it's set.
   - Device Manager → View → Show hidden devices → uninstall the old network adapter.
   - Set the static IP on the new adapter.
4. **Offline data disks:** run `Get-Disk`. If disks show as offline or read-only:
   ```powershell
   Get-Disk | Where-Object IsOffline | Set-Disk -IsOffline $false
   Get-Disk | Where-Object IsReadOnly | Set-Disk -IsReadOnly $false
   ```
   Then check that the drive letters are the same as before.
5. **Guest agents:** uninstall the oVirt guest agent and check `Get-Service QEMU-GA`. The SPICE agent is only needed if the VM uses a SPICE display.
6. **Time:** `localtime` should be on (the default for `ostype win*`). If the clock is exactly 1 hour off, run `qm set <vmid> --localtime 1`. Then run `w32tm /resync /force`.
7. **Activation:** Windows may ask for reactivation because the virtual hardware changed.

## Linux VMs: extra todos

- **Interface name changes** (`eth0` / `ens3` becomes `ens18`). Fix `/etc/network/interfaces` and use `auto <if>`, not `allow-hotplug`, so the network is up before services like nmbd start.
- **Guest agent:** run `apt purge ovirt-guest-agent`, then `apt install qemu-guest-agent && systemctl enable --now qemu-guest-agent`.
- **Failed services:** run `systemctl --failed`, fix whatever is listed, then `systemctl reset-failed`.
- **LVM:** `lvm2-pvscan@…` "failed" messages at boot are harmless if `pvs` / `lvs` show everything active.
- **Filesystems:** if the boot log shows `recovery complete`, run `e2fsck -f` on the affected volumes at a quiet moment.
- **Samba / AD members:** check `wbinfo -t` and `net ads testjoin`. "Clock skew too great" means a time problem (see Troubleshooting).

---

## Space planning

**Both checks plan with the full (thick) disk size, not the data actually used.** A thin disk can be written up to its full size during the copy, so only the full size is guaranteed to fit. A 500 GB disk with 80 GB of data needs 500 GB of headroom.

**Export share (`EXPORT_MAX_PCT`, e.g. 95 %), three layers:**
1. **Before anything is shut down:** `export` adds up the full sizes of all disks in the run (plus what running exports may still write) and refuses to start if the share would go above the limit. The `SPACE` line shows the numbers.
2. **Before each disk:** every export checks again, under a lock, so parallel exports can't claim the same free space. A disk that doesn't fit fails with a reason and isn't started.
3. **While exporting:** a watchdog checks the share every 5 seconds. If it reaches the limit anyway (for example because something else writes to the same pool), it stops all exports to the share, deletes their partial files and doesn't start queued disks. Free space and rerun `export`; finished disks are skipped.

**Import storage (`MAX_POOL_PCT`):** an import starts only if its full disk size (plus imports already running, plus 10 % headroom) fits and keeps the storage at or below the limit. Otherwise it shows `HOLD … waiting` and starts once space is free.

**General advice:**
- **If the share lives on the same pool as the VM storage, every disk takes space twice** during the migration: once as the qcow2 file, once as the PVE disk. A full pool pauses **every** VM on it with `io-error`.
- **Delete the files in `imported/`** as soon as each VM is verified.
- **ZFS slows down sharply above about 80 % full.** Consider a quota on the staging dataset, e.g. `zfs set quota=1T data/ovirt-export`.
- **Don't let big exports and big imports compete** on a tight pool. In this setup, export speed dropped to about 5 MB/s under contention, compared to about 15–25 MB/s (60–80 GB/h) with the pool to itself.

## Overview: `list`

Shows every VM from `disks.csv` with its disks, the full (thick) size and the allocated size, sorted largest first, plus a total. The column `ON OVIRT` / `ON PVE` shows whether the VM is `running` or `off` on the hypervisor you run it on (`not found` / `-` if it doesn't exist there). Useful for planning batches and for checking progress over several weekends.

- **On the oVirt host** the sizes come from the engine. They're also stored in `state/disk-sizes.csv`, so the PVE side can show them. An info line reminds you that the PVE host shows the import state too.
- **On the PVE host** each disk shows its state: `imported`, `on PVE (no import record)` (e.g. migrated by hand before using this script), `importing`, `exported, waiting for import`, `exporting`, `queued for export`, `export failed: <reason>`, `stale` or `not exported yet`. Each VM is summarized as `COMPLETE`, `in progress`, `partial`, `ATTENTION` (a failed or stale disk), `not started` or `PVE VM missing`, followed by how many VMs are complete and how much is still to migrate.
- **Disks in a different slot than `disks.csv` says** (e.g. moved from `sata0` to `scsi0` after a Windows driver fix) are matched by size against the PVE VM's other disks and shown as "as scsi0 (matched by size; disks.csv says sata0)". Update `disks.csv` to the real slots.
- **ALLOC can be larger than SIZE.** On oVirt block storage it's the size of the disk's logical volume, which oVirt grows in steps and doesn't shrink (e.g. after deleting snapshots). The export contains only the disk content and is never larger than SIZE.
- **Sizes shown as `?`** haven't been fetched yet. Run `list` on the oVirt host once.

## Status, rate and ETA

```
STAGE   DISK                       STATE     PCT  ELAPSED     RATE      ETA
export  termserver-sata0           RUN     37.0%    2h57m   17MB/s    4h38m
import  fileserver-scsi2           DONE   100.0%    0h41m        -        -
export  appserver-scsi1            QUEUED      -        -        -        -
```

- **`RATE` and `ETA`** are based on the last `RATE_WINDOW` (30 minutes by default), so a slow start doesn't distort them. Every `status` call records a progress sample.
- **Progress comes in 1 % steps.** On big disks, the first value can take several minutes to appear.
- **Thin disks:** empty regions copy almost instantly, so early ETAs can be too optimistic.
- **`DEAD`** means the export or import process is gone without a result (killed, reboot, lost session). It's detected immediately on the host that ran it: `qemu-img` on oVirt, `qm` on PVE. Rerun export or import for that disk.
- **`STALL?`** means no data was written to the partial export file for `STALL_SEC` (e.g. `300` = 5 minutes) while the process still exists, or, on the other host, where the process isn't visible. Check the process and the storage.
- **`QUEUED`** means the disk is waiting for a free export slot.
- **`ELAPSED` compares timestamps from both hosts.** If their clocks differ, the value is off by that difference; keep both hosts on NTP.
- **The footer** shows the reason for every failed disk, files waiting for import, unmatched files, and the usage of the export share and the PVE storage against their limits.

---

## Built-in safety checks

**All commands:**
- Refuse a world-writable `migrate.conf` (it's sourced as root).
- Validate `disks.csv` first: VMID, disk ID and slot format, duplicate lines, slots or disk IDs, and exactly one boot disk per PVE VM.

**`export`:**
- Warns about disks attached to the VM in oVirt that aren't in `disks.csv`, because they won't be migrated.
- Refuses to run if the datamover isn't running, or warns and asks if it runs on another host.
- Finds snapshots and lists them (date, type, description). The export should run without snapshots, so it offers to remove them one by one (`y/N`, default no; automatic with `-y`) and waits for each merge to finish. Only snapshots of type `regular` are ever removed: a VM that is previewing a snapshot, or has a stateless or unknown snapshot type, is refused. Afterwards it checks that no snapshots remain and every disk is still there.
- **Can't delete a disk:** every deleting API call is checked against a whitelist. Only two kinds are allowed: detaching a disk from a VM (with `detach_only=true`, so the disk always stays in oVirt) and removing a snapshot of a VM. Anything else, e.g. `DELETE /disks/…`, is refused before it reaches the engine.
- Rejects disks with more than one volume (snapshot chain) as a second check on the storage side.
- Prints a preflight table and asks for confirmation before changing anything.
- Saves the original attachment (interface, boot flag, MAC addresses) before moving any disk.
- Tries a clean shutdown first and asks before a hard stop; never a hard stop with `-y`.
- Attaches disks read-only and waits until the block device is actually accessible before exporting.
- Plans the export share with the full disk sizes before shutting anything down, checks again before each disk, and aborts all exports (deleting partial files) if the share reaches `EXPORT_MAX_PCT` anyway.
- Writes `.part` files and renames them only on success, so incomplete files are never imported.
- Uses one lock per VM, so two exports, restores or releases for the same VM can't run at once.

**`restore` and `release`:**
- Refuse to run while an export of that VM is still running.
- `restore` only works on a stopped VM and verifies the boot disk afterwards.

**`import`:**
- Imports only files that have a line in `disks.csv`, and moves everything else to `unmatched/`.
- Never overwrites an occupied PVE slot; it shows `HOLD` instead.
- Waits for free space, planned with the full disk size (see "Space planning").
- Runs imports into the same VM one after another.
- With `--start`: starts a VM only after **every** disk listed for it in `disks.csv` has been imported, each import being newer than that disk's last export. A VM that's already running is left alone.
- If an import fails, the file stays in `importing/`. Move it back to the share root to retry.

**Not covered, so check yourself:**
- Whether a disk ID in `disks.csv` belongs to the right VM. Compare the names and sizes in the preflight table.
- Guest-level problems after the import: drivers, network, time.

## Rollback

1. Stop the PVE VM.
2. Run `./migrate.sh restore <vm> --start` on the oVirt host. This works whether the disks are currently on the datamover or already released.
3. On PVE, remove the imported disks from the VM before the next attempt.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `INACCESSIBLE_BOOT_DEVICE` (Windows) | The `vioscsi` driver isn't loaded at boot. Boot via SATA, then follow the VirtIO steps in the Windows section. |
| No network, "Medium getrennt" | The **Disconnect** checkbox on the PVE NIC is ticked, or the static IP is still bound to the hidden old adapter |
| "Clock skew too great" or NTP alarms with an offset of many hours | VMs that were paused (for example by a full pool) resume with their clock stopped at the pause time. Fix the DCs first: `chronyc makestep`, and set `makestep 1 -1` in chrony.conf. Don't use `timedatectl set-ntp true` on chrony hosts, because it stops chrony. |
| `HOLD … not enough space` | Free space (delete files in `imported/`, old backups) or raise `MAX_POOL_PCT` carefully |
| `not enough space on the export share` / `ABORT export share at …%` | Free space on the share (verified files in `imported/`), then rerun `export` - finished disks are skipped. Or export fewer VMs per run. |
| `HOLD … slot in use` | That PVE slot already has a disk. Remove it (`qm set <vmid> --delete <slot>`) or fix `disks.csv`. |
| File in `unmatched/` | The file name doesn't match `<name>-<slot>` in `disks.csv` (for example, the slot was changed after the export) |
| `disks are locked` (HTTP 409) | oVirt keeps a disk locked for a while after detaching it. The script waits (up to 5 min) and retries automatically. If it still fails, rerun `export` - unattached disks are picked up - or `restore` to roll back. |
| `disk … not accessible after 180s` | The datamover runs on a different host, or the hot-plug failed. Check oVirt events. |
| `DEAD` / `STALL?` in status | `DEAD`: the process is gone without a result; rerun export or import for that disk. `STALL?`: no data written for `STALL_SEC`; check the process and the storage. |
| `QUEUED` stays forever in status | The export session was lost (e.g. SSH disconnect without tmux) before that disk started. Rerun `export`; finished disks are skipped. |
| `STALE … already imported on PVE` | That disk on the PVE VM is from an outdated export. Remove it from the PVE VM (`qm set <vmid> --delete <slot>`, then delete the unused disk) before the next attempt; the import would otherwise HOLD on the occupied slot. |
| `nmbd` fails at boot | The network came up too late. Use `auto <if>` in `/etc/network/interfaces`. |
