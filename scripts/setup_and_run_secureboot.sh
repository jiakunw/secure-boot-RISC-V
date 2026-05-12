#!/usr/bin/env bash
set -euo pipefail

# secure boot setup + rebuild + positive run helper
#
# this script assumes:
#   - the secure-boot repo already exists
#   - chipyard already exists
#   - chipyard/env.sh sets the riscv toolchain and verilator env
#
# it installs normal ubuntu host tools when possible, checks the project
# environment, runs integration, checks freshness, rebuilds SecureBootConfig,
# and runs the positive boot.

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "ERROR: do not source this script."
  echo "Run it with:"
  echo "  bash scripts/setup_and_run_secureboot.sh"
  return 1
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CHIPYARD_HOME="${CHIPYARD_HOME:-/root/chipyard}"
CONFIG="${CONFIG:-SecureBootConfig}"
RUN_SIM="${RUN_SIM:-1}"
RUN_APT_INSTALL="${RUN_APT_INSTALL:-1}"
SIM_TIMEOUT="${SIM_TIMEOUT:-300}"

BOOTROM_RESOURCE="$CHIPYARD_HOME/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img"
VERILATOR_DIR="$CHIPYARD_HOME/sims/verilator"
SIM_BIN="$VERILATOR_DIR/simulator-chipyard.harness-$CONFIG"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

note() {
  echo ""
  echo "[$1] $2"
}

have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_host_tools_if_possible() {
  if [ "$RUN_APT_INSTALL" != "1" ]; then
    echo "Skipping apt install because RUN_APT_INSTALL=$RUN_APT_INSTALL"
    return
  fi

  if ! have_cmd apt-get; then
    echo "apt-get not found; skipping host package install"
    return
  fi

  local SUDO=""
  if [ "$(id -u)" -ne 0 ]; then
    if have_cmd sudo; then
      SUDO="sudo"
    else
      echo "Not root and sudo not found; skipping host package install"
      return
    fi
  fi

  echo "Installing/checking host tools through apt..."
  $SUDO apt-get update
  $SUDO apt-get install -y \
    bash \
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    git \
    make \
    cmake \
    gcc \
    g++ \
    python3 \
    python3-pip \
    ca-certificates \
    file \
    dos2unix
}

source_chipyard_env() {
  [ -d "$CHIPYARD_HOME" ] || die "CHIPYARD_HOME does not exist: $CHIPYARD_HOME"
  [ -f "$CHIPYARD_HOME/env.sh" ] || die "missing Chipyard env.sh at $CHIPYARD_HOME/env.sh"

  # Chipyard/conda scripts can reference unset vars.
  # Keep strict mode for our script, but relax nounset only while sourcing.
  set +u
  # shellcheck disable=SC1090
  source "$CHIPYARD_HOME/env.sh"
  set -u

  export CHIPYARD_HOME
  export SECURE_BOOT_REPO="$REPO"
}

check_required_files() {
  [ -f "$REPO/scripts/integrate_to_chipyard.sh" ] || die "missing scripts/integrate_to_chipyard.sh"
  [ -f "$REPO/scripts/check_secureboot_freshness.sh" ] || die "missing scripts/check_secureboot_freshness.sh"

  [ -f "$REPO/software/bootrom/bootrom.c" ] || die "missing software/bootrom/bootrom.c"
  [ -f "$REPO/software/bootrom/bootrom.S" ] || die "missing software/bootrom/bootrom.S"
  [ -f "$REPO/software/bootrom/Makefile" ] || die "missing software/bootrom/Makefile"

  [ -f "$REPO/software/kernel/kernel.c" ] || die "missing software/kernel/kernel.c"
  [ -f "$REPO/software/recovery/recovery.c" ] || die "missing software/recovery/recovery.c"

  [ -f "$REPO/metadata/public_key.bin" ] || die "missing metadata/public_key.bin"
  [ -f "$REPO/metadata/private_key.bin" ] || die "missing metadata/private_key.bin"
  [ -f "$REPO/metadata/pubkey_hash.bin" ] || die "missing metadata/pubkey_hash.bin"

  [ -f "$REPO/hardware/ed25519/rtl/ed25519_verifier.scala" ] || die "missing Ed verifier scala"
  [ -f "$REPO/hardware/ed25519/vsrc/Ed25519VerifierSim.sv" ] || die "missing Ed verifier sv"
  [ -f "$REPO/tools/verify_ed25519_from_files.py" ] || die "missing host Ed verifier script"
}

fix_script_line_endings() {
  find "$REPO/scripts" -type f -name "*.sh" -print0 | while IFS= read -r -d '' f; do
    sed -i 's/\r$//' "$f"
    chmod +x "$f"
  done
}

