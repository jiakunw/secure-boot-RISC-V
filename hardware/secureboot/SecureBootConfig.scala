package chipyard

import org.chipsalliance.cde.config.Config
import freechips.rocketchip.devices.tilelink.BootROMLocated
import freechips.rocketchip.subsystem.InSubsystem

object SecureBootPaths {
  val repoRoot: String =
    sys.env.getOrElse(
      "SECURE_BOOT_REPO",
      "/mnt/c/Users/lbarc/Downloads/secure-boot-RISC-V-kernel-start-fixed/secure-boot-RISC-V"
    )

  val chipyardRoot: String =
    sys.env.getOrElse(
      "CHIPYARD_HOME",
      "/root/chipyard"
    )

  val bootromImg: String =
    s"$chipyardRoot/generators/testchipip/src/main/resources/testchipip/bootrom/bootrom.secureboot.rv64.img"

  val pubkeyHash: String =
    s"$repoRoot/metadata/pubkey_hash.bin"

  val flashHex: String =
    s"$repoRoot/flash_image/flash_image.hex"
}

class WithSecureBootROM extends Config((site, here, up) => {
  case BootROMLocated(InSubsystem) =>
    up(BootROMLocated(InSubsystem), site).map(_.copy(
      contentFileName = SecureBootPaths.bootromImg
    ))
})

class SecureBootConfig extends Config(
  new chipyard.WithSecureBootROM ++
  new chipyard.WithSecureBootSPI(
    address = 0xF0002000L,
    imageHexFile = SecureBootPaths.flashHex
  ) ++
  new chipyard.WithSecureBootOTP(
    hashPath = SecureBootPaths.pubkeyHash
  ) ++
  new chipyard.WithSecureBootRollback() ++
  new chipyard.WithSecureBootEd25519(
    address = 0xF0004000L
  ) ++
  new chipyard.WithSecureBootSR() ++
  new freechips.rocketchip.rocket.WithNHugeCores(1) ++
  new chipyard.config.AbstractConfig
)
