# Chicago SS2 lab — source from other scripts in this directory.
# Wiki: QD-XGS-Chicago (SS2), skill: xpon-chicago-lab-debug

export CHICAGO_OLT_IP="${CHICAGO_OLT_IP:-10.254.20.137}"
export CHICAGO_OLT_USER="${CHICAGO_OLT_USER:-root}"
export CHICAGO_OLT_PASS="${CHICAGO_OLT_PASS:-}"   # empty password on lab OLT

export CHICAGO_EXC_IP="${CHICAGO_EXC_IP:-10.254.21.42}"

# Wiki PON1 ONU1. Running currently has 0 v-ani; PON1 dump-stats is gpon.
export ONU_SN="${ONU_SN:-ZYXE53725310}"
export PON="${PON:-1}"
# Wiki ONU1 is XGS (pon_ni=0) → chpart.1 / chpair.1. gpon uses chpart.gpon.N.
export PON_TECH="${PON_TECH:-xgs}"

# Chicago running only has this template (no Prod_XGS_*).
export ONU_TEMPLATE="${ONU_TEMPLATE:-default-onu-template}"

# Existing TD on Chicago (not largescale assured_10m / be_200m).
export TD_PROFILE="${TD_PROFILE:-gpon5m}"

# Persistent on OLT overlay (survives reboot). /tmp is tmpfs and is wiped.
export OLT_SMOKE_DIR="${OLT_SMOKE_DIR:-/root/chicago_smoke}"

# provision | service | negative | full
export STAGE="${STAGE:-provision}"