check_architecture_contract() {
  echo "Checking final Ed verifier peripheral contract..."

  if grep -q "ed25519_check\|ed25519.h" "$REPO/software/bootrom/bootrom.c"; then
    die "BootROM still references software ed25519 path; expected Ed verifier peripheral path"
  fi

  grep -q "ED25519_VERIFY_BASE" "$REPO/software/bootrom/bootrom.c" || die "BootROM missing ED25519_VERIFY_BASE"
  grep -q "ED25519_STATUS" "$REPO/software/bootrom/bootrom.c" || die "BootROM missing ED25519_STATUS"
  grep -q "check_manifest_signature" "$REPO/software/bootrom/bootrom.c" || die "BootROM missing check_manifest_signature"

  if grep -q "monocypher.o\|ed25519.o\|secureboot_ed25519_lut" "$REPO/software/bootrom/Makefile"; then
    die "BootROM Makefile still depends on old software Ed/LUT path"
  fi

  grep -q "WithSecureBootEd25519" "$REPO/hardware/secureboot/SecureBootConfig.scala" || die "SecureBootConfig missing WithSecureBootEd25519"

  if grep -q "generate_ed25519_lut\|secureboot_ed25519_lut\|P_W_WIDTH\|B_W_WIDTH" "$REPO/scripts/integrate_to_chipyard.sh"; then
    die "integration script still contains old BootROM software-Ed LUT logic"
  fi
}

check_tools() {
  have_cmd python3 || die "python3 not found"
  have_cmd gcc || die "host gcc not found"
  have_cmd make || die "make not found"
  have_cmd cmake || die "cmake not found"
  have_cmd git || die "git not found"

  have_cmd riscv64-unknown-elf-gcc || die "riscv64-unknown-elf-gcc not found after sourcing Chipyard env"
}

run_integration() {
  note "1" "Running repo integration script"
  cd "$REPO"
  bash "$REPO/scripts/integrate_to_chipyard.sh"
}

run_freshness() {
  note "2" "Running freshness checks"
  cd "$REPO"
  CHIPYARD_HOME="$CHIPYARD_HOME" "$REPO/scripts/check_secureboot_freshness.sh"
}

check_generated_artifacts() {
  note "3" "Checking generated artifacts"

  [ -f "$REPO/software/bootrom/bootrom.img" ] || die "missing bootrom.img"
  [ -f "$REPO/software/kernel/kernel.riscv" ] || die "missing kernel.riscv"
  [ -f "$REPO/software/kernel/kernel.bin" ] || die "missing kernel.bin"
  [ -f "$REPO/software/recovery/recovery.riscv" ] || die "missing recovery.riscv"
  [ -f "$REPO/metadata/manifest.bin" ] || die "missing manifest.bin"
  [ -f "$REPO/metadata/signature.bin" ] || die "missing signature.bin"
  [ -f "$REPO/flash_image/flash_image.bin" ] || die "missing flash_image.bin"
  [ -f "$REPO/flash_image/flash_image.hex" ] || die "missing flash_image.hex"
  [ -f "$BOOTROM_RESOURCE" ] || die "missing staged BootROM resource"
  [ -f "$VERILATOR_DIR/flash_image/flash_image.hex" ] || die "missing staged Verilator flash"

  echo "BootROM image size:"
  stat -c%s "$REPO/software/bootrom/bootrom.img"

  echo "Kernel ELF:"
  ls -l "$REPO/software/kernel/kernel.riscv"

  echo "Recovery ELF:"
  ls -l "$REPO/software/recovery/recovery.riscv"
}

build_simulator() {
  note "4" "Rebuilding Chipyard simulator for $CONFIG"
  cd "$VERILATOR_DIR"

  rm -rf "generated-src/chipyard.harness.TestHarness.$CONFIG"
  rm -f "$CHIPYARD_HOME/.classpath_cache/chipyard.jar"

  make CONFIG="$CONFIG" -j"$(nproc)"
}

run_positive_sim() {
  note "5" "Running positive secure boot simulation"

  cd "$VERILATOR_DIR"
  [ -x "$SIM_BIN" ] || die "simulator binary missing or not executable: $SIM_BIN"

  set +e
  timeout "$SIM_TIMEOUT" stdbuf -oL "$SIM_BIN" \
    +payload="$REPO/software/recovery/recovery.riscv" \
    "$REPO/software/kernel/kernel.riscv" \
    2>&1 | tee /tmp/secureboot_positive_setup_run.log

  local rc=${PIPESTATUS[0]}
  set -e

  echo "sim exit code: $rc"

  grep -nE "kernel started|recovery|boot status|signature|public_key|rollback|PMP|FAILED|tohost|Verilog|finish|trap|fault|UART|Terminated" \
    /tmp/secureboot_positive_setup_run.log || true

  if [ "$rc" -ne 0 ]; then
    die "positive secure boot simulation failed with exit code $rc"
  fi

  grep -q "kernel started successfully rocket" /tmp/secureboot_positive_setup_run.log || \
    die "kernel success line not found"

  echo ""
  echo "SECURE BOOT POSITIVE RUN PASSED"
}

main() {
  echo "============================================================"
  echo "Secure Boot setup/rebuild/run"
  echo "repo:        $REPO"
  echo "chipyard:    $CHIPYARD_HOME"
  echo "config:      $CONFIG"
  echo "run sim:     $RUN_SIM"
  echo "============================================================"

  install_host_tools_if_possible
  source_chipyard_env
  check_tools
  check_required_files
  fix_script_line_endings
  check_architecture_contract

  run_integration
  run_freshness
  check_generated_artifacts
  build_simulator

  if [ "$RUN_SIM" = "1" ]; then
    run_positive_sim
  else
    echo "RUN_SIM=$RUN_SIM, skipping simulation run"
  fi

  echo ""
  echo "Done."
}

main "$@"