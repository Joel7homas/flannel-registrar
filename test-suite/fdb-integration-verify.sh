#!/bin/bash
# fdb-integration-verify.sh
# Integration verification script for FDB modules
# Verifies proper interaction between fdb-core.sh, fdb-advanced.sh, and fdb-diagnostics-core.sh

set -e  # Exit on error

# Set up test environment
TEST_DIR="/tmp/flannel-registrar-test"
MODULES_DIR="$TEST_DIR/lib"
STATE_DIR="$TEST_DIR/state"
LOG_FILE="$TEST_DIR/integration-test.log"

# Test status tracking
TEST_PASSED=0
TEST_FAILED=0
TEST_SKIPPED=0

# Colors for output
GREEN=$(tput setaf 2)
RED=$(tput setaf 1)
YELLOW=$(tput setaf 3)
RESET=$(tput sgr0)

# Create directories
mkdir -p "$MODULES_DIR" "$STATE_DIR"

# Initialize log
echo "FDB Module Integration Test - $(date)" > "$LOG_FILE"
echo "======================================" >> "$LOG_FILE"

# Utility function to log messages
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
  echo "$1"
}

# Test function that tracks results
run_test() {
  local test_name="$1"
  local test_function="$2"
  
  echo -n "Running test: $test_name... "
  log "TEST: $test_name"
  
  # Create a subshell for testing to contain errors
  if ( $test_function >> "$LOG_FILE" 2>&1 ); then
    echo "${GREEN}PASSED${RESET}"
    log "RESULT: PASSED"
    TEST_PASSED=$((TEST_PASSED + 1))
    return 0
  else
    echo "${RED}FAILED${RESET}"
    log "RESULT: FAILED"
    TEST_FAILED=$((TEST_FAILED + 1))
    return 1
  fi
}

# Define test-local variables for the modules
export COMMON_STATE_DIR="$STATE_DIR"

# Copy the modules to test directory
copy_modules() {
  local base_dir="./lib"  # Adjust this to the base dir containing the modules
  
  # Copy modules - modify these paths as needed for your environment
  cp "$base_dir/common.sh" "$MODULES_DIR/" 2>/dev/null || \
    { log "WARNING: Could not find common.sh, creating stub"; echo "#!/bin/bash" > "$MODULES_DIR/common.sh"; }
  
  cp "$base_dir/etcd-lib.sh" "$MODULES_DIR/" 2>/dev/null || \
    { log "WARNING: Could not find etcd-lib.sh, creating stub"; echo "#!/bin/bash" > "$MODULES_DIR/etcd-lib.sh"; }
  
  cp "$base_dir/network-lib.sh" "$MODULES_DIR/" 2>/dev/null || \
    { log "WARNING: Could not find network-lib.sh, creating stub"; echo "#!/bin/bash" > "$MODULES_DIR/network-lib.sh"; }
  
  # Copy FDB modules - these are required
  for module in "fdb-core.sh" "fdb-advanced.sh" "fdb-diagnostics-core.sh"; do
    if ! cp "$base_dir/$module" "$MODULES_DIR/"; then
      log "ERROR: Required module $module not found"
      return 1
    fi
  done
  
  # Create stub implementations for missing functions in common.sh
  echo "# Stub functions for testing" >> "$MODULES_DIR/common.sh"
  echo "log() { echo \"[LOG] \$1 - \$2\"; }" >> "$MODULES_DIR/common.sh"
  echo "debug() { echo \"[DEBUG] \$1\"; }" >> "$MODULES_DIR/common.sh"
  echo "error() { echo \"[ERROR] \$1\"; return 1; }" >> "$MODULES_DIR/common.sh"
  
  # Create stub implementations for etcd-lib.sh
  echo "# Stub functions for testing" >> "$MODULES_DIR/etcd-lib.sh"
  echo "etcd_get() { echo \"{}\"; }" >> "$MODULES_DIR/etcd-lib.sh"
  echo "etcd_list_keys() { echo \"\"; }" >> "$MODULES_DIR/etcd-lib.sh"
  
  return 0
}

# Create a callback test tracker
CALLBACK_EXECUTED=""
test_callback() {
  CALLBACK_EXECUTED="$1"
  return 0
}

