package chipyard

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.devices.tilelink.{BootROMLocated, BootROMParams}
import freechips.rocketchip.subsystem.{InSubsystem}
import freechips.rocketchip.util.{ResourceFileName}

class WithSecureBootROM extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) =>
    up(BootROMLocated(InSubsystem), site).map(_.copy(
      contentFileName = ResourceFileName("/testchipip/bootrom/bootrom.secureboot.rv64.img")
    ))
})

class SecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++             // ← 改这里
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)