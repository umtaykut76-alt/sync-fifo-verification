// ============================================================
// Synchronous FIFO (single clock)
//  - Pointers are ADDR_W+1 bits wide: the extra MSB (lap bit)
//    is used to tell full from empty
//  - DEPTH must be a power of 2 (pointers wrap around naturally)
//  - Registered read: rd_data is valid 1 clock AFTER rd_en
//  - Write when full / read when empty is silently ignored
// ============================================================
module sync_fifo #(
  parameter int DATA_WIDTH = 8,
  parameter int DEPTH      = 16
)(
  input  logic                  clk,
  input  logic                  rst_n,    // asynchronous, active-low reset

  // Write side
  input  logic                  wr_en,
  input  logic [DATA_WIDTH-1:0] wr_data,
  output logic                  full,

  // Read side
  input  logic                  rd_en,
  output logic [DATA_WIDTH-1:0] rd_data,
  output logic                  empty
);

  localparam int ADDR_W = $clog2(DEPTH);

  // Fail immediately in simulation if DEPTH is not a power of 2
  initial begin
    if (DEPTH != (1 << ADDR_W))
      $fatal(1, "sync_fifo: DEPTH must be a power of 2 (DEPTH=%0d)", DEPTH);
  end

  // ----------------------------------------------------------
  // Memory and pointers
  // ----------------------------------------------------------
  logic [DATA_WIDTH-1:0] mem [DEPTH];

  logic [ADDR_W:0] wptr;   // [ADDR_W] = lap bit, [ADDR_W-1:0] = address
  logic [ADDR_W:0] rptr;

  // ----------------------------------------------------------
  // full / empty
  //  empty : pointers are completely equal (same address, same lap)
  //  full  : addresses are equal but lap bits differ
  //          (the write pointer is one lap ahead of the read pointer)
  // ----------------------------------------------------------
  assign empty = (wptr == rptr);
  assign full  = (wptr[ADDR_W]     != rptr[ADDR_W]) &&
                 (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0]);

  // Operations that actually take place (guarded by full/empty)
  logic do_write, do_read;
  assign do_write = wr_en && !full;
  assign do_read  = rd_en && !empty;

  // ----------------------------------------------------------
  // Write: store the data in memory, advance wptr
  // ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      wptr <= '0;
    end else if (do_write) begin
      mem[wptr[ADDR_W-1:0]] <= wr_data;
      wptr <= wptr + 1'b1;
    end
  end

  // ----------------------------------------------------------
  // Read: load the output register, advance rptr
  // ----------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rptr    <= '0;
      rd_data <= '0;
    end else if (do_read) begin
      rd_data <= mem[rptr[ADDR_W-1:0]];
      rptr    <= rptr + 1'b1;
    end
  end

endmodule
