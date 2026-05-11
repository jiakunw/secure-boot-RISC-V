package chipyard

import chisel3._
import org.chipsalliance.cde.config.{Parameters, Field, Config}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.prci._
import freechips.rocketchip.tilelink._
import freechips.rocketchip.regmapper._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}

// --- 1. Parameters & Key ---
case class SecureBootRollbackParams(address: BigInt = 0xF0001000L)

case object SecureBootRollbackKey extends Field[Option[SecureBootRollbackParams]](None)

// --- 2. The LazyModule (matches SPI's ClockSinkDomain pattern) ---
class SecureBootRollbackCounterTL(params: SecureBootRollbackParams, beatBytes: Int)
    (implicit p: Parameters) extends ClockSinkDomain(ClockSinkParameters())(p) {

  val device = new SimpleDevice("secure-boot-rollback", Seq("secureboot,rollback-v1"))
  val node = TLRegisterNode(
    address     = Seq(AddressSet(params.address, 0x3f)),  // 64 B window (PBUS maxTransfer alignment); regmap only populates 8 B (ROLLBACK_COUNTER_SIZE in bootrom.c), rest reads 0
    device      = device,
    beatBytes   = beatBytes,
    concurrency = 1)

  override lazy val module = new SecureBootRollbackImpl
  class SecureBootRollbackImpl extends Impl {
    withClockAndReset(clock, reset) {
      // Hardware-enforced monotonic counter.
      // RegInit means simulation cannot demonstrate cross-reset persistence —
      // real silicon would back this with eFuse / anti-fuse storage.
      val version = RegInit(0.U(64.W))

      node.regmap(
        0x00 -> Seq(RegField(64,
          // Read: always valid, return current counter value.
          RegReadFn { ready => (true.B, version) },
          // Write: always ready; only advance if data is strictly greater
          // than the current value. Lower-or-equal writes are silently
          // dropped. This is the core anti-rollback security property,
          // enforced in hardware so neither M-mode software nor a corrupted
          // PMP configuration can bypass it.
          RegWriteFn { (valid, data) =>
            when (valid && (data > version)) {
              version := data
            }
            true.B
          },
          RegFieldDesc("version", "Monotonic rollback counter")
        ))
      )
    }
  }
}

// --- 3. The Integration Trait ---
trait CanHavePeripherySecureBootRollback { this: BaseSubsystem =>
  private val pbus = locateTLBusWrapper(PBUS)

  p(SecureBootRollbackKey).foreach { params =>
    val rollback = LazyModule(new SecureBootRollbackCounterTL(params, pbus.beatBytes)(p))
    rollback.clockNode := pbus.fixedClockNode
    pbus.coupleTo("secure_boot_rollback") {
      rollback.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
}

// --- 4. The Config Class ---
class WithSecureBootRollback(address: BigInt = 0xF0001000L)
  extends Config((site, here, up) => {
    case SecureBootRollbackKey => Some(SecureBootRollbackParams(address))
  })
