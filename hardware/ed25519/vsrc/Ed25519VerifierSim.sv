module Ed25519VerifierSim (
    input  wire        clock,
    input  wire        reset,

    input  wire        clear,
    input  wire        data_valid,
    input  wire [31:0] data_word,
    input  wire        start,

    output reg  [31:0] status,
    output reg  [31:0] count
);

  // bootrom writes manifest, signature, then public key
  reg [7:0] buffer [0:191];

  integer idx;
  integer f;
  integer rc;
  integer i;

  task write_file;
    input [1023:0] path;
    input integer start_idx;
    input integer nbytes;
    integer j;
    begin
      f = $fopen(path, "wb");
      if (f == 0) begin
        status <= 32'h00000008; // error
      end else begin
        for (j = 0; j < nbytes; j = j + 1) begin
          $fwrite(f, "%c", buffer[start_idx + j]);
        end
        $fclose(f);
      end
    end
  endtask

  always @(posedge clock) begin
    if (reset || clear) begin
      idx    <= 0;
      count  <= 0;
      status <= 32'h00000000;
    end else begin
      if (data_valid) begin
        if (idx <= 188) begin
          buffer[idx + 0] <= data_word[7:0];
          buffer[idx + 1] <= data_word[15:8];
          buffer[idx + 2] <= data_word[23:16];
          buffer[idx + 3] <= data_word[31:24];
          idx   <= idx + 4;
          count <= idx + 4;
        end else begin
          status <= 32'h00000008; // error
        end
      end

      if (start) begin
        $display("EDDBG start count=%0d idx=%0d", count, idx);
        status <= 32'h00000001; // busy

        if (idx != 192) begin
          status <= 32'h00000008; // error
        end else begin
          write_file("/tmp/secureboot_ed_manifest.bin",  0,   96);
          write_file("/tmp/secureboot_ed_signature.bin", 96,  64);
          write_file("/tmp/secureboot_ed_public_key.bin",160, 32);

          $display("EDDBG running host verifier");
          rc = $system("python3 \"$SECURE_BOOT_REPO/tools/verify_ed25519_from_files.py\" /tmp/secureboot_ed_manifest.bin /tmp/secureboot_ed_signature.bin /tmp/secureboot_ed_public_key.bin");
          $display("EDDBG verifier rc=%0d", rc);

          if (rc == 0) begin
            status <= 32'h00000006; // done + pass
          end else begin
            status <= 32'h0000000A; // done + error
          end
        end
      end
    end
  end

endmodule