`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12.08.2026 23:15:23
// Design Name: 
// Module Name: tb_fir_2d
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

module tb_fir_2d_wavelet_golden;
 
    localparam int DATA_WIDTH    = 16;
    localparam int MAX_IMG_WIDTH = 512;
 
    logic clk = 0;
    logic rst_n;
    logic [$clog2(MAX_IMG_WIDTH)-1:0] img_width_m1;
    logic [DATA_WIDTH-1:0] s_axis_tdata;
    logic s_axis_tvalid, s_axis_tready, s_axis_tlast;
    logic [DATA_WIDTH-1:0] m_axis_lh_tdata, m_axis_hl_tdata;
    logic m_axis_tvalid, m_axis_tready, m_axis_tlast;
 
    fir_2d_wavelet_engine #(.DATA_WIDTH(DATA_WIDTH), .MAX_IMG_WIDTH(MAX_IMG_WIDTH)) dut (
        .aclk(clk), .aresetn(rst_n),
        .img_width_m1(img_width_m1),
        .s_axis_tdata(s_axis_tdata), .s_axis_tvalid(s_axis_tvalid), .s_axis_tready(s_axis_tready),
        .s_axis_tlast(s_axis_tlast),
        .m_axis_lh_tdata(m_axis_lh_tdata), .m_axis_hl_tdata(m_axis_hl_tdata),
        .m_axis_tvalid(m_axis_tvalid), .m_axis_tlast(m_axis_tlast), .m_axis_tready(m_axis_tready)
    );
 
    always #5 clk = ~clk;
 
    // ---------------- Scoreboard ----------------
    logic [DATA_WIDTH-1:0] exp_lh_q[$];
    logic [DATA_WIDTH-1:0] exp_hl_q[$];
    int pushed = 0, popped = 0, errors = 0;
    bit saw_backpressure_input = 0;
    bit saw_output_stall       = 0;
    bit saw_idle_input         = 0;
 
    // Pipeline "pending" state -- module level so it survives across
    // back-to-back run_frame calls that don't flush/reset between them
    // (matching real hardware: the next frame's own pixel 0 is what
    // actually drains the previous frame's last pixel, not an artificial
    // flush transfer).
    bit pending_valid = 0;
    logic [DATA_WIDTH-1:0] pending_lh, pending_hl;
 
    // Expected value for whichever pixel the driver is CURRENTLY presenting
    // on s_axis_tdata. Set by run_frame just before each accept; read here
    // by a dedicated monitor. Keeping push logic in its own always block
    // (rather than inline in the sequential driver task) avoids a same-edge
    // execution-order race against the pop monitor below -- confirmed via
    // direct trace: an inline push and the pop monitor landing on the same
    // negedge produced a nondeterministic scoreboard misalignment.
    logic [DATA_WIDTH-1:0] cur_exp_lh, cur_exp_hl;
 
    always @(negedge clk) begin
        if (rst_n && s_axis_tvalid && s_axis_tready) begin
            if (pending_valid) begin
                exp_lh_q.push_back(pending_lh);
                exp_hl_q.push_back(pending_hl);
                pushed++;
            end
            pending_lh    <= cur_exp_lh;
            pending_hl    <= cur_exp_hl;
            pending_valid <= 1'b1;
        end
        if (rst_n && s_axis_tvalid && !s_axis_tready) saw_backpressure_input = 1;
        if (rst_n && m_axis_tvalid && !m_axis_tready) saw_output_stall = 1;
    end
 
    always @(negedge clk) begin
        logic [DATA_WIDTH-1:0] e_lh, e_hl;
        if (rst_n && m_axis_tvalid && m_axis_tready) begin
            popped++;
            if (exp_lh_q.size() == 0) begin
                $error("SCOREBOARD UNDERFLOW at popped=%0d", popped);
                errors++;
            end else begin
                e_lh = exp_lh_q.pop_front();
                e_hl = exp_hl_q.pop_front();
                if (m_axis_lh_tdata !== e_lh) begin
                    $error("LH MISMATCH: got=%0d exp=%0d", m_axis_lh_tdata, e_lh);
                    errors++;
                end
                if (m_axis_hl_tdata !== e_hl) begin
                    $error("HL MISMATCH: got=%0d exp=%0d", m_axis_hl_tdata, e_hl);
                    errors++;
                end
            end
        end
    end
 
    // ---------------- Protocol assertions ----------------
`ifdef __ICARUS__
    logic prev_valid, prev_ready;
    logic [DATA_WIDTH-1:0] prev_lh, prev_hl;
    always @(negedge clk) begin
        if (rst_n) begin
            if (prev_valid && !prev_ready) begin
                assert (m_axis_tvalid) else $error("SVA(icarus): tvalid dropped while stalled");
                assert (m_axis_lh_tdata === prev_lh) else $error("SVA(icarus): lh changed while stalled");
                assert (m_axis_hl_tdata === prev_hl) else $error("SVA(icarus): hl changed while stalled");
            end
            if (m_axis_tvalid) begin
                assert (!$isunknown(m_axis_lh_tdata)) else $error("SVA(icarus): X on lh while tvalid");
                assert (!$isunknown(m_axis_hl_tdata)) else $error("SVA(icarus): X on hl while tvalid");
            end
        end
        prev_valid <= m_axis_tvalid;
        prev_ready <= m_axis_tready;
        prev_lh    <= m_axis_lh_tdata;
        prev_hl    <= m_axis_hl_tdata;
    end
