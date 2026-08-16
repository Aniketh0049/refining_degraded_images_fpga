`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 14.08.2026 12:47:33
// Design Name: 
// Module Name: tb_Axis_log
// Project Name: 
// Target Devices: 
// Tool Versions: 
// Description: 
// 
// Dependencies: 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
//////////////////////////////////////////////////////////////////////////////////



module tb_axis_log_lut_golden;
 
    localparam int ADDR_WIDTH = 12;
    localparam int DATA_WIDTH = 16;
    localparam int NUM_TRANSFERS = 3000;
 
    logic aclk = 0;
    logic aresetn;
    logic [ADDR_WIDTH-1:0] s_axis_tdata;
    logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
    logic [DATA_WIDTH-1:0] m_axis_tdata;
    logic m_axis_tvalid, m_axis_tlast;
    logic m_axis_tready;
 
    logic cfg_wr_en;
    logic [ADDR_WIDTH-1:0] cfg_wr_addr;
    logic [DATA_WIDTH-1:0] cfg_wr_data;
 
    axis_log_lut #(.ADDR_WIDTH(ADDR_WIDTH), .DATA_WIDTH(DATA_WIDTH)) dut (
        .aclk(aclk), .aresetn(aresetn),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tready(s_axis_tready), .s_axis_tlast(s_axis_tlast),
        .m_axis_tdata(m_axis_tdata), .m_axis_tvalid(m_axis_tvalid),
        .m_axis_tready(m_axis_tready), .m_axis_tlast(m_axis_tlast),
        .cfg_wr_en(cfg_wr_en), .cfg_wr_addr(cfg_wr_addr), .cfg_wr_data(cfg_wr_data)
    );
 
    always #5 aclk = ~aclk;
 
    // ---------------- Golden reference model ----------------
    logic [DATA_WIDTH-1:0] golden_mem [0:(1<<ADDR_WIDTH)-1];
    initial $readmemh("log_lut_q4_12.mem", golden_mem);
 
    typedef struct packed {
        logic [DATA_WIDTH-1:0] data;
        logic                  last;
    } exp_t;
    logic [DATA_WIDTH-1:0] exp_data_q[$];
    logic                  exp_last_q[$];
 
    int pushed = 0, popped = 0, errors = 0;
    bit saw_backpressure_input  = 0; // DUT stalled s_axis (s_axis_tready low while tvalid high)
    bit saw_output_stall        = 0; // m_axis_tvalid high while m_axis_tready low
    bit saw_idle_input          = 0; // driver deliberately left s_axis_tvalid low mid-test
    bit saw_cfg_write           = 0;
 
    // Push expected result whenever the DUT actually accepts a beat.
    // Sampled at negedge -- half a clock period after the DUT's own
    // posedge-triggered registers update, avoiding a same-edge race between
    // this monitor, the DUT, and the m_axis_tready driver below.
    always @(negedge aclk) begin
        if (aresetn && s_axis_tvalid && s_axis_tready) begin
            exp_data_q.push_back(golden_mem[s_axis_tdata]);
            exp_last_q.push_back(s_axis_tlast);
            pushed++;
        end
        if (aresetn && s_axis_tvalid && !s_axis_tready) saw_backpressure_input = 1;
        if (aresetn && m_axis_tvalid && !m_axis_tready) saw_output_stall = 1;
    end
 
    // Pop and compare whenever the DUT actually produces a beat.
    always @(negedge aclk) begin
        logic [DATA_WIDTH-1:0] e_data;
        logic                  e_last;
        if (aresetn && m_axis_tvalid && m_axis_tready) begin
            popped++;
            if (exp_data_q.size() == 0) begin
                $error("SCOREBOARD UNDERFLOW: DUT produced an output with nothing expected");
                errors++;
            end else begin
                e_data = exp_data_q.pop_front();
                e_last = exp_last_q.pop_front();
                if (m_axis_tdata !== e_data) begin
                    $error("DATA MISMATCH: got=%0h exp=%0h", m_axis_tdata, e_data);
                    errors++;
                end
                if (m_axis_tlast !== e_last) begin
                    $error("TLAST MISMATCH: got=%0b exp=%0b", m_axis_tlast, e_last);
                    errors++;
                end
            end
        end
    end
 
    // ---------------- Protocol assertions ----------------
`ifdef __ICARUS__
    // Icarus has no concurrent `assert property` support (confirmed by
    // direct test) -- these clocked immediate assertions check the same
    // conditions one cycle at a time.
    logic prev_m_valid, prev_m_ready;
    logic [DATA_WIDTH-1:0] prev_m_data;
    logic prev_m_last;
    always @(negedge aclk) begin
        if (aresetn) begin
            if (prev_m_valid && !prev_m_ready) begin
                assert (m_axis_tvalid) else $error("SVA(icarus): tvalid dropped while stalled");
                assert (m_axis_tdata === prev_m_data) else $error("SVA(icarus): tdata changed while stalled");
                assert (m_axis_tlast === prev_m_last) else $error("SVA(icarus): tlast changed while stalled");
            end
            if (m_axis_tvalid) assert (!$isunknown(m_axis_tdata)) else $error("SVA(icarus): X on tdata while tvalid");
        end
        prev_m_valid <= m_axis_tvalid;
        prev_m_ready <= m_axis_tready;
        prev_m_data  <= m_axis_tdata;
        prev_m_last  <= m_axis_tlast;
    end
