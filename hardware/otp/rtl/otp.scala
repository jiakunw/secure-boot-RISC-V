package chipyard

import chisel3._
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.regmapper._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}
import java.nio.file.{Files, Path, Paths}

// --- 1. Parameters & Key ---
case class SecureBootOTPParams(
    address: BigInt = 0xF0000000L,
    hashPath: String = "metadata/pubkey_hash.bin")

case object SecureBootOTPKey extends Field[Option[SecureBootOTPParams]](None)

// --- 2. The LazyModule ---
class SecureBootOTPTL(params: SecureBootOTPParams, beatBytes: Int)(implicit p: Parameters)
    extends LazyModule {

  val device = new SimpleDevice("secure-boot-otp", Seq("secureboot,otp-v1"))
  val node = TLRegisterNode(
    address     = Seq(AddressSet(params.address, 0x1f)),  // 32 B, matches OTP_SIZE in bootrom.c
    device      = device,
    beatBytes   = beatBytes,
    concurrency = 1)

  lazy val module = new LazyModuleImp(this) {
    // Resolve relative paths against $SECURE_BOOT_REPO so the build works
    // from $CHIPYARD_HOME/sims/verilator (where cwd lands during elaboration).
    val resolvedPath: Path = {
      val raw = Paths.get(params.hashPath)
      if (raw.isAbsolute) raw
      else sys.env.get("SECURE_BOOT_REPO") match {
        case Some(root) => Paths.get(root).resolve(raw)
        case None       => raw.toAbsolutePath
      }
    }

    // Fail loud if the hash file is missing or wrong size — never silently boot
    // with a bogus root of trust.
    val hashBytes: Array[Byte] = Files.readAllBytes(resolvedPath)
    require(hashBytes.length == 32,
      s"OTP hash at $resolvedPath must be 32 bytes (found ${hashBytes.length})")

    // Pack 32 bytes into 8 little-endian 32-bit words so the regmap mirrors
    // BootROM's `for (i = 0; i < 32; i += 4) read_register(OTP_BASE + i)` pattern.
    val words: Seq[BigInt] = hashBytes.toSeq.map(b => BigInt(b & 0xff))
      .grouped(4)
      .map(group => group.zipWithIndex.foldLeft(BigInt(0)) {
        case (acc, (b, i)) => acc | (b << (i * 8))
      })
      .toSeq

    val mapping = words.zipWithIndex.map { case (w, idx) =>
      (idx * 4) -> Seq(RegField.r(32, w.U(32.W)))
    }
    node.regmap(mapping: _*)
  }
}

// --- 3. The Integration Trait ---
trait CanHavePeripherySecureBootOTP { this: BaseSubsystem =>
  private val pbus = locateTLBusWrapper(PBUS)

  val otp = p(SecureBootOTPKey).map { params =>
    val otpModule = LazyModule(new SecureBootOTPTL(params, pbus.beatBytes)(p))
    pbus.coupleTo("secure_boot_otp") {
      otpModule.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
    otpModule
  }
}

// --- 4. The Config Class ---
class WithSecureBootOTP(
    address: BigInt = 0xF0000000L,
    hashPath: String = "metadata/pubkey_hash.bin")
  extends Config((site, here, up) => {
    case SecureBootOTPKey => Some(SecureBootOTPParams(address, hashPath))
  })