`else
    // Real deliverable for Vivado XSim / QuestaSim.
    property p_valid_stable_until_ready;
        @(posedge clk) disable iff (!rst_n)
        (m_axis_tvalid && !m_axis_tready) |=> m_axis_tvalid;
    endproperty
    assert property (p_valid_stable_until_ready)
        else $error("SVA: m_axis_tvalid dropped before m_axis_tready sampled high");
 
    property p_data_stable_until_ready;
        @(posedge clk) disable iff (!rst_n)
        (m_axis_tvalid && !m_axis_tready) |=> $stable(m_axis_lh_tdata) && $stable(m_axis_hl_tdata);
    endproperty
    assert property (p_data_stable_until_ready)
        else $error("SVA: lh/hl changed while stalled");
 
    property p_no_x_on_valid_data;
        @(posedge clk) disable iff (!rst_n)
        m_axis_tvalid |-> !$isunknown(m_axis_lh_tdata) && !$isunknown(m_axis_hl_tdata);
    endproperty
    assert property (p_no_x_on_valid_data)
        else $error("SVA: unknown (X) bits on lh/hl while m_axis_tvalid high");
 
    property p_reset_clears_valid;
        @(posedge clk) !rst_n |-> !m_axis_tvalid;
    endproperty
    assert property (p_reset_clears_valid)
        else $error("SVA: m_axis_tvalid asserted during reset");
 
    property p_width_in_range;
        @(posedge clk) disable iff (!rst_n)
        (s_axis_tvalid && s_axis_tready) |-> (img_width_m1 < MAX_IMG_WIDTH);
    endproperty
    assert property (p_width_in_range)
        else $error("SVA: img_width_m1 out of range for this instance's MAX_IMG_WIDTH");
`endif
 
    // ---------------- Randomized slave-side backpressure ----------------
    initial m_axis_tready = 0;
    always @(posedge clk) m_axis_tready <= ($urandom_range(0, 99) < 70);
 
    // ---------------- Frame generation + streaming ----------------
    // pattern: 0=random, 1=horizontal ramp, 2=checkerboard, 3=constant-per-row
    task automatic run_frame(input int width, input int height, input int pattern, input string label,
                              input bit assert_reset, input bit do_flush);
        logic [DATA_WIDTH-1:0] pix   [0:511][0:511]; // [row][col], bounded by MAX_IMG_WIDTH/test height
        logic [DATA_WIDTH-1:0] exp_lh[0:511][0:511];
        logic [DATA_WIDTH-1:0] exp_hl[0:511][0:511];
 
        $display("--- Frame: %s  (width=%0d height=%0d pattern=%0d) ---", label, width, height, pattern);
 
        // 1) Generate pixel data per pattern.
        for (int r = 0; r < height; r++) begin
            for (int c = 0; c < width; c++) begin
                case (pattern)
                    0: pix[r][c] = $urandom_range(0, (1<<DATA_WIDTH)-1);
                    1: pix[r][c] = (r * 50 + c * 10) & 16'hFFFF;
                    2: pix[r][c] = ((r + c) % 2 == 0) ? 16'd1000 : 16'd9000;
                    3: pix[r][c] = (r * 33) & 16'hFFFF; // constant across each row
                    default: pix[r][c] = 0;
                endcase
            end
        end
 
        // 2) Pure-spec golden reference, independent of DUT implementation.
        for (int r = 0; r < height; r++) begin
            for (int c = 0; c < width; c++) begin
                exp_hl[r][c] = (r == 0) ? 16'd0 :
                               (pix[r][c] > pix[r-1][c]) ? (pix[r][c]-pix[r-1][c]) : (pix[r-1][c]-pix[r][c]);
                exp_lh[r][c] = (c == 0) ? 16'd0 :
                               (pix[r][c] > pix[r][c-1]) ? (pix[r][c]-pix[r][c-1]) : (pix[r][c-1]-pix[r][c]);
            end
        end
 
        // 3) Reset before each frame UNLESS this frame is relying purely on
        //    the previous frame's tlast to have already re-armed state (the
        //    real, DMA-practical mechanism -- see DUT header comment). A
        //    real reset also wipes any not-yet-emitted pipeline content, so
        //    clear the testbench's own pending-expectation tracking to match.
        img_width_m1 = (width - 1);
        if (assert_reset) begin
            rst_n = 0;
            s_axis_tvalid = 0;
            repeat (3) @(negedge clk);
            rst_n = 1;
            @(negedge clk);
            pending_valid = 0;
        end
 
        // 4) Stream row-major, with randomized idle gaps. The pipeline has
        //    1 cycle of latency: the output produced when accepting pixel k
        //    corresponds to pixel (k-1), not pixel k itself (see DUT header
        //    comment on `primed`). The dedicated push monitor above handles
        //    the "pending" delay-by-one bookkeeping; this loop just presents
        //    each pixel's data AND its expected result together, and waits
        //    for acceptance. `pending` is module-level, so in a true
        //    back-to-back (no-flush) sequence it carries over: the NEXT
        //    frame's own pixel 0 naturally drains THIS frame's last pixel,
        //    exactly like real continuous DMA streaming -- an artificial
        //    flush transfer here would corrupt col_ptr for the next frame
        //    (confirmed: this was a real bug, now avoided).
        for (int r = 0; r < height; r++) begin
            for (int c = 0; c < width; c++) begin
                if ($urandom_range(0, 4) == 0) begin
                    saw_idle_input = 1;
                    repeat ($urandom_range(1, 3)) @(negedge clk);
                end
                @(negedge clk);
                s_axis_tdata  <= pix[r][c];
                s_axis_tvalid <= 1'b1;
                s_axis_tlast  <= (r == height-1) && (c == width-1);
                cur_exp_lh    <= exp_lh[r][c];
                cur_exp_hl    <= exp_hl[r][c];
                @(negedge clk);
                while (!s_axis_tready) @(negedge clk);
 
                s_axis_tvalid <= 1'b0;
                s_axis_tlast  <= 1'b0;
                @(negedge clk); // let nonblocking clear settle
            end
        end
 
        // Flush ONLY when requested (this frame is the last in its
        // back-to-back run, or is immediately followed by a reset/end of
        // test) -- otherwise leave `pending` set so the NEXT frame's own
        // pixel 0 drains it naturally. The flush's own acceptance triggers
        // the push monitor to push whatever was pending (the final real
        // pixel's expected value) exactly like any other accept -- no
        // special-case push needed here.
        if (do_flush) begin
            @(negedge clk);
            s_axis_tdata  <= '0;
            s_axis_tvalid <= 1'b1;
            s_axis_tlast  <= 1'b0;
            @(negedge clk);
            while (!s_axis_tready) @(negedge clk);
            s_axis_tvalid <= 1'b0;
            @(negedge clk); // let nonblocking clear settle, and let the push monitor run
            pending_valid = 0; // the flush's own (garbage) data must never become a future pending
        end
 
        // 5) Drain.
        repeat (20) @(negedge clk);
        while (exp_lh_q.size() > 0) @(negedge clk);
        repeat (5) @(negedge clk);
 
        $display("--- %s done: pushed=%0d popped=%0d errors_so_far=%0d ---", label, pushed, popped, errors);
    endtask
 
    initial begin
        run_frame(128, 20, 0, "128-wide random",             1, 1);
        run_frame(256, 12, 1, "256-wide horizontal ramp",     1, 1);
        run_frame(128, 15, 2, "128-wide checkerboard",        1, 1);
        run_frame(256, 10, 3, "256-wide constant-per-row",    1, 1);
        run_frame(512, 6,  0, "512-wide random (max width)",  1, 1);
 
        // The real-world scenario: multiple independent images streamed
        // back-to-back through a continuous DMA feed, with NO reset pulse
        // between them -- only tlast marking each image boundary, and no
        // artificial flush between images either (the next image's own
        // pixel 0 drains the previous image's last pixel, exactly like real
        // hardware). Only the LAST image in the chain needs an explicit
        // flush, since nothing follows it to drain it naturally.
        run_frame(128, 8, 0, "back-to-back image 1 of 3 (tlast re-arm, no reset)", 1, 0);
        run_frame(128, 8, 1, "back-to-back image 2 of 3 (tlast re-arm, no reset)", 0, 0);
        run_frame(128, 8, 2, "back-to-back image 3 of 3 (tlast re-arm, no reset)", 0, 1);
 
        $display("");
        $display("=== pushed=%0d popped=%0d errors=%0d ===", pushed, popped, errors);
        $display("=== coverage: backpressure_input=%0b output_stall=%0b idle_input=%0b ===",
                   saw_backpressure_input, saw_output_stall, saw_idle_input);
 
        if (pushed != popped) begin
            $display("FAIL: pushed/popped mismatch (%0d vs %0d)", pushed, popped);
            errors++;
        end
        if (!saw_backpressure_input) begin $display("FAIL: never exercised input-side backpressure"); errors++; end
        if (!saw_output_stall)       begin $display("FAIL: never exercised output-side stall");        errors++; end
        if (!saw_idle_input)         begin $display("FAIL: never exercised idle input gaps");           errors++; end
 
        if (errors == 0) $display("=== ALL TESTS PASSED ===");
        else              $display("=== TESTS FAILED (%0d errors) ===", errors);
        $finish;
    end
 
endmodule
 
 