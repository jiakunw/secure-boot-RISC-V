package chipyard

import org.chipsalliance.cde.config.{Config}

/* Tempered SoC config for the test_tempering_manifest_header negative test.
 *
 * Identical to SecureBootConfig EXCEPT the SPI flash is parameterized to
 * read from tempered_flash_image/flash_image.hex (relative to the
 * Verilator working directory $CHIPYARD_HOME/sims/verilator/) instead of
 * the regular flash_image/flash_image.hex. The hex file at that path is
 * placed there by this test's build.sh and contains a manifest with a
 * deliberately tampered magic.
 *
 * Build produces: simulator-chipyard.harness-TemperedSecureBootConfig
 * which can coexist with the regular simulator-chipyard.harness-SecureBootConfig.
 */
class TemperedSecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  new chipyard.WithSecureBootSPI(
    address      = 0xF0002000L,
    imageHexFile = "tempered_flash_image/flash_image.hex"
  ) ++
  new chipyard.WithSecureBootOTP() ++
  new chipyard.WithSecureBootRollback() ++
  new chipyard.WithSecureBootSR() ++
  new chipyard.WithSecureBootEd25519() ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)
