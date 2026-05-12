// SPI flash backing storage.
//
// Hand-written SystemVerilog (not a Chisel `Mem`) so FIRRTL/CIRCT never wraps
// it in the `RANDOMIZE_MEM_INIT` template that Chipyard's default Verilator
// flags enable. With a Chisel `Mem`, that template runs *after*
// `loadMemoryFromFileInline`'s $readmemh in the same `initial` block and
// silently overwrites the loaded image with random bytes, so reads return
// deterministic-looking garbage instead of flash content.
//
// Two combinational read ports — one for the sAddress -> sData first-byte
// fetch, one for the byte rollover inside sData. Widths and depth come from
// the instantiating BlackBox via the parameter Map.

module FlashStorage #(
  parameter integer DEPTH    = 1048576,
  parameter integer ADDR_W   = 20,
  parameter         HEX_FILE = ""
) (
  input  wire [ADDR_W-1:0] addr0,
  output wire [7:0]        data0,
  input  wire [ADDR_W-1:0] addr1,
  output wire [7:0]        data1
);

  reg [7:0] mem [0:DEPTH-1];

  initial begin
    if (HEX_FILE != "") begin
      $readmemh(HEX_FILE, mem);
    end
  end

  assign data0 = mem[addr0];
  assign data1 = mem[addr1];

endmodule
