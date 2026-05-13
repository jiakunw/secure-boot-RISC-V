package chipyard

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.devices.tilelink.{BootROMLocated}
import freechips.rocketchip.subsystem.{InSubsystem}
import freechips.rocketchip.util.{ResourceFileName}

class WithSecureBootROM extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) =>
    up(BootROMLocated(InSubsystem), site).map(_.copy(
      contentFileName = ResourceFileName("/testchipip/bootrom/bootrom.secureboot.rv64.img")
    ))
})

class SecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  new chipyard.WithSecureBootSPI(address = 0xF0002000L) ++
  new chipyard.WithSecureBootOTP() ++
  // INCREMENT 3: add Rollback Counter peripheral
  new chipyard.WithSecureBootRollback() ++
  // Status register: BootROM writes which verification stage failed; recovery firmware reads it
  new chipyard.WithSecureBootSR() ++
  // Ed25519 hardware verifier (sim-only BlackBox delegating to host MonoCypher)
  new chipyard.WithSecureBootEd25519() ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)