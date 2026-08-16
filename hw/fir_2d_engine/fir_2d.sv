`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 12.08.2026 23:13:04
// Design Name: 
// Module Name: fir_2d
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


module fir_2d_wavelet_engine #(
    parameter int DATA_WIDTH    = 16, // Q4.12 fixed point
    parameter int MAX_IMG_WIDTH = 512 // largest row width this instance is BUILT for (sizes the BRAM)
)(
    input  logic                  aclk,
    input  logic                  aresetn,
 
    // Runtime row width for THIS frame: set to (actual_image_width - 1),
    // e.g. 127 for a 128-wide image, 255 for 256-wide, 511 for 512-wide.
    // Intended to be driven from the same AXI4-Lite config path as the
    // log-LUT reload (Integration Point 3) -- set once per frame/dataset
    // sample before streaming pixels in. Must satisfy img_width_m1 < MAX_IMG_WIDTH.
    input  logic [$clog2(MAX_IMG_WIDTH)-1:0] img_width_m1,
 
    input  logic [DATA_WIDTH-1:0] s_axis_tdata,
    input  logic                  s_axis_tvalid,
    output logic                  s_axis_tready,
    input  logic                  s_axis_tlast,  // marks the LAST pixel of an image/frame
 
    output logic [DATA_WIDTH-1:0] m_axis_lh_tdata, // Horizontal detail (row-wise gradient)
    output logic [DATA_WIDTH-1:0] m_axis_hl_tdata, // Vertical detail (column-wise gradient)
    output logic                  m_axis_tvalid,
    output logic                  m_axis_tlast,
    input  logic                  m_axis_tready
);
 
    // Single line buffer: holds "pixel one row above, same column" using the
    // classic trick of writing every incoming pixel into line_buf[col_ptr]
    // and reading the OLD value (from img_width_m1+1 cycles ago) before it's
    // overwritten. Sized to the largest width this instance supports; smaller
    // runtime widths simply use a subset of the entries.
    logic [DATA_WIDTH-1:0] line_buf [0:MAX_IMG_WIDTH-1];
 
    logic [$clog2(MAX_IMG_WIDTH)-1:0] col_ptr;
    logic [DATA_WIDTH-1:0]  prev_col_pixel; // raw shift register: previous cycle's input pixel
 
    // line_buf is NOT cleared by aresetn (clearing BRAM costs a full extra row
    // of cycles, so this is standard practice) -- meaning row 0 of any frame
    // would otherwise read above_pixel from whatever the PREVIOUS frame left
    // behind. That's fine for continuous video, but wrong for independent
    // dataset samples: row 0 of image N would show a spurious vertical
    // "edge" against an unrelated pixel from image N-1's last row. This flag
    // gives row 0 of every frame a defined zero vertical-gradient baseline
    // instead, symmetric to how col_ptr==0 already handles the left edge.
    // Re-armed by aresetn -- reset (or an equivalent frame-boundary pulse)
    // MUST be asserted between independent images for this to take effect.
    logic first_row_of_frame;
 
    // The pipeline has 1 cycle of latency: the lh/hl computed on any given
    // cycle reflect cur_pixel/above_pixel/left_pixel as captured on the
    // PREVIOUS accepted cycle, not this one. That means the very FIRST
    // accepted pixel EVER (right after power-on/hard reset) produces an
    // output computed from whatever those registers held before ever being
    // loaded -- meaningless leftover data, not a real result. `primed`
    // suppresses m_axis_tvalid for exactly that one beat, so the DUT never
    // emits a beat that doesn't correspond to a real pixel. It is re-armed
    // ONLY by aresetn, not by tlast/frame boundaries: unlike power-on, a
    // frame boundary never leaves these registers holding garbage -- the
    // next frame's pixel 0 is immediately and correctly captured into them,
    // so no re-suppression is needed there (confirmed via golden-reference
    // testbench: an earlier version incorrectly re-armed primed via tlast
    // and ended up suppressing every subsequent frame's genuinely-valid
    // first beat). The one remaining tradeoff (standard for any pipelined
    // streaming IP): the LAST pixel's result only comes out after one extra
    // transfer past the end of the frame (either a flush, or in continuous
    // streaming, the next frame's own pixel 0), since it's still sitting in
    // the pipeline when the real input stream for that frame ends.
    logic primed;
 
    // Captured window taps for the pixel currently "in flight" through the
    // pipeline (one cycle behind s_axis_tdata).
    logic [DATA_WIDTH-1:0]  cur_pixel;      // this pixel
    logic [DATA_WIDTH-1:0]  above_pixel;    // row-1, same column
    logic [DATA_WIDTH-1:0]  left_pixel;     // same row, column-1 (0 gradient at row start)
    logic                   cur_last;       // this pixel's tlast, carried through the same 1-cycle delay
 
    assign s_axis_tready = m_axis_tready || !m_axis_tvalid;
 
    always_ff @(posedge aclk or negedge aresetn) begin
        if (!aresetn) begin
            col_ptr           <= '0;
            prev_col_pixel     <= '0;
            first_row_of_frame <= 1'b1;
            primed          <= 1'b0;
            m_axis_tvalid   <= 1'b0;
            m_axis_tlast    <= 1'b0;
            cur_last        <= 1'b0;
            m_axis_lh_tdata <= '0;
            m_axis_hl_tdata <= '0;
        end else if (s_axis_tvalid && s_axis_tready) begin
            // Capture this pixel's window taps BEFORE line_buf/prev_col_pixel
            // are overwritten below (non-blocking assignments all read the
            // pre-edge values, so this is safe regardless of statement order).
            cur_pixel   <= s_axis_tdata;
            cur_last    <= s_axis_tlast;
            // Row 0 of this frame: force a zero vertical gradient instead of
            // reading a previous frame's stale line_buf contents.
            above_pixel <= first_row_of_frame ? s_axis_tdata : line_buf[col_ptr];
            // At col_ptr==0 (start of a new row), prev_col_pixel still holds
            // the LAST pixel of the row above -- not a real left neighbor.
            // Substitute the current pixel itself so the horizontal gradient
            // reads 0 at the row boundary instead of a bogus cross-row diff.
            left_pixel  <= (col_ptr == 0) ? s_axis_tdata : prev_col_pixel;
 
            line_buf[col_ptr] <= s_axis_tdata;
            prev_col_pixel    <= s_axis_tdata;
            col_ptr <= (col_ptr == img_width_m1) ? '0 : col_ptr + 1'b1;
 
            // Frame-boundary handling: s_axis_tlast marks the LAST pixel of
            // THIS image. first_row_of_frame re-arms immediately (it gates
            // the NEXT accepted pixel's own window capture, which is correct
            // to base on THIS pixel's own tlast).
            if (s_axis_tlast) begin
                first_row_of_frame <= 1'b1;
            end else if (col_ptr == img_width_m1) begin
                first_row_of_frame <= 1'b0;
            end
 
            // Output stage: computed from cur_pixel/above_pixel/left_pixel as
            // they stood BEFORE this edge -- i.e. the window captured on the
            // previous cycle. Because this assignment and m_axis_tvalid are
            // in the same block, data and valid always update together, so
            // there's no cross-block skew between them.
            m_axis_lh_tdata <= (cur_pixel > left_pixel)  ? (cur_pixel - left_pixel)  : (left_pixel  - cur_pixel);
            m_axis_hl_tdata <= (cur_pixel > above_pixel) ? (cur_pixel - above_pixel) : (above_pixel - cur_pixel);
            m_axis_tlast    <= cur_last;
            m_axis_tvalid   <= primed; // suppress the first (garbage-window) beat -- ONCE EVER, after power-on reset
            // `primed` is NOT re-armed at frame boundaries: unlike power-on
            // (where cur_pixel/above/left genuinely hold undefined data
            // before the first-ever pixel loads), a frame boundary via
            // tlast never produces garbage -- the next frame's pixel 0 is
            // immediately and correctly captured into these same registers.
            // Re-arming primed here (an earlier version of this code did,
            // using cur_last) incorrectly suppressed every subsequent
            // frame's genuinely-valid first beat -- caught by golden-
            // reference testbench comparison across a real frame boundary.
            primed          <= 1'b1;
        end else if (m_axis_tvalid && !m_axis_tready) begin
            // Real stall: consumer hasn't accepted the current beat yet.
            // AXI4-Stream requires tvalid to stay high with STABLE data until
            // tready is sampled high -- so hold here, touching nothing else.
            // (Without this branch, the prior code fell through to the
            // unconditional "else: m_axis_tvalid <= 0" below and silently
            // dropped the pending beat the moment no NEW input was accepted
            // in the same cycle -- a real data-loss bug under backpressure,
            // caught by golden-reference testbench assertions.)
            m_axis_tvalid <= 1'b1;
        end else begin
            m_axis_tvalid <= 1'b0;
        end
    end
 
endmodule
 

 
