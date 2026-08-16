`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 
// Engineer: 
// 
// Create Date: 14.08.2026 12:46:45
// Design Name: 
// Module Name: Axis_log
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


module axis_log_lut #(
    parameter int ADDR_WIDTH = 12,   // 4096-entry LUT, indexed by raw 12-bit pixel
    parameter int DATA_WIDTH = 16    // Q4.12 fixed-point output
)(
    input  logic                     aclk,
    input  logic                     aresetn,        // active-low, synchronous
 
    // ---- AXI4-Stream slave: raw pixel in (from AXI DMA, MM2S) ----
    input  logic [ADDR_WIDTH-1:0]    s_axis_tdata,
    input  logic                     s_axis_tvalid,
    output logic                     s_axis_tready,
    input  logic                     s_axis_tlast,
 
    // ---- AXI4-Stream master: log-domain pixel out (to 2D wavelet engine) ----
    output logic [DATA_WIDTH-1:0]    m_axis_tdata,
    output logic                     m_axis_tvalid,
    input  logic                     m_axis_tready,
    output logic                     m_axis_tlast,
 
    // ---- Config write port: LUT reload from host (Integration Point 3) ----
    // Intended to be driven by an AXI4-Lite -> simple-write-port adapter
    // (e.g. Vivado's AXI4-Lite IPIF wrapper generated when packaging this as an IP).
    input  logic                     cfg_wr_en,
    input  logic [ADDR_WIDTH-1:0]    cfg_wr_addr,
    input  logic [DATA_WIDTH-1:0]    cfg_wr_data
);
 
    localparam int DEPTH = 1 << ADDR_WIDTH;
 
    // True dual-port BRAM: port A = streaming read, port B = config write.
    // ram_style attribute nudges Vivado synthesis to map this to a BRAM
    // primitive rather than distributed LUTRAM.
    (* ram_style = "block" *) logic [DATA_WIDTH-1:0] lut_mem [0:DEPTH-1];
 
    initial begin
        $readmemh("log_lut_q4_12.mem", lut_mem);
    end
 
    // ---- Single-stage pipeline (BRAM read latency = 1 cycle) ----
    logic                     stage_valid;
    logic                     stage_last;
    logic [DATA_WIDTH-1:0]    stage_data;
 
    logic fire_in, fire_out;
    assign fire_in  = s_axis_tvalid && s_axis_tready;
    assign fire_out = m_axis_tvalid && m_axis_tready;
 
    // Accept new input whenever the output stage is draining this cycle,
    // or whenever the output stage is currently empty.
    assign s_axis_tready = m_axis_tready || !stage_valid;
 
    always_ff @(posedge aclk) begin
        if (!aresetn) begin
            stage_valid <= 1'b0;
            stage_last  <= 1'b0;
            stage_data  <= '0;
        end else begin
            if (fire_in) begin
                stage_data  <= lut_mem[s_axis_tdata];
                stage_last  <= s_axis_tlast;
                stage_valid <= 1'b1;
            end else if (fire_out) begin
                stage_valid <= 1'b0;
            end
 
            // Config write on port B - independent of the streaming read on port A.
            // If cfg_wr_addr happens to equal s_axis_tdata on the same cycle,
            // behavior is BRAM-primitive-dependent (read-old vs read-new) -
            // avoid reconfiguring the LUT while the stream is actively running.
            if (cfg_wr_en) begin
                lut_mem[cfg_wr_addr] <= cfg_wr_data;
            end
        end
    end
 
    assign m_axis_tdata  = stage_data;
    assign m_axis_tvalid = stage_valid;
    assign m_axis_tlast  = stage_last;
 
endmodule
 