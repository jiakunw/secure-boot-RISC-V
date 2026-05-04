package chipyard

import chisel3._
import chiseltest._
import org.scalatest.flatspec.AnyFlatSpec
import scala.io.Source

class SPIFlashSlaveSpec extends AnyFlatSpec with ChiselScalatestTester {
  behavior of "SPIFlashSlave"

  private def idle(c: SPIFlashSlave): Unit = {
    c.io.cs_n.poke(true.B)
    c.io.sclk.poke(false.B)
    c.io.mosi.poke(false.B)
    c.clock.step()
  }

  private def sendBit(c: SPIFlashSlave, bit: Int): Unit = {
    c.io.mosi.poke((bit != 0).B)
    c.io.sclk.poke(false.B)
    c.clock.step()
    c.io.sclk.poke(true.B)
    c.clock.step()
    c.io.sclk.poke(false.B)
    c.clock.step()
  }

  private def sendByte(c: SPIFlashSlave, value: Int): Unit = {
    for (bit <- 7 to 0 by -1) {
      sendBit(c, (value >> bit) & 1)
    }
  }

  private def readByte(c: SPIFlashSlave): Int = {
    var value = 0
    for (_ <- 0 until 8) {
      c.io.sclk.poke(true.B)
      c.clock.step()
      value = (value << 1) | c.io.miso.peek().litValue.toInt
      c.io.sclk.poke(false.B)
      c.clock.step()
    }
    value
  }

  private def readFrom(c: SPIFlashSlave, address: Int, byteCount: Int): Seq[Int] = {
    c.io.cs_n.poke(false.B)
    c.clock.step()
    sendByte(c, 0x03)
    sendByte(c, (address >> 16) & 0xff)
    sendByte(c, (address >> 8) & 0xff)
    sendByte(c, address & 0xff)
    val data = Seq.fill(byteCount)(readByte(c))
    c.io.cs_n.poke(true.B)
    c.clock.step()
    data
  }

  private def expectedBytes(address: Int, byteCount: Int): Seq[Int] = {
    val source = Source.fromFile("flash_image/flash_image.hex")
    try {
      source.getLines().slice(address, address + byteCount).map(Integer.parseInt(_, 16)).toSeq
    } finally {
      source.close()
    }
  }

  it should "return bytes through the 0x03 READ command" in {
    test(new SPIFlashSlave(depthBytes = 256, imageHexFile = "flash_image/flash_image.hex")) { c =>
      idle(c)
      readFrom(c, 0x000000, 4) should be(expectedBytes(0x000000, 4))
      readFrom(c, 0x000060, 4) should be(expectedBytes(0x000060, 4))
      readFrom(c, 0x0000a0, 4) should be(expectedBytes(0x0000a0, 4))
      readFrom(c, 0x0000c0, 4) should be(expectedBytes(0x0000c0, 4))
    }
  }
}
