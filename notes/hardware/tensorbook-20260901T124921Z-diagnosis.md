# M0 follow-up diagnosis

Generated 2026-09-01T12:49:23Z by capture-followup.sh
Kernel: Linux 7.0.0-30-generic x86_64

Deliberately free of serial numbers, MAC addresses and filesystem UUIDs, so this
file can be emailed or committed without redaction. The full raw capture is a
separate, much larger file that is NOT safe to share as-is.

--- hibernation / D29 ---
secure boot     : SecureBoot enabled
lockdown        : none [integrity] confidentiality
power states    : freeze mem
mem_sleep       : s2idle [deep]
nohibernate set : no
resume= set     : no
VERDICT         : CONFIRMED — kernel lockdown is active and is hiding 'disk'.
                  Secure Boot -> lockdown -> hibernation blocked. To have hibernation
                  on a stock Ubuntu kernel, Secure Boot must be disabled in firmware.

--- drive health / RAID0 fitness ---
/dev/nvme0n1
  health=PASSED  critical_warning=0x00
  pct_used=2%  spare=100%  media_errors=0
  power_on_hours=255  unsafe_shutdowns=65
  written=93,777,020 [48.0 TB]
/dev/nvme1n1
  health=PASSED  critical_warning=0x00
  pct_used=0%  spare=100%  media_errors=0
  power_on_hours=206  unsafe_shutdowns=66
  written=10,815,101 [5.53 TB]

--- displays / docking ---
Current connector state:
  card1-DP-1         disconnected  driver=i915
  card1-DP-2         disconnected  driver=i915
  card1-DP-3         disconnected  driver=i915
  card1-DP-4         disconnected  driver=i915
  card1-eDP-1        connected     driver=i915
thunderbolt (uuid/serial/key stripped — see the raw capture for full detail):
   o Shenzhen Lianfaxun Electronic Technology Co Ltd T4801
     |- type:          peripheral
     |- name:          T4801
     |- vendor:        Shenzhen Lianfaxun Electronic Technology Co Ltd
     |- generation:    USB4
     |- status:        disconnected
     |- authorized:    Wed 01 Jan 2020 12:00:58 AM UTC
     |- connected:     Wed 01 Jan 2020 12:00:58 AM UTC
     `- stored:        Mon 27 Jul 2026 01:14:47 PM UTC
        |- policy:     iommu
  

Dock test skipped (--skip-dock-test).

--- NVMe namespace format (settles sector geometry) ---
/dev/nvme0n1
    [6:5] : 0	Most significant 2 bits of Current LBA Format Selected
    [3:0] : 0	Least significant 4 bits of Current LBA Format Selected
  LBA Format  0 : Metadata Size: 0   bytes - Data Size: 512 bytes - Relative Performance: 0 Best (in use)
/dev/nvme1n1
    [6:5] : 0	Most significant 2 bits of Current LBA Format Selected
    [3:0] : 0	Least significant 4 bits of Current LBA Format Selected
  LBA Format  0 : Metadata Size: 0   bytes - Data Size: 512 bytes - Relative Performance: 0 Best (in use)

--- thermal and fan control (16.5 input) ---
hwmon chips      : AC0 acpi_fan acpitz BAT0 coretemp iwlwifi_1 nvme 
fan inputs       : 0
writable pwm     : 0
cooling devices  : 29
NOTE            : no fan telemetry or control exposed — this CONFIRMS the reported
                  'no fan control at all' on this chassis, rather than leaving it hearsay.
zone temps (m°C) : acpitz:27800 INT3400 Thermal:20000 SEN1:50 SEN2:50 SEN3:50 SEN4:50 TCPU:49000 iwlwifi_1:32000 x86_pkg_temp:52000 
cpufreq driver   : intel_pstate
