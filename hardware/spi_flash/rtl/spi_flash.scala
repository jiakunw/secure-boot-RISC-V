package chipyard

import chisel3._
import chisel3.util._
import chisel3.util.experimental.loadMemoryFromFileInline
import freechips.rocketchip.diplomacy._
import freechips.rocketchip.prci._
import freechips.rocketchip.regmapper.RegField
import freechips.rocketchip.subsystem.{BaseSubsystem, PBUS}
import freechips.rocketchip.tilelink._
import org.chipsalliance.cde.config.{Config, Field, Parameters}

case class SecureBootSPIParams(
    address: BigInt = 0xF0002000L,
    depthBytes: Int = 1 << 20,
    imageHexFile: String = "flash_image/flash_image.hex",
    fifoDepth: Int = 16)

case object SecureBootSPIKey extends Field[Option[SecureBootSPIParams]](None)

class SPIFlashPort extends Bundle {
  val cs_n = Output(Bool())
  val sclk = Output(Bool())
  val mosi = Output(Bool())
  val miso = Input(Bool())
}

class SPIFlashSlave(
    depthBytes: Int = 1 << 20,
    imageHexFile: String = ""
) extends Module {
  require(depthBytes > 0, "SPI flash depth must be positive")

  private val addrWidth = log2Ceil(depthBytes)

  val io = IO(new Bundle {
    val cs_n = Input(Bool())
    val sclk = Input(Bool())
    val mosi = Input(Bool())
    val miso = Output(Bool())
    val active = Output(Bool())
    val readAddress = Output(UInt(24.W))
  })

  val flash = Mem(depthBytes, UInt(8.W))
  if (imageHexFile.nonEmpty) {
    loadMemoryFromFileInline(flash, imageHexFile)
  }

  val sIdle :: sCommand :: sAddress :: sData :: sIgnore :: Nil = Enum(5)

  val state = RegInit(sIdle)
  val sclkPrev = RegNext(io.sclk, false.B)
  val risingEdge = !sclkPrev && io.sclk
  val fallingEdge = sclkPrev && !io.sclk

  val commandReg = RegInit(0.U(8.W))
  val commandBits = RegInit(0.U(3.W))
  val addressReg = RegInit(0.U(24.W))
  val addressBits = RegInit(0.U(5.W))
  val outputReg = RegInit(0.U(8.W))
  val outputBits = RegInit(0.U(3.W))
  val outputLoaded = RegInit(false.B)
  val misoReg = RegInit(false.B)

  private def readByte(addr: UInt): UInt = flash(addr(addrWidth - 1, 0))
  private def nextAddress(addr: UInt): UInt =
    Mux(addr === (depthBytes - 1).U, 0.U, addr + 1.U)

  io.miso := Mux(io.cs_n, false.B, misoReg)
  io.active := !io.cs_n && state =/= sIdle
  io.readAddress := addressReg

  when(io.cs_n) {
    state := sIdle
    commandReg := 0.U
    commandBits := 0.U
    addressReg := 0.U
    addressBits := 0.U
    outputReg := 0.U
    outputBits := 0.U
    outputLoaded := false.B
    misoReg := false.B
  }.otherwise {
    when(state === sIdle) {
      state := sCommand
    }

    switch(state) {
      is(sCommand) {
        when(risingEdge) {
          val nextCommand = Cat(commandReg(6, 0), io.mosi)
          commandReg := nextCommand
          when(commandBits === 7.U) {
            commandBits := 0.U
            state := Mux(nextCommand === "h03".U, sAddress, sIgnore)
          }.otherwise {
            commandBits := commandBits + 1.U
          }
        }
      }

      is(sAddress) {
        when(risingEdge) {
          val nextAddr = Cat(addressReg(22, 0), io.mosi)
          addressReg := nextAddr
          when(addressBits === 23.U) {
            addressBits := 0.U
            outputReg := readByte(nextAddr)
            outputBits := 0.U
            outputLoaded := false.B
            state := sData
          }.otherwise {
            addressBits := addressBits + 1.U
          }
        }
      }

      is(sData) {
        when(fallingEdge) {
          when(!outputLoaded) {
            misoReg := outputReg(7)
            outputLoaded := true.B
          }.otherwise {
            when(outputBits === 7.U) {
              val addrPlusOne = nextAddress(addressReg)
              val nextByte = readByte(addrPlusOne)
              addressReg := addrPlusOne
              outputReg := nextByte
              misoReg := nextByte(7)
              outputBits := 0.U
            }.otherwise {
              outputReg := Cat(outputReg(6, 0), 0.U(1.W))
              misoReg := outputReg(6)
              outputBits := outputBits + 1.U
            }
          }
        }
      }

      is(sIgnore) {
        misoReg := false.B
      }
    }
  }
}

