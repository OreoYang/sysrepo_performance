# Chicago OLT incremental-validation smoke test

Target: **QD Chicago SS2** OLT `chicago` @ `10.254.20.137` (EXS1610, SN S220Z31018422).

Install path on OLT: **`/root/chicago_smoke`** (overlay, survives reboot). Not `/tmp` — that is tmpfs.

## Quick start (on CNPC26044)

First time, or after you change these scripts:

```bash
cd ~/works/private/sysrepo_performance/scripts/scale_cfg/chicago_smoke
./deploy_to_olt.sh
```

Later tests — **no copy**, SSH and run on the OLT:

```bash
ssh root@10.254.20.137
cd /root/chicago_smoke/olt
export STAGE=provision ONU_SN=ZYXE53725310 PON=1 ONU_TEMPLATE=default-onu-template
./run_smoke_on_olt.sh
```

Or from the PC (still no scp):

```bash
STAGE=provision ./run_smoke_remote.sh
```

`STAGE=provision` = one ONU only. After that passes: `STAGE=full` (provision + service + negative, timed).

## What it tests

1. `SR_VALIDATE_INCREMENTAL=1` on netconf-polt / netopeer2 (and export the same on any `sysrepocfg` shell)
2. Keep **netconf-polt** and **protocol-handler** running for paired scale (`run_work_paired_remote.sh` starts them if down; it does not stop them)
2. First validate logs `Incremental YANG validation is enabled`
3. NETCONF `edit-config` provision + service (`netopeer2-cli` on OLT → `127.0.0.1:830`)
4. Negative edit (bad template) must fail
5. Times in `/root/chicago_smoke/work/times.csv`

## Files

| Path | Purpose |
|------|---------|
| `/root/chicago_smoke/olt/` | Scripts (keep) |
| `/root/chicago_smoke/work/` | Generated XML, NETCONF logs, timings |
| `env.chicago.sh` | Lab IPs, default SN / template |

## Manual SSH

```bash
ssh root@10.254.20.137
cd /root/chicago_smoke/olt
export STAGE=provision ONU_SN=ZYXE53725310 PON=1
./run_smoke_on_olt.sh
```
