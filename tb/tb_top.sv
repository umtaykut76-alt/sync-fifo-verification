// ============================================================
// Layered, class-based (non-UVM) testbench for sync_fifo
//
//  fifo_test
//    └─ fifo_env
//         ├─ fifo_generator  --(mailbox)--> fifo_driver --> [ DUT ]
//         └─ fifo_monitor    --(mailbox)--> fifo_scoreboard <-- [ DUT ]
//
// Compile order:  sync_fifo.sv  ->  tb_top.sv   (top: tb_top)
// ============================================================


// ------------------------------------------------------------
// 1) Shared parameters (DUT and testbench use the same values)
// ------------------------------------------------------------
package fifo_cfg_pkg;
  localparam int DATA_WIDTH = 8;
  localparam int DEPTH      = 16;   // must be a power of 2
endpackage


// ------------------------------------------------------------
// 2) Interface: the wires between the DUT and the testbench
//    Clocking blocks prevent races between driver/monitor and DUT
// ------------------------------------------------------------
interface fifo_if (input logic clk);
  import fifo_cfg_pkg::*;

  logic                  rst_n   = 1'b0;
  logic                  wr_en   = 1'b0;
  logic [DATA_WIDTH-1:0] wr_data;
  logic                  full;
  logic                  rd_en   = 1'b0;
  logic [DATA_WIDTH-1:0] rd_data;
  logic                  empty;

  // Driver: drives 1ns AFTER the clock edge
  clocking drv_cb @(posedge clk);
    default input #1step output #1;
    output rst_n, wr_en, wr_data, rd_en;
    input  full, empty, rd_data;
  endclocking

  // Monitor: samples the values just BEFORE the clock edge
  // (i.e. the values the DUT sees at that edge)
  clocking mon_cb @(posedge clk);
    default input #1step;
    input rst_n, wr_en, wr_data, full, rd_en, rd_data, empty;
  endclocking
endinterface


