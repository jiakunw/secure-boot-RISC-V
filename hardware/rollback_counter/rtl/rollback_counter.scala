import chisel3._
import chisel3.util._

class RollbackCounterIO extends Bundle {
  val readEn    = Input(Bool())
  val writeEn   = Input(Bool())
  val writeData = Input(UInt(64.W))
  val readDaata = Output(UInt(64.W))
  val ack       = Output(Bool())
}

class RollbackCounter extends Module {
  val io = IO(new RollbackCounterIO)

  val counter = RegInit(1.U(64.W))
  val ackReg  = RegInit(false.B)

  io.readData := 0.U
  ackReg      := false.B

  when (io.writeEn) {
    when (io.writeData > counter) {
      counter := io.writeData
    }

    ackReg := true.B
  }

  io.ack := ackReg
}
