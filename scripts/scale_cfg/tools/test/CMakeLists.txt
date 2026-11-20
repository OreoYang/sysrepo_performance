# Mirror of xpon-apps/sr-validate/test/CMakeLists.txt — keep in sync when either side changes.
# Wired from sr-validate/CMakeLists.txt in xpon-apps (BUILD_TESTING). On a host-only checkout use run_ut.sh.

# Unit test of sr_validate_ds. The script builds its own sysrepo database in a temp directory from
# fixtures/vds-test.yang, so no OLT data and no external repository are needed. It only needs the sysrepo tools.
# When sysrepoctl or sysrepocfg cannot be found the test is reported as skipped (exit code 77).
#
#   ctest -R sr_validate_ds -V
#   cmake -DSYSREPOCTL=/path/sysrepoctl -DSYSREPOCFG=/path/sysrepocfg ...   (when not in PATH)

find_program(SYSREPOCTL sysrepoctl)
find_program(SYSREPOCFG sysrepocfg)

add_test(
    NAME sr_validate_ds
    COMMAND "${CMAKE_CURRENT_SOURCE_DIR}/sr_validate_ds_ctest.sh"
            "$<TARGET_FILE:sr_validate_ds>"
            "${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
)
set_tests_properties(sr_validate_ds PROPERTIES
    ENVIRONMENT "SYSREPOCTL=${SYSREPOCTL};SYSREPOCFG=${SYSREPOCFG}"
    SKIP_RETURN_CODE 77
)