// ------------------------------------------------------------
// 3) Testbench class package
// ------------------------------------------------------------
package fifo_tb_pkg;
  import fifo_cfg_pkg::*;

  // ==========================================================
  // Transaction: stimulus / observation for one clock cycle
  // ==========================================================
  class fifo_txn;
    // --- request fields ---
    bit                  wr_en;
    bit                  rd_en;
    bit [DATA_WIDTH-1:0] wr_data;

    // --- if greater than 0, this txn is a RESET request ---
    int unsigned reset_cycles = 0;

    // --- fields observed by the monitor (logic to preserve X) ---
    logic                  rst_n;
    logic                  full;
    logic                  empty;
    logic [DATA_WIDTH-1:0] rd_data;

    // $urandom is used instead of randomize()/constraints
    // (the constraint solver is disabled in the Starter Edition license).
    // wr_pct / rd_pct = probability (percent, 0..100) of the request being 1
    function void gen_random(int unsigned wr_pct, int unsigned rd_pct);
      wr_en   = ($urandom_range(99) < wr_pct);
      rd_en   = ($urandom_range(99) < rd_pct);
      wr_data = $urandom();
    endfunction
  endclass


  // ==========================================================
  // Generator: creates txns and puts them in the mailbox
  // ==========================================================
  class fifo_generator;
    mailbox #(fifo_txn) gen2drv;
    int unsigned        sent = 0;   // total number of txns sent

    function new(mailbox #(fifo_txn) gen2drv);
      this.gen2drv = gen2drv;
    endfunction

    // Reset request
    task send_reset(int unsigned cycles);
      fifo_txn t = new();
      t.reset_cycles = cycles;
      gen2drv.put(t);
      sent++;
    endtask

    // n cycles of random traffic; wr_pct / rd_pct set the write/read probability
    task send_random(int unsigned n, int unsigned wr_pct, int unsigned rd_pct);
      repeat (n) begin
        fifo_txn t = new();
        t.gen_random(wr_pct, rd_pct);
        gen2drv.put(t);
        sent++;
      end
    endtask
  endclass


  // ==========================================================
  // Driver: takes txns from the mailbox and drives the pins
  //  - Consumes one txn per clock; drives idle when none is pending
  // ==========================================================
  class fifo_driver;
    virtual fifo_if     vif;
    mailbox #(fifo_txn) gen2drv;
    int unsigned        done = 0;   // number of txns processed

    function new(virtual fifo_if vif, mailbox #(fifo_txn) gen2drv);
      this.vif     = vif;
      this.gen2drv = gen2drv;
    endfunction

    task drive_idle();
      vif.drv_cb.wr_en <= 1'b0;
      vif.drv_cb.rd_en <= 1'b0;
    endtask

    task run();
      fifo_txn t;
      forever begin
        @(vif.drv_cb);
        if (gen2drv.try_get(t)) begin
          if (t.reset_cycles > 0) begin
            drive_idle();
            vif.drv_cb.rst_n <= 1'b0;
            repeat (t.reset_cycles) @(vif.drv_cb);
            vif.drv_cb.rst_n <= 1'b1;
          end else begin
            vif.drv_cb.wr_en   <= t.wr_en;
            vif.drv_cb.wr_data <= t.wr_data;
            vif.drv_cb.rd_en   <= t.rd_en;
          end
          done++;
        end else begin
          drive_idle();
        end
      end
    endtask
  endclass


  // ==========================================================
  // Monitor: samples the pins on every clock edge and sends them to the scoreboard
  // ==========================================================
  class fifo_monitor;
    virtual fifo_if     vif;
    mailbox #(fifo_txn) mon2scb;

    function new(virtual fifo_if vif, mailbox #(fifo_txn) mon2scb);
      this.vif     = vif;
      this.mon2scb = mon2scb;
    endfunction

    task run();
      fifo_txn t;
      forever begin
        @(vif.mon_cb);
        t = new();
        t.rst_n   = vif.mon_cb.rst_n;
        t.wr_en   = vif.mon_cb.wr_en;
        t.wr_data = vif.mon_cb.wr_data;
        t.rd_en   = vif.mon_cb.rd_en;
        t.full    = vif.mon_cb.full;
        t.empty   = vif.mon_cb.empty;
        t.rd_data = vif.mon_cb.rd_data;
        mon2scb.put(t);
      end
    endtask
  endclass


  // ==========================================================
  // Scoreboard: compares the DUT against a reference model (queue)
  //
  //  On every sample (just before the clock edge):
  //   1) full / empty / rd_data are compared with the model's CURRENT state
  //   2) then the requests seen at this edge are applied to the model
  //
  //  Because rd_data is registered: when a read happens the model updates
  //  the "expected rd_data" value, and the DUT output is compared with it
  //  at the next sample. The value must hold until the next read.
  // ==========================================================
  class fifo_scoreboard;
    mailbox #(fifo_txn) mon2scb;

    logic [DATA_WIDTH-1:0] model [$];
    logic [DATA_WIDTH-1:0] exp_rd_data = '0;

    int unsigned errors = 0;

    // statistics (did the stimulus actually reach the corner cases?)
    int unsigned n_cycles, n_writes, n_reads;
    int unsigned n_overflow, n_underflow;
    int unsigned n_simul, n_simul_at_full, n_simul_at_empty;
    int unsigned n_empty_cycles, n_full_cycles;
    int unsigned n_reset_with_data;
    int unsigned max_level;

    function new(mailbox #(fifo_txn) mon2scb);
      this.mon2scb = mon2scb;
    endfunction

    task run();
      fifo_txn t;
      forever begin
        mon2scb.get(t);
        check(t);
      end
    endtask

    function void check(fifo_txn t);
      bit exp_full, exp_empty, do_w, do_r;

      // ---------------- RESET state ----------------
      if (!t.rst_n) begin
        if (model.size() > 0) n_reset_with_data++;
        model.delete();
        exp_rd_data = '0;
        // Outputs must be at their reset values during reset
        // (they can be X in the first cycle, so only check known values)
        if (!$isunknown({t.full, t.empty, t.rd_data})) begin
          if (t.empty !== 1'b1 || t.full !== 1'b0 || t.rd_data !== '0) begin
            errors++;
            $error("[SCB] @%0t wrong reset values: empty=%b full=%b rd_data=%h",
                   $time, t.empty, t.full, t.rd_data);
          end
        end
        return;
      end

      n_cycles++;
      exp_full  = (model.size() == DEPTH);
      exp_empty = (model.size() == 0);

      // ---------------- 1) OUTPUT CHECKS ----------------
      if (t.full !== exp_full) begin
        errors++;
        $error("[SCB] @%0t full mismatch: DUT=%b expected=%b (level=%0d)",
               $time, t.full, exp_full, model.size());
      end
      if (t.empty !== exp_empty) begin
        errors++;
        $error("[SCB] @%0t empty mismatch: DUT=%b expected=%b (level=%0d)",
               $time, t.empty, exp_empty, model.size());
      end
      if (t.rd_data !== exp_rd_data) begin
        errors++;
        $error("[SCB] @%0t rd_data mismatch: DUT=%h expected=%h",
               $time, t.rd_data, exp_rd_data);
      end

      // ---------------- 2) APPLY REQUESTS TO THE MODEL ----------------
      // The decision is made from the pre-edge state (like do_write/do_read in the DUT)
      do_w = t.wr_en && !exp_full;
      do_r = t.rd_en && !exp_empty;

      if (exp_full)  n_full_cycles++;
      if (exp_empty) n_empty_cycles++;
      if (t.wr_en && exp_full)  n_overflow++;
      if (t.rd_en && exp_empty) n_underflow++;
      if (t.wr_en && t.rd_en && exp_full)  n_simul_at_full++;
      if (t.wr_en && t.rd_en && exp_empty) n_simul_at_empty++;
      if (do_w && do_r) n_simul++;

      if (do_r) begin
        exp_rd_data = model.pop_front();
        n_reads++;
      end
      if (do_w) begin
        model.push_back(t.wr_data);
        n_writes++;
      end
      if (model.size() > max_level) max_level = model.size();
    endfunction

    function void report();
      $display("");
      $display("================ FIFO TEST SUMMARY ================");
      $display("  total cycles                  : %0d", n_cycles);
      $display("  successful writes / reads     : %0d / %0d", n_writes, n_reads);
      $display("  max occupancy                 : %0d / %0d", max_level, DEPTH);
      $display("  full / empty cycles           : %0d / %0d", n_full_cycles, n_empty_cycles);
      $display("  overflow attempts             : %0d", n_overflow);
      $display("  underflow attempts            : %0d", n_underflow);
      $display("  simultaneous wr+rd (normal)   : %0d", n_simul);
      $display("  simultaneous, FIFO full       : %0d", n_simul_at_full);
      $display("  simultaneous, FIFO empty      : %0d", n_simul_at_empty);
      $display("  reset with data               : %0d", n_reset_with_data);

      // Stimulus coverage check: were the corner cases really exercised?
      if (max_level != DEPTH)      begin errors++; $error("[SCB] COVERAGE: FIFO never became full"); end
      if (n_empty_cycles == 0)     begin errors++; $error("[SCB] COVERAGE: FIFO never stayed empty"); end
      if (n_overflow == 0)         begin errors++; $error("[SCB] COVERAGE: overflow was never attempted"); end
      if (n_underflow == 0)        begin errors++; $error("[SCB] COVERAGE: underflow was never attempted"); end
      if (n_simul == 0)            begin errors++; $error("[SCB] COVERAGE: simultaneous write+read was never attempted"); end
      if (n_simul_at_full == 0)    begin errors++; $error("[SCB] COVERAGE: write+read while full was never attempted"); end
      if (n_simul_at_empty == 0)   begin errors++; $error("[SCB] COVERAGE: write+read while empty was never attempted"); end
      if (n_writes < 2*DEPTH)      begin errors++; $error("[SCB] COVERAGE: no pointer wrap-around"); end
      if (n_reset_with_data == 0)  begin errors++; $error("[SCB] COVERAGE: reset with data inside was never attempted"); end

      if (errors == 0) $display("  *** TEST PASSED ***");
      else             $display("  *** TEST FAILED: %0d errors ***", errors);
      $display("===================================================");
    endfunction
  endclass


  // ==========================================================
  // Environment: creates and connects all components
  // ==========================================================
  class fifo_env;
    fifo_generator      gen;
    fifo_driver         drv;
    fifo_monitor        mon;
    fifo_scoreboard     scb;
    mailbox #(fifo_txn) gen2drv;
    mailbox #(fifo_txn) mon2scb;
    virtual fifo_if     vif;

    function new(virtual fifo_if vif);
      this.vif = vif;
      gen2drv  = new();
      mon2scb  = new();
      gen      = new(gen2drv);
      drv      = new(vif, gen2drv);
      mon      = new(vif, mon2scb);
      scb      = new(mon2scb);
    endfunction

    task start();
      fork
        drv.run();
        mon.run();
        scb.run();
      join_none
    endtask

    // Wait until all sent txns are processed and the last samples reach the scoreboard
    task wait_done();
      wait (drv.done == gen.sent);
      repeat (3) @(vif.mon_cb);
    endtask
  endclass


  // ==========================================================
  // Test: runs the scenarios in sequence
  // ==========================================================
  class fifo_test;
    fifo_env env;

    function new(virtual fifo_if vif);
      env = new(vif);
    endfunction

    task do_reset(int unsigned cycles);
      $display("[TEST] @%0t reset (%0d cycles)", $time, cycles);
      env.gen.send_reset(cycles);
      env.wait_done();
    endtask

    task phase(string name, int unsigned n, int unsigned wr_pct, int unsigned rd_pct);
      $display("[TEST] @%0t %s (n=%0d, write=%0d%%, read=%0d%%)",
               $time, name, n, wr_pct, rd_pct);
      env.gen.send_random(n, wr_pct, rd_pct);
      env.wait_done();
    endtask

    task run();
      env.start();

      // ---- 1) Initial state after reset ----
      do_reset(3);

      // ---- 2) Read from an empty FIFO (underflow) ----
      phase("read from empty FIFO (underflow)",        5,           0, 100);

      // ---- 3) Fill + overflow attempts ----
      phase("fill + overflow attempts",                DEPTH + 4,   100, 0);

      // ---- 4) Simultaneous write+read while full ----
      phase("simultaneous write+read while full",      2*DEPTH,     100, 100);

      // ---- 5) Drain + underflow ----
      phase("drain + underflow",                       2*DEPTH + 4, 0, 100);

      // ---- 6) Simultaneous write+read while empty ----
      phase("simultaneous write+read while empty",     2*DEPTH,     100, 100);
      phase("drain",                                   2*DEPTH + 4, 0, 100);

      // ---- 7) Random traffic (many wrap-arounds) ----
      phase("balanced random",                         500,         50, 50);
      phase("write-heavy random",                      300,         70, 30);
      phase("read-heavy random",                       300,         30, 70);

      // ---- 8) Reset with data inside ----
      phase("partial fill",                            6,           100, 0);
      do_reset(2);
      phase("read after reset (must be empty)",        4,           0, 100);
      phase("refill after reset",                      5,           100, 0);
      phase("drain (new data must come out)",          8,           0, 100);

      // ---- 9) Reset while completely full ----
      phase("fill completely",                         DEPTH,       100, 0);
      do_reset(2);
      phase("post-reset verification",                 DEPTH + 2,   50, 50);

      // ---- 10) Long runs with random weights ----
      repeat (10)
        phase("random-weight run",                     200,
              $urandom_range(10, 90), $urandom_range(10, 90));

      // Final drain
      phase("final drain",                             2*DEPTH + 4, 0, 100);

      env.scb.report();
    endtask
  endclass

endpackage


// ------------------------------------------------------------
// 4) Top module: ties together clock, DUT, interface and test
// ------------------------------------------------------------
module tb_top;
  import fifo_cfg_pkg::*;
  import fifo_tb_pkg::*;

  logic clk = 1'b0;
  always #5 clk = ~clk;          // 10ns period

  fifo_if fif (clk);

  sync_fifo #(
    .DATA_WIDTH (DATA_WIDTH),
    .DEPTH      (DEPTH)
  ) dut (
    .clk     (clk),
    .rst_n   (fif.rst_n),
    .wr_en   (fif.wr_en),
    .wr_data (fif.wr_data),
    .full    (fif.full),
    .rd_en   (fif.rd_en),
    .rd_data (fif.rd_data),
    .empty   (fif.empty)
  );

  initial begin
    fifo_test test;
    test = new(fif);
    test.run();
    $finish;
  end

  // Watchdog in case the test hangs
  initial begin
    #1ms;
    $fatal(1, "[TB] timeout: test did not finish");
  end
endmodule
