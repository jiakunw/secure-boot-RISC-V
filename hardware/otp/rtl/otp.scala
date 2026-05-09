import chisel3._

class OTPIO extends Bundle {
  val readEn   = Input(Bool())
  val readData = Output(UInt(256.W))
  val ack      = Output(Bool())
}

class OTPPeripheral(val pubkeyHash: BigInt) extends Module {
  val io = IO(new OTPIO)

  val hashVal = pubkeyHash.U(256.W)
  val ackReg  = RegInit(false.B)

  io.readData := 0.U
  ackReg      := false.B

  when(io.readEn) {
    io.readData := hashVal
    ackReg      := true.B
  }

  io.ack := ackReg
}