class SPIMasterCore extends Module {
  val io = IO(new Bundle {
    val start = Input(Bool())
    val address = Input(UInt(24.W))
    val lengthBytes = Input(UInt(32.W))
    val data = Decoupled(UInt(32.W))
    val busy = Output(Bool())
    val done = Output(Bool())
    val error = Output(Bool())
    val remainingBytes = Output(UInt(32.W))
    val spi = new SPIFlashPort
  })

  val sIdle :: sSendSetup :: sSendRise :: sReadSetup :: sReadRise :: sEmit :: sDone :: Nil = Enum(7)

  val state = RegInit(sIdle)
  val txShift = RegInit(0.U(32.W))
  val txBitsLeft = RegInit(0.U(6.W))
  val rxByte = RegInit(0.U(8.W))
  val rxBitCount = RegInit(0.U(3.W))
  val bytesRemaining = RegInit(0.U(32.W))
  val wordReg = RegInit(0.U(32.W))
  val wordByteCount = RegInit(0.U(2.W))
  val emitWord = RegInit(0.U(32.W))
  val sclkReg = RegInit(false.B)
  val mosiReg = RegInit(false.B)
  val csReg = RegInit(true.B)
  val doneReg = RegInit(false.B)
  val errorReg = RegInit(false.B)

  io.spi.cs_n := csReg
  io.spi.sclk := sclkReg
  io.spi.mosi := mosiReg
  io.data.valid := state === sEmit
  io.data.bits := emitWord
  io.busy := state =/= sIdle && state =/= sDone
  io.done := doneReg
  io.error := errorReg
  io.remainingBytes := bytesRemaining

  when(state =/= sDone) {
    doneReg := false.B
  }

  switch(state) {
    is(sIdle) {
      csReg := true.B
      sclkReg := false.B
      mosiReg := false.B
      errorReg := false.B
      when(io.start) {
        when(io.lengthBytes === 0.U) {
          doneReg := true.B
          state := sDone
        }.otherwise {
          csReg := false.B
          txShift := Cat("h03".U(8.W), io.address)
          txBitsLeft := 32.U
          rxByte := 0.U
          rxBitCount := 0.U
          bytesRemaining := io.lengthBytes
          wordReg := 0.U
          wordByteCount := 0.U
          state := sSendSetup
        }
      }
    }

    is(sSendSetup) {
      sclkReg := false.B
      mosiReg := txShift(31)
      state := sSendRise
    }

    is(sSendRise) {
      sclkReg := true.B
      txShift := Cat(txShift(30, 0), 0.U(1.W))
      txBitsLeft := txBitsLeft - 1.U
      when(txBitsLeft === 1.U) {
        state := sReadSetup
      }.otherwise {
        state := sSendSetup
      }
    }

    is(sReadSetup) {
      sclkReg := false.B
      mosiReg := false.B
      state := sReadRise
    }

    is(sReadRise) {
      sclkReg := true.B
      val nextByte = Cat(rxByte(6, 0), io.spi.miso)
      when(rxBitCount === 7.U) {
        val shift = Cat(wordByteCount, 0.U(3.W))
        val packedByte = (nextByte.pad(32) << shift)(31, 0)
        val nextWord = wordReg | packedByte
        val lastByte = bytesRemaining === 1.U
        emitWord := nextWord
        bytesRemaining := bytesRemaining - 1.U
        rxByte := 0.U
        rxBitCount := 0.U

        when(wordByteCount === 3.U || lastByte) {
          wordReg := 0.U
          wordByteCount := 0.U
          state := sEmit
        }.otherwise {
          wordReg := nextWord
          wordByteCount := wordByteCount + 1.U
          state := sReadSetup
        }
      }.otherwise {
        rxByte := nextByte
        rxBitCount := rxBitCount + 1.U
        state := sReadSetup
      }
    }

    is(sEmit) {
      sclkReg := false.B
      when(io.data.ready) {
        when(bytesRemaining === 0.U) {
          csReg := true.B
          doneReg := true.B
          state := sDone
        }.otherwise {
          state := sReadSetup
        }
      }
    }

    is(sDone) {
      csReg := true.B
      sclkReg := false.B
      when(!io.start) {
        state := sIdle
      }
    }
  }
}