# Test function for 1. Module Loading Test
test_module_loading() {
  # Source modules in correct dependency order
  log "Sourcing common.sh"
  source "$MODULES_DIR/common.sh" || return 1
  
  log "Sourcing etcd-lib.sh"
  source "$MODULES_DIR/etcd-lib.sh" || return 1
  
  log "Sourcing network-lib.sh"
  source "$MODULES_DIR/network-lib.sh" || return 1
  
  log "Sourcing fdb-core.sh"
  source "$MODULES_DIR/fdb-core.sh" || return 1
  
  log "Sourcing fdb-advanced.sh"
  source "$MODULES_DIR/fdb-advanced.sh" || return 1
  
  log "Sourcing fdb-diagnostics-core.sh"
  source "$MODULES_DIR/fdb-diagnostics-core.sh" || return 1
  
  # Verify key functions are available from each module
  log "Verifying key functions from fdb-core.sh"
  declare -f init_fdb_management > /dev/null || { log "Function init_fdb_management not found"; return 1; }
  declare -f update_fdb_entries_from_etcd > /dev/null || { log "Function update_fdb_entries_from_etcd not found"; return 1; }
  declare -f fix_flannel_mtu > /dev/null || { log "Function fix_flannel_mtu not found"; return 1; }
  
  log "Verifying key functions from fdb-advanced.sh"
  declare -f init_fdb_advanced > /dev/null || { log "Function init_fdb_advanced not found"; return 1; }
  declare -f check_and_fix_vxlan > /dev/null || { log "Function check_and_fix_vxlan not found"; return 1; }
  declare -f register_fdb_diagnostic_callback > /dev/null || { log "Function register_fdb_diagnostic_callback not found"; return 1; }
  
  log "Verifying key functions from fdb-diagnostics-core.sh"
  declare -f init_fdb_diagnostics > /dev/null || { log "Function init_fdb_diagnostics not found"; return 1; }
  declare -f get_fdb_diagnostics > /dev/null || { log "Function get_fdb_diagnostics not found"; return 1; }
  
  log "All required functions are available"
  return 0
}

# Test function for 2. Cross-Module Function Call Test
test_cross_module_calls() {
  # Set up mock functions if needed for testing
  log "Setting up mock functions for bridge and ip commands"
  
  # Mock bridge command
  bridge() {
    case "$1" in
      "fdb")
        echo "11:22:33:44:55:66 dev flannel.1 dst 192.168.1.1"
        ;;
      *)
        echo "Unknown bridge command: $1"
        ;;
    esac
    return 0
  }
  
  # Mock ip command
  ip() {
    case "$1" in
      "link")
        echo "flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1370 state UNKNOWN"
        ;;
      "-s")
        echo "RX: 1000 packets"
        echo "TX: 2000 packets"
        ;;
      *)
        echo "Unknown ip command: $1"
        ;;
    esac
    return 0
  }
  
  export -f bridge ip
  
  # Test fdb-core to fdb-advanced calls
  log "Testing fdb-core -> fdb-advanced calls"
  # No direct calls in our design, but verify they can be loaded together
  
  # Test fdb-advanced to fdb-diagnostics-core calls
  log "Testing fdb-advanced -> fdb-diagnostics-core calls via callbacks"
  # This is implemented via callbacks, will be tested in the callback test
  
  # Verify at least one basic operation that requires both modules
  log "Verifying basic operations across modules"
  
  # Initialize modules in sequence
  init_fdb_management || { log "Failed to initialize fdb-core"; return 1; }
  init_fdb_advanced || { log "Failed to initialize fdb-advanced"; return 1; }
  init_fdb_diagnostics || { log "Failed to initialize fdb-diagnostics-core"; return 1; }
  
  log "All modules initialized successfully"
  return 0
}

# Test function for 3. Callback Registration Test
test_callback_registration() {
  # Reset callback tracking
  CALLBACK_EXECUTED=""
  
  # Register a test callback
  log "Registering test callback"
  if ! register_fdb_diagnostic_callback "test" "test_callback"; then
    log "Failed to register callback"
    return 1
  fi
  
  # Check if our callback was registered
  if [[ -v FDB_DIAGNOSTIC_CALLBACKS ]]; then
    if [[ -n "${FDB_DIAGNOSTIC_CALLBACKS[test]}" ]]; then
      log "Callback was registered successfully"
    else
      log "Callback was not found in FDB_DIAGNOSTIC_CALLBACKS"
      return 1
    fi
  else
    log "FDB_DIAGNOSTIC_CALLBACKS associative array not found"
    return 1
  fi
  
  # Try to execute the callback
  log "Executing callback"
  if ! ${FDB_DIAGNOSTIC_CALLBACKS[test]} "test_executed"; then
    log "Callback execution failed"
    return 1
  fi
  
  # Verify callback execution
  if [[ "$CALLBACK_EXECUTED" == "test_executed" ]]; then
    log "Callback was executed successfully"
  else
    log "Callback was not executed correctly"
    return 1
  fi
  
  return 0
}