`else
    // Real deliverable for Vivado XSim / QuestaSim (standard IEEE1800 SVA).
    property p_valid_stable_until_ready;
        @(posedge aclk) disable iff (!aresetn)
        (m_axis_tvalid && !m_axis_tready) |=> m_axis_tvalid;
    endproperty
    assert property (p_valid_stable_until_ready)
        else $error("SVA: m_axis_tvalid dropped before m_axis_tready sampled high");
 
    property p_data_stable_until_ready;
        @(posedge aclk) disable iff (!aresetn)
        (m_axis_tvalid && !m_axis_tready) |=> $stable(m_axis_tdata) && $stable(m_axis_tlast);
    endproperty
    assert property (p_data_stable_until_ready)
        else $error("SVA: m_axis_tdata/tlast changed while stalled (tvalid high, tready low)");
 
    property p_no_x_on_valid_data;
        @(posedge aclk) disable iff (!aresetn)
        m_axis_tvalid |-> !$isunknown(m_axis_tdata);
    endproperty
    assert property (p_no_x_on_valid_data)
        else $error("SVA: unknown (X) bits on m_axis_tdata while m_axis_tvalid high");
 
    property p_reset_clears_valid;
        @(posedge aclk) !aresetn |-> !m_axis_tvalid;
    endproperty
    assert property (p_reset_clears_valid)
        else $error("SVA: m_axis_tvalid asserted during reset");
`endif
 
    // ---------------- Stimulus: randomized master + slave BFMs ----------------
    task automatic drive_input_beat(input logic [ADDR_WIDTH-1:0] addr, input logic last);
        @(negedge aclk);
        s_axis_tdata  <= addr;
        s_axis_tlast  <= last;
        s_axis_tvalid <= 1'b1;
        @(negedge aclk);
        while (!s_axis_tready) @(negedge aclk); // hold stable until accepted (AXI-Stream master rule)
        s_axis_tvalid <= 1'b0;
        @(negedge aclk); // let the nonblocking clear above actually settle before returning
    endtask
 
    // Randomized slave-side backpressure: toggles m_axis_tready every cycle.
    // Driven with a NONBLOCKING assignment at posedge -- same timing
    // discipline as a real registered "ready" signal in hardware, so it's
    // stable for the DUT's combinational logic all cycle and safe for the
    // negedge-sampled monitors above to read without a race.
    initial m_axis_tready = 0;
    always @(posedge aclk) m_axis_tready <= ($urandom_range(0, 99) < 70); // ~70% ready
 
    // Occasional runtime LUT reconfiguration, gated to only happen when no
    // input beat is in flight this cycle (per the documented read/write
    // collision caveat in axis_log_lut.sv).
    task automatic maybe_do_cfg_write();
        if (!s_axis_tvalid && $urandom_range(0, 9) == 0) begin
            logic [ADDR_WIDTH-1:0] a = $urandom_range(0, (1<<ADDR_WIDTH)-1);
            logic [DATA_WIDTH-1:0] d = $urandom;
            @(negedge aclk);
            cfg_wr_addr <= a;
            cfg_wr_data <= d;
            cfg_wr_en   <= 1'b1;
            golden_mem[a] = d; // update shadow in lockstep
            saw_cfg_write = 1;
            @(negedge aclk);
            cfg_wr_en <= 1'b0;
        end
    endtask
 
    initial begin
        aresetn = 0;
        s_axis_tvalid <= 0; s_axis_tdata <= 0; s_axis_tlast <= 0;
        cfg_wr_en <= 0; cfg_wr_addr <= 0; cfg_wr_data <= 0;
        repeat (5) @(negedge aclk);
        aresetn = 1;
        @(negedge aclk);
 
        for (int i = 0; i < NUM_TRANSFERS; i++) begin
            maybe_do_cfg_write();
 
            // Randomized idle gap before this transfer, to exercise s_axis_tvalid
            // deassertion between beats (not just back-to-back streaming).
            if ($urandom_range(0, 4) == 0) begin
                saw_idle_input = 1;
                repeat ($urandom_range(1, 3)) @(negedge aclk);
            end
 
            drive_input_beat($urandom_range(0, (1<<ADDR_WIDTH)-1), (i % 128 == 127));
        end
 
        // Drain: wait until every pushed expectation has been popped.
        repeat (20) @(negedge aclk);
        while (exp_data_q.size() > 0) @(negedge aclk);
        repeat (5) @(negedge aclk);
 
        $display("");
        $display("=== pushed=%0d popped=%0d errors=%0d ===", pushed, popped, errors);
        $display("=== coverage: backpressure_input=%0b output_stall=%0b idle_input=%0b cfg_write=%0b ===",
                   saw_backpressure_input, saw_output_stall, saw_idle_input, saw_cfg_write);
 
        if (pushed != popped) begin
            $display("FAIL: pushed/popped count mismatch (%0d vs %0d)", pushed, popped);
            errors++;
        end
        if (!saw_backpressure_input) begin $display("FAIL: never exercised input-side backpressure"); errors++; end
        if (!saw_output_stall)       begin $display("FAIL: never exercised output-side stall");        errors++; end
        if (!saw_idle_input)         begin $display("FAIL: never exercised idle input gaps");           errors++; end
        if (!saw_cfg_write)          begin $display("FAIL: never exercised runtime cfg reconfiguration"); errors++; end
 
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else              $display("=== TESTS FAILED (%0d errors) ===", errors);
        $finish;
    end
 
endmodule
 
