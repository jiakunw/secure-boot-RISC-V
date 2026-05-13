package chipyard

import org.chipsalliance.cde.config.{Config}

/* Tampered SoC config for the test_tempering_version negative test.
 *
 * Identical to SecureBootConfig EXCEPT:
 *   1. SPI flash points at this test's tempered_flash_image/flash_image.hex
 *      (manifest with VERSION=1, signed correctly).
 *   2. Rollback counter peripheral is elaborated with resetValue=5 — i.e.
 *      the simulated chip behaves as though an earlier-installed newer
 *      firmware (V>=5) had already advanced the rollback counter. In real
 *      silicon this state would persist across reboots via eFuse / anti-
 *      fuse storage; we encode it directly into the reset value because
 *      Verilator-elaborated registers reset to 0 every sim run.
 *
 * BootROM Stage 4 (`check_rollback_counter`) reads counter=5, sees
 * manifest.version=1, and rejects: 1 < 5 → `enter_recovery(SR_ROLLBACK_COUNTER)`.
 *
 * Build produces: simulator-chipyard.harness-TamperedRollbackSecureBootConfig
 * which can coexist with the regular SecureBootConfig + TemperedSecureBootConfig
 * sim binaries.
 */
class TamperedRollbackSecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  new chipyard.WithSecureBootSPI(
    address      = 0xF0002000L,
    imageHexFile = "tempered_rollback_flash_image/flash_image.hex"
  ) ++
  new chipyard.WithSecureBootOTP() ++
  new chipyard.WithSecureBootRollback(
    address    = 0xF0001000L,
    resetValue = 5                    // simulate a prior boot bumping counter
  ) ++
  new chipyard.WithSecureBootSR() ++
  new chipyard.WithSecureBootEd25519() ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)
