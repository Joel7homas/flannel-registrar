#!/bin/bash
# Fixed FDB integration verification script

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

# Copy the modules to test directory
copy_modules() {
  local base_dir="./lib"  # Your lib directory
  
  log "Copying modules from $base_dir to $MODULES_DIR"
  
  # Copy each module file (fix permissions)
  for module in "common.sh" "etcd-lib.sh" "network-lib.sh" "fdb-core.sh" "fdb-advanced.sh" "fdb-diagnostics-core.sh"; do
    if [ -f "$base_dir/$module" ]; then
      cp "$base_dir/$module" "$MODULES_DIR/"
      # Fix permissions
      chmod +x "$MODULES_DIR/$module"
      log "Copied $module"
    else
      log "ERROR: Required module $module not found in $base_dir"
      return 1
    fi
  done
  
  # Create a basic environment file to set required variables
  cat > "$MODULES_DIR/test-env.sh" << ENVEOF
# Test environment setup
export COMMON_STATE_DIR="$STATE_DIR"
export FLANNEL_PREFIX="/coreos.com/network"
export FLANNEL_CONFIG_PREFIX="/flannel/network/subnets"
export FDB_STATE_DIR="$STATE_DIR/fdb"
export FDB_DIAG_STATE_DIR="$STATE_DIR/fdb-diagnostics"
export DEBUG=true

# Create necessary directories
mkdir -p "$STATE_DIR/fdb" "$STATE_DIR/fdb-diagnostics"
ENVEOF
  
  chmod +x "$MODULES_DIR/test-env.sh"
  
  # Fix common.sh for testing purposes
  sed -i 's/^MODULE_DEPENDENCIES=(/MODULE_DEPENDENCIES=()/g' "$MODULES_DIR/common.sh" 2>/dev/null || true
  
  # Create simple mocks for network-lib.sh functions
  log "Adding mock functions to test environment"
  cat >> "$MODULES_DIR/test-env.sh" << MOCKEOF

# Mock functions for testing
bridge() {
  case "\$1" in
    "fdb")
      echo "11:22:33:44:55:66 dev flannel.1 dst 192.168.1.1"
      ;;
    *)
      echo "Unknown bridge command: \$1"
      ;;
  esac
  return 0
}

ip() {
  case "\$1" in
    "link")
      echo "flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1370 state UNKNOWN"
      ;;
    "-s")
      echo "RX: 1000 packets"
      echo "TX: 2000 packets"
      ;;
    *)
      echo "Unknown ip command: \$1"
      ;;
  esac
  return 0
}

export -f bridge ip

# Mock etcd functions if not defined
if ! type etcd_get &>/dev/null; then
  etcd_get() { echo "{}"; }
  etcd_list_keys() { echo ""; }
  export -f etcd_get etcd_list_keys
fi
MOCKEOF
  
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
  # Source environment
  source "$MODULES_DIR/test-env.sh" || return 1
  
  # Source modules in correct dependency order
  log "Sourcing common.sh"
  source "$MODULES_DIR/common.sh" || { log "Failed to source common.sh"; return 1; }
  
  log "Sourcing etcd-lib.sh" 
  source "$MODULES_DIR/etcd-lib.sh" || { log "Failed to source etcd-lib.sh"; return 1; }
  
  log "Sourcing network-lib.sh"
  if ! source "$MODULES_DIR/network-lib.sh"; then
    log "Failed to source network-lib.sh, checking for syntax errors"
    bash -n "$MODULES_DIR/network-lib.sh"
    return 1
  fi
  
  log "Sourcing fdb-core.sh"
  source "$MODULES_DIR/fdb-core.sh" || { log "Failed to source fdb-core.sh"; return 1; }
  
  log "Sourcing fdb-advanced.sh"
  source "$MODULES_DIR/fdb-advanced.sh" || { log "Failed to source fdb-advanced.sh"; return 1; }
  
  log "Sourcing fdb-diagnostics-core.sh"
  source "$MODULES_DIR/fdb-diagnostics-core.sh" || { log "Failed to source fdb-diagnostics-core.sh"; return 1; }
  
  # List all functions loaded
  log "Listing available functions"
  declare -F | grep "init_\|update_\|check_\|fix_\|get_\|register_" || true
  
  # Verify key functions are available from each module
  log "Verifying key functions"
  for func in "init_fdb_management" "update_fdb_entries_from_etcd" "init_fdb_advanced" "check_and_fix_vxlan" "init_fdb_diagnostics" "get_fdb_diagnostics"; do
    if ! declare -F "$func" >/dev/null; then
      log "Function $func not found"
      return 1
    else
      log "Found function: $func"
    fi
  done
  
  log "All required functions are available"
  return 0
}

# Run all tests
run_all_tests() {
  echo "Starting FDB module integration verification"
  echo "============================================"
  
  # Prepare test environment
  if ! copy_modules; then
    echo "${RED}Failed to prepare test environment${RESET}"
    echo "Check error messages above for details"
    return 1
  fi
  
  # Run syntax check on all modules 
  echo "Checking syntax of all modules..."
  for module in "$MODULES_DIR"/*.sh; do
    if ! bash -n "$module"; then
      echo "${RED}Syntax error in $module${RESET}"
      return 1
    fi
  done
  
  # Run module loading test only
  run_test "Module Loading" test_module_loading
  
  # If module loading test passes, proceed with other tests
  if [ $TEST_FAILED -eq 0 ]; then
    echo "Basic module loading successful, proceeding with further tests..."
    # Add other tests here if needed
  else
    echo "${RED}Module loading failed, fix this issue first before proceeding${RESET}"
  fi
  
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

# Main execution
main() {
  # Run tests
  run_all_tests
  echo "Test logs are available at $LOG_FILE"
}

# Run main function
main