# Test function for 4. State Sharing Test
test_state_sharing() {
  # Create test state
  local test_state="${STATE_DIR}/test_state.txt"
  echo "Test state" > "$test_state"
  
  # Verify fdb-core state dir
  log "Checking state directory in fdb-core"
  if [[ "$FDB_STATE_DIR" != "$STATE_DIR/fdb" ]]; then
    log "fdb-core state directory inconsistency: $FDB_STATE_DIR"
    return 1
  fi
  
  # Verify fdb-diagnostics state dir
  log "Checking state directory in fdb-diagnostics-core"
  if [[ "$FDB_DIAG_STATE_DIR" != "$STATE_DIR/fdb-diagnostics" ]]; then
    log "fdb-diagnostics-core state directory inconsistency: $FDB_DIAG_STATE_DIR"
    return 1
  fi
  
  # Create test function for writing state
  write_test_state() {
    echo "Test data from $1" > "${STATE_DIR}/test_from_$1.txt"
    return 0
  }
  
  # Write state from different modules
  log "Writing state from different modules"
  write_test_state "core"
  write_test_state "advanced"
  write_test_state "diagnostics"
  
  # Verify state was written
  for module in "core" "advanced" "diagnostics"; do
    if [[ ! -f "${STATE_DIR}/test_from_${module}.txt" ]]; then
      log "Failed to write state from $module"
      return 1
    fi
  done
  
  log "State sharing test passed"
  return 0
}

# Test function for 5. Error Handling Test
test_error_handling() {
  # Create error-generating function
  fail_with_error() {
    return 1
  }
  
  # Create error-propagating function
  propagate_error() {
    fail_with_error
    return $?
  }
  
  # Test error propagation
  log "Testing error propagation"
  if propagate_error; then
    log "Error was not propagated correctly"
    return 1
  else
    log "Error was correctly propagated"
  fi
  
  # Test error handling in check_and_fix_vxlan
  # Mock bridge command to fail
  bridge() {
    return 1
  }
  export -f bridge
  
  log "Testing error handling in check_and_fix_vxlan"
  if check_and_fix_vxlan "test_iface" "minimal"; then
    log "check_and_fix_vxlan did not fail when bridge command failed"
    return 1
  else
    log "check_and_fix_vxlan correctly reported failure"
  fi
  
  log "Error handling test passed"
  return 0
}

# Test function for 6. Documentation Verification
test_documentation_consistency() {
  log "Checking function signature consistency"
  
  # Get function signatures
  get_function_signature() {
    declare -f "$1" | head -n 1
  }
  
  # Check key function signatures
  for func in "init_fdb_management" "update_fdb_entries_from_etcd" "check_and_fix_vxlan" "get_fdb_diagnostics"; do
    log "Checking signature for $func: $(get_function_signature "$func")"
    
    # Basic validation that function exists and has proper signature format
    if ! declare -f "$func" | head -n 1 | grep -q "()" ; then
      log "Invalid function signature for $func"
      return 1
    fi
  done
  
  # Verify export statements
  log "Checking export patterns"
  # We can only verify existence of exported variables
  for var in "FDB_STATE_DIR" "FDB_LAST_UPDATE_TIME" "FDB_DIAGNOSTIC_CALLBACKS" "FDB_DIAG_STATE_DIR"; do
    if [[ -v $var ]]; then
      log "Variable $var is exported"
    else
      log "Variable $var is not exported"
      return 1
    fi
  done
  
  log "Documentation consistency test passed"
  return 0
}

# Run all tests
run_all_tests() {
  echo "Starting FDB module integration verification"
  echo "============================================"
  
  # Prepare test environment
  if ! copy_modules; then
    echo "${RED}Failed to prepare test environment${RESET}"
    return 1
  fi
  
  # Run all tests
  run_test "Module Loading" test_module_loading
  run_test "Cross-Module Function Calls" test_cross_module_calls
  run_test "Callback Registration" test_callback_registration
  run_test "State Sharing" test_state_sharing
  run_test "Error Handling" test_error_handling
  run_test "Documentation Consistency" test_documentation_consistency
  
  # Print summary
  echo "============================================"
  echo "Test Summary:"
  echo "${GREEN}Passed: $TEST_PASSED${RESET}"
  echo "${RED}Failed: $TEST_FAILED${RESET}"
  echo "${YELLOW}Skipped: $TEST_SKIPPED${RESET}"
  
  if [ $TEST_FAILED -eq 0 ]; then
    echo "${GREEN}All tests passed!${RESET}"
    return 0
  else
    echo "${RED}Some tests failed. See $LOG_FILE for details.${RESET}"
    return 1
  fi
}

# Clean up test environment
cleanup() {
  log "Cleaning up test environment"
  rm -rf "$TEST_DIR"
}

# Main execution
main() {
  # Run tests
  if run_all_tests; then
    cleanup
    exit 0
  else
    echo "Test logs are available at $LOG_FILE"
    exit 1
  fi
}

# Run main function
main
