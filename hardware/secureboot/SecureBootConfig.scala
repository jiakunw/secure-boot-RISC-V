package chipyard

import org.chipsalliance.cde.config.{Config}
import freechips.rocketchip.devices.tilelink.{BootROMLocated}
import freechips.rocketchip.subsystem.{InSubsystem, MaxXLen}
import freechips.rocketchip.util.SystemFileName
import chipyard.stage.phases.TargetDirKey

class WithSecureBootROM extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) =>
    up(BootROMLocated(InSubsystem), site).map(_.copy(
      contentFileName = SystemFileName(s"${site(TargetDirKey)}/bootrom.secureboot.rv${site(MaxXLen)}.img")
    ))
})

class SecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  // BISECT: temporarily disabled OTP and Rollback Config keys to match
  // the 84e057b "kernel started" working state. If kernel prints with
  // these off, the issue is in OTP/Rollback Chisel integration.
  // new chipyard.WithSecureBootOTP() ++
  // new chipyard.WithSecureBootRollback() ++
  new chipyard.WithSecureBootSPI(address = 0xF0002000L) ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)
