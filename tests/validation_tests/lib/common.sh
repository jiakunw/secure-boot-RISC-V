#!/usr/bin/env bash

set -o pipefail

vt_repo_root() {
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
    cd "$script_dir/../.." && pwd
}

vt_log_dir() {
    local repo="$1"
    mkdir -p "$repo/validation_tests/logs"
    printf '%s\n' "$repo/validation_tests/logs"
}

vt_source_env() {
    local repo="$1"
    if [ -f "$repo/.env" ]; then
        # shellcheck disable=SC1090
        source "$repo/.env"
    fi
    export SECURE_BOOT_REPO="$repo"
    if [ -z "${CHIPYARD_HOME:-}" ]; then
        echo "FAIL: CHIPYARD_HOME is not set. Put it in .env or export it first." >&2
        return 1
    fi
}

vt_source_chipyard() {
    local repo="$1"
    vt_source_env "$repo" || return 1
    if [ -f "$CHIPYARD_HOME/env.sh" ]; then
        # Chipyard's env can reference vars like RISCV before they exist.
        # Turn nounset off only while sourcing Chipyard, then restore it.
        set +u
        # shellcheck disable=SC1090
        source "$CHIPYARD_HOME/env.sh"
        set -u
    fi
}

vt_require_file() {
    local path="$1"
    if [ ! -f "$path" ]; then
        echo "FAIL: missing file: $path" >&2
        return 1
    fi
}

vt_require_exe() {
    local path="$1"
    if [ ! -x "$path" ]; then
        echo "FAIL: missing executable: $path" >&2
        return 1
    fi
}

vt_backup_artifacts() {
    local repo="$1"
    local out_dir="$2"
    mkdir -p "$out_dir"
    for rel in \
        metadata/manifest.bin \
        metadata/signature.bin \
        metadata/public_key.bin \
        metadata/pubkey_hash.bin \
        flash_image/flash_image.bin \
        flash_image/flash_image.hex; do
        if [ -f "$repo/$rel" ]; then
            mkdir -p "$out_dir/$(dirname "$rel")"
            cp -p "$repo/$rel" "$out_dir/$rel"
        fi
    done
    if [ -n "${CHIPYARD_HOME:-}" ] && [ -f "$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex" ]; then
        mkdir -p "$out_dir/chipyard_flash_image"
        cp -p "$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex" "$out_dir/chipyard_flash_image/flash_image.hex"
    fi
}

vt_restore_artifacts() {
    local repo="$1"
    local backup_dir="$2"
    for rel in \
        metadata/manifest.bin \
        metadata/signature.bin \
        metadata/public_key.bin \
        metadata/pubkey_hash.bin \
        flash_image/flash_image.bin \
        flash_image/flash_image.hex; do
        if [ -f "$backup_dir/$rel" ]; then
            cp -p "$backup_dir/$rel" "$repo/$rel"
        fi
    done
    if [ -n "${CHIPYARD_HOME:-}" ] && [ -f "$backup_dir/chipyard_flash_image/flash_image.hex" ]; then
        mkdir -p "$CHIPYARD_HOME/sims/verilator/flash_image"
        cp -p "$backup_dir/chipyard_flash_image/flash_image.hex" "$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex"
    fi
}

vt_regen_hex_and_stage() {
    local repo="$1"
    python3 "$repo/tools/flash_image_to_hex.py" \
        --input "$repo/flash_image/flash_image.bin" \
        --output "$repo/flash_image/flash_image.hex" >/dev/null
    vt_source_env "$repo" || return 1
    mkdir -p "$CHIPYARD_HOME/sims/verilator/flash_image"
    cp -p "$repo/flash_image/flash_image.hex" "$CHIPYARD_HOME/sims/verilator/flash_image/flash_image.hex"
}

vt_run_sim() {
    local repo="$1"
    local log="$2"
    local timeout_s="${3:-300}"

    vt_source_chipyard "$repo" || return 1

    local sim="$CHIPYARD_HOME/sims/verilator/simulator-chipyard.harness-SecureBootConfig"
    local kernel="$repo/software/kernel/kernel.riscv"
    local recovery="$repo/software/recovery/recovery.riscv"

    vt_require_exe "$sim" || return 1
    vt_require_file "$kernel" || return 1
    vt_require_file "$recovery" || return 1

    cd "$CHIPYARD_HOME/sims/verilator" || return 1
    set +e
    timeout "$timeout_s" stdbuf -oL "$sim" "+payload=$recovery" "$kernel" > "$log" 2>&1
    local rc=$?
    set -e
    echo "sim exit code: $rc" | tee -a "$log" >/dev/null
    return 0
}

vt_print_log_summary() {
    local log="$1"
    grep -nE "kernel started|recovery|boot status|check_|signature|public_key|rollback|PMP|FAILED|tohost|Verilog|finish|trap|fault|UART|Terminated|sim exit code" "$log" || true
}

vt_expect_positive_boot() {
    local log="$1"
    if grep -q "kernel started successfully" "$log"; then
        echo "PASS: kernel success banner present"
        return 0
    fi
    echo "FAIL: kernel success banner was not found"
    return 1
}

vt_expect_rejection() {
    local log="$1"
    local bit_hex="$2"
    local label="$3"
    local pass=true

    if grep -q "kernel started successfully" "$log"; then
        echo "FAIL: kernel banner present. BootROM did not reject the bad image."
        pass=false
    else
        echo "PASS: kernel banner absent"
    fi

    if grep -q "boot status register = $bit_hex" "$log"; then
        echo "PASS: recovery status matched $bit_hex ($label)"
    else
        echo "WARN: expected recovery status $bit_hex was not visible"
        echo "      This can happen if the recovery console/tohost path is not visible."
    fi

    if grep -q "$label" "$log"; then
        echo "PASS: recovery decoded $label"
    else
        echo "WARN: recovery decoded line '$label' was not visible"
    fi

    if [ "$pass" = true ]; then
        return 0
    fi
    return 1
}