class SecureBootSPITL(params: SecureBootSPIParams, beatBytes: Int)(implicit p: Parameters)
    extends ClockSinkDomain(ClockSinkParameters())(p) {
  val device = new SimpleDevice("secure-boot-spi", Seq("secureboot,spi-master"))
  val node = TLRegisterNode(
    address = Seq(AddressSet(params.address, 0xfff)),
    device = device,
    beatBytes = beatBytes,
    concurrency = 1)

  override lazy val module = new SecureBootSPIImpl
  class SecureBootSPIImpl extends Impl {
    withClockAndReset(clock, reset) {
      val addrReg = RegInit(0.U(32.W))
      val lenReg = RegInit(4.U(32.W))
      val doneSticky = RegInit(false.B)

      val command = Wire(Decoupled(UInt(32.W)))
      val startPulse = WireDefault(false.B)

      val master = Module(new SPIMasterCore)
      val flash = Module(new SPIFlashSlave(params.depthBytes, params.imageHexFile))
      val fifo = Module(new Queue(UInt(32.W), params.fifoDepth))

      flash.io.cs_n := master.io.spi.cs_n
      flash.io.sclk := master.io.spi.sclk
      flash.io.mosi := master.io.spi.mosi
      master.io.spi.miso := flash.io.miso

      master.io.start := startPulse
      master.io.address := addrReg(23, 0)
      master.io.lengthBytes := lenReg
      fifo.io.enq <> master.io.data

      command.ready := !master.io.busy
      when(command.fire) {
        when(command.bits(1)) {
          doneSticky := false.B
        }
        when(command.bits(0)) {
          startPulse := true.B
          doneSticky := false.B
        }
      }
      when(master.io.done) {
        doneSticky := true.B
      }

      val status = Cat(
        0.U(27.W),
        fifo.io.deq.valid,
        master.io.error,
        doneSticky,
        master.io.busy)

      node.regmap(
        0x00 -> Seq(RegField(32, addrReg)),
        0x04 -> Seq(RegField(32, lenReg)),
        0x08 -> Seq(RegField.w(32, command)),
        0x0C -> Seq(RegField.r(32, status)),
        0x10 -> Seq(RegField.r(32, fifo.io.deq)),
        0x14 -> Seq(RegField.r(32, master.io.remainingBytes)))
    }
  }
}

trait CanHavePeripherySecureBootSPI { this: BaseSubsystem =>
  private val pbus = locateTLBusWrapper(PBUS)

  p(SecureBootSPIKey).foreach { params =>
    val spi = LazyModule(new SecureBootSPITL(params, pbus.beatBytes)(p))
    spi.clockNode := pbus.fixedClockNode
    pbus.coupleTo("secure_boot_spi") {
      spi.node := TLFragmenter(pbus.beatBytes, pbus.blockBytes) := _
    }
  }
}

class WithSecureBootSPI(
    address: BigInt = 0xF0002000L,
    depthBytes: Int = 1 << 20,
    imageHexFile: String = "flash_image/flash_image.hex",
    fifoDepth: Int = 16)
    extends Config((site, here, up) => {
      case SecureBootSPIKey => Some(SecureBootSPIParams(address, depthBytes, imageHexFile, fifoDepth))
    })
