package chipyard

import chisel3._
import chisel3.util._
import org.chipsalliance.cde.config.{Config, Field, Parameters}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.prci._
import freechips.rocketchip.regmapper.{RegField, RegFieldDesc}
import freechips.rocketchip.tilelink._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}

// --- 1. Parameters & Key ---
case class SecureBootSRParams(address: BigInt = 0xF0003000L)
case object SecureBootSRKey extends Field[Option[SecureBootSRParams]](None)

// --- 2. The LazyModule ---
class SecureBootSRTL(params: SecureBootSRParams, beatBytes: Int)(implicit p: Parameters)
    extends ClockSinkDomain(ClockSinkParameters())(p) {

  val device = new SimpleDevice("secure-boot-sr", Seq("secureboot,status-reg-v1"))
  val node = TLRegisterNode(
    address     = Seq(AddressSet(params.address, 0x3f)),   // 64-byte window (PBUS maxTransfer alignment); same convention as OTP / Rollback / SPI peripherals
    device      = device,
    beatBytes   = beatBytes,
    concurrency = 1)

  override lazy val module = new SecureBootSRImpl
  class SecureBootSRImpl extends Impl {
    withClockAndReset(clock, reset) {
      // Boot failure status bits (set by BootROM on verification failure):
      //   bit 0: check_manifest_header failed
      //   bit 1: check_public_key failed (OTP root-of-trust)
      //   bit 2: check_manifest_signature failed (Ed25519)
      //   bit 3: check_and_load_kernel failed (SPI read / SHA-256 mismatch)
      //   bit 4: check_rollback_counter failed (anti-rollback)
      //   bit 5: lock_pmp failed
      // Bits 6..31 reserved.
      val status = RegInit(0.U(32.W))

      node.regmap(
        0x00 -> Seq(RegField(32, status, RegFieldDesc("boot_status", "Secure Boot Failure Status Bits")))
      )
    }
  }
}

// --- 3. The Integration Trait ---
trait CanHavePeripherySecureBootSR { this: BaseSubsystem =>
  private val pbus = locateTLBusWrapper(PBUS)

  p(SecureBootSRKey).foreach { params =>
    val sr = LazyModule(new SecureBootSRTL(params, pbus.beatBytes)(p))
    sr.clockNode := pbus.fixedClockNode
    pbus.coupleTo("secure_boot_sr") {
      sr.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
}

// --- 4. The Config Class ---
class WithSecureBootSR(address: BigInt = 0xF0003000L)
  extends Config((site, here, up) => {
    case SecureBootSRKey => Some(SecureBootSRParams(address))
  })
