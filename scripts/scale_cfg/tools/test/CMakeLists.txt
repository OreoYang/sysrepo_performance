# Mirror of xpon-apps/sr-validate/test/CMakeLists.txt — keep in sync when either side changes.
# Wired from sr-validate/CMakeLists.txt in xpon-apps (BUILD_TESTING). On a host-only checkout use run_ut.sh.

# Unit test of sr_validate_ds (Python unittest). The test builds its own sysrepo database in a temp directory from
# fixtures/vds-test.yang, so no OLT data and no external repository are needed. It only needs python3 and the sysrepo
# tools. Without python3 the test is not registered; without sysrepoctl or sysrepocfg it is reported as skipped (77).
#
#   ctest -R sr_validate_ds -V
#   cmake -DSYSREPOCTL=/path/sysrepoctl -DSYSREPOCFG=/path/sysrepocfg ...   (when not in PATH)

find_package(Python3 COMPONENTS Interpreter)
find_program(SYSREPOCTL sysrepoctl)
find_program(SYSREPOCFG sysrepocfg)

if(Python3_Interpreter_FOUND)
add_test(
    NAME sr_validate_ds
    COMMAND "${Python3_EXECUTABLE}" "${CMAKE_CURRENT_SOURCE_DIR}/sr_validate_ds_test.py"
            "$<TARGET_FILE:sr_validate_ds>"
            "${CMAKE_CURRENT_SOURCE_DIR}/fixtures"
)
set_tests_properties(sr_validate_ds PROPERTIES
    ENVIRONMENT "SYSREPOCTL=${SYSREPOCTL};SYSREPOCFG=${SYSREPOCFG}"
    SKIP_RETURN_CODE 77
)
else()
    message(STATUS "python3 not found, sr_validate_ds unit test not registered")
endif()
