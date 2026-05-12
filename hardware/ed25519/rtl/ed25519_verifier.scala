package chipyard

import chisel3._
import chisel3.util._
import org.chipsalliance.cde.config.{Config, Field, Parameters}
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.prci._
import freechips.rocketchip.regmapper._
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}
import freechips.rocketchip.tilelink._

case class SecureBootEd25519Params(address: BigInt = 0xF0004000L)

case object SecureBootEd25519Key extends Field[Option[SecureBootEd25519Params]](None)

class Ed25519VerifierSim extends BlackBox with HasBlackBoxResource {
  val io = IO(new Bundle {
    val clock = Input(Clock())
    val reset = Input(Bool())

    val clear = Input(Bool())
    val data_valid = Input(Bool())
    val data_word = Input(UInt(32.W))
    val start = Input(Bool())

    val status = Output(UInt(32.W))
    val count = Output(UInt(32.W))
  })

  addResource("/vsrc/Ed25519VerifierSim.sv")
}

class SecureBootEd25519TL(params: SecureBootEd25519Params, beatBytes: Int)(implicit p: Parameters)
    extends ClockSinkDomain(ClockSinkParameters())(p) {

  val device = new SimpleDevice("secure-boot-ed25519", Seq("secureboot,ed25519-verifier-v1"))

  val node = TLRegisterNode(
    address     = Seq(AddressSet(params.address, 0x3f)),
    device      = device,
    beatBytes   = beatBytes,
    concurrency = 1)

  override lazy val module = new SecureBootEd25519Impl

  class SecureBootEd25519Impl extends Impl {
    withClockAndReset(clock, reset) {
      val verifier = Module(new Ed25519VerifierSim)

      val clearPulse = WireDefault(false.B)
      val startPulse = WireDefault(false.B)
      val dataPulse  = WireDefault(false.B)
      val dataWord   = WireDefault(0.U(32.W))

      verifier.io.clock := clock
      verifier.io.reset := reset.asBool
      verifier.io.clear := clearPulse
      verifier.io.start := startPulse
      verifier.io.data_valid := dataPulse
      verifier.io.data_word := dataWord

      node.regmap(
        // command:
        //   bit 0 = clear/reset byte counter/status
        //   bit 1 = start verification
        0x00 -> Seq(RegField.w(32, RegWriteFn { (valid, data) =>
          when (valid) {
            clearPulse := data(0)
            startPulse := data(1)
          }
          true.B
        })),

        // status:
        //   bit 0 = busy
        //   bit 1 = done
        //   bit 2 = pass
        //   bit 3 = error
        0x04 -> Seq(RegField.r(32, verifier.io.status)),

        // number of bytes received by verifier
        0x08 -> Seq(RegField.r(32, verifier.io.count)),

        // data FIFO:
        // BootROM writes manifest, signature, public key as 32-bit words.
        0x0c -> Seq(RegField.w(32, RegWriteFn { (valid, data) =>
          when (valid) {
            dataPulse := true.B
            dataWord := data
          }
          true.B
        }))
      )
    }
  }
}

trait CanHavePeripherySecureBootEd25519 { this: BaseSubsystem =>
  private val pbus = locateTLBusWrapper(PBUS)

  p(SecureBootEd25519Key).foreach { params =>
    val ed = LazyModule(new SecureBootEd25519TL(params, pbus.beatBytes)(p))
    ed.clockNode := pbus.fixedClockNode
    pbus.coupleTo("secure_boot_ed25519") {
      ed.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
}

class WithSecureBootEd25519(address: BigInt = 0xF0004000L)
  extends Config((site, here, up) => {
    case SecureBootEd25519Key => Some(SecureBootEd25519Params(address))
  })
