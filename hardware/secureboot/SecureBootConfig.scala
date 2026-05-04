package chipyard

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.devices.tilelink.{BootROMLocated}
import freechips.rocketchip.subsystem.{InSubsystem, MaxXLen}
import chipyard.stage.phases.TargetDirKey

class WithSecureBootROM extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) =>
    up(BootROMLocated(InSubsystem), site).map(_.copy(
      contentFileName = s"${site(TargetDirKey)}/bootrom.secureboot.rv${site(MaxXLen)}.img"
    ))
})

class SecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  new chipyard.WithSecureBootSPI(address = 0xF0002000L) ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)
