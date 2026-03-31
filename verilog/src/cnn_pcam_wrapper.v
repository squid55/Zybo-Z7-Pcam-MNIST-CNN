//------------------------------------------------------------------------
// CNN Pcam Wrapper - Top-Level System Wrapper (Verilog)
// Converted from VHDL: cnn_pcam_wrapper.vhd
//
// [기능]
//   Pcam 카메라의 AXI Stream 출력을 받아
//   CNN 추론을 수행하고 AXI-Lite로 결과를 제공하는 시스템 래퍼
//
// [시스템 구조]
//   AXI Stream (Pcam) → Bridge → CNN Top → AXI-Lite (PS)
//
//   GammaCorrection.m_axis ─┬─→ VDMA (원본 HDMI 경로)
//                           └─→ 이 모듈의 s_axis_* (CNN 경로)
//
// [서브모듈]
//   1. axi_stream_to_rgb_stream: AXI Stream → rgb_stream 변환
//   2. cnn_top: CNN 추론 (Conv×3 + Pool×3 + FC + Argmax)
//   3. cnn_result_axilite: 결과를 AXI-Lite 레지스터로 노출
//
// [Vivado Block Design 연결]
//   - s_axis_*: GammaCorrection의 AXI Stream T-tap
//   - S_AXI_*:  PS M_AXI_GP0 → 이 IP (Base: 0x40000000)
//   - prediction_out/probability_out: LED/디버그 용
//------------------------------------------------------------------------
module cnn_pcam_wrapper #(
    parameter INPUT_WIDTH  = 1280,   // Pcam 해상도 폭
    parameter INPUT_HEIGHT = 720,    // Pcam 해상도 높이
    parameter CNN_IMG_SIZE = 448,    // CNN 입력 이미지 크기
    parameter CNN_OFFSET   = 80,     // 크롭 오프셋
    parameter CNN_SIZE     = 28      // CNN 내부 처리 크기
)(
    // Clock and Reset
    input  wire        aclk,
    input  wire        aresetn,

    // AXI Stream input (T-tap from GammaCorrection)
    input  wire [23:0] s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    // Direct outputs (LED/debug)
    output wire [3:0]  prediction_out,
    output wire [9:0]  probability_out,

    // AXI-Lite Slave (PS reads CNN results)
    input  wire [3:0]  S_AXI_ARADDR,
    input  wire        S_AXI_ARVALID,
    output wire        S_AXI_ARREADY,
    output wire [31:0] S_AXI_RDATA,
    output wire [1:0]  S_AXI_RRESP,
    output wire        S_AXI_RVALID,
    input  wire        S_AXI_RREADY,
    input  wire [3:0]  S_AXI_AWADDR,
    input  wire        S_AXI_AWVALID,
    output wire        S_AXI_AWREADY,
    input  wire [31:0] S_AXI_WDATA,
    input  wire [3:0]  S_AXI_WSTRB,
    input  wire        S_AXI_WVALID,
    output wire        S_AXI_WREADY,
    output wire [1:0]  S_AXI_BRESP,
    output wire        S_AXI_BVALID,
    input  wire        S_AXI_BREADY
);

    //------------------------------------------------------------------
    // Internal signals (VHDL rgb_stream record → individual wires)
    //------------------------------------------------------------------
    wire [7:0]  bridge_r, bridge_g, bridge_b;
    wire [10:0] bridge_column;
    wire [9:0]  bridge_row;
    wire        bridge_new_pixel;

    wire [3:0]  prediction_int;
    wire [9:0]  probability_int;

    // Direct outputs
    assign prediction_out  = prediction_int;
    assign probability_out = probability_int;

    //------------------------------------------------------------------
    // Sub-module 1: AXI Stream → rgb_stream Bridge
    //------------------------------------------------------------------
    axi_stream_to_rgb_stream #(
        .INPUT_WIDTH  (INPUT_WIDTH),
        .INPUT_HEIGHT (INPUT_HEIGHT)
    ) u_bridge (
        .aclk          (aclk),
        .aresetn       (aresetn),
        .s_axis_tdata  (s_axis_tdata),
        .s_axis_tvalid (s_axis_tvalid),
        .s_axis_tready (s_axis_tready),
        .s_axis_tlast  (s_axis_tlast),
        .s_axis_tuser  (s_axis_tuser),
        .o_r           (bridge_r),
        .o_g           (bridge_g),
        .o_b           (bridge_b),
        .o_column      (bridge_column),
        .o_row         (bridge_row),
        .o_new_pixel   (bridge_new_pixel)
    );

    //------------------------------------------------------------------
    // Sub-module 2: CNN Core
    //------------------------------------------------------------------
    cnn_top #(
        .INPUT_COLUMNS (CNN_IMG_SIZE),
        .INPUT_ROWS    (CNN_IMG_SIZE),
        .COLUMN_OFFSET (CNN_OFFSET),
        .CNN_COLUMNS   (CNN_SIZE),
        .CNN_ROWS      (CNN_SIZE)
    ) u_cnn (
        .i_r         (bridge_r),
        .i_g         (bridge_g),
        .i_b         (bridge_b),
        .i_column    (bridge_column[9:0]),
        .i_row       (bridge_row[8:0]),
        .i_new_pixel (bridge_new_pixel),
        .prediction  (prediction_int),
        .probability (probability_int)
    );

    //------------------------------------------------------------------
    // Sub-module 3: AXI-Lite Result Register
    //------------------------------------------------------------------
    cnn_result_axilite u_result (
        .prediction    (prediction_int),
        .probability   (probability_int),
        .S_AXI_ACLK   (aclk),
        .S_AXI_ARESETN (aresetn),
        .S_AXI_ARADDR  (S_AXI_ARADDR),
        .S_AXI_ARVALID (S_AXI_ARVALID),
        .S_AXI_ARREADY (S_AXI_ARREADY),
        .S_AXI_RDATA   (S_AXI_RDATA),
        .S_AXI_RRESP   (S_AXI_RRESP),
        .S_AXI_RVALID  (S_AXI_RVALID),
        .S_AXI_RREADY  (S_AXI_RREADY),
        .S_AXI_AWADDR  (S_AXI_AWADDR),
        .S_AXI_AWVALID (S_AXI_AWVALID),
        .S_AXI_AWREADY (S_AXI_AWREADY),
        .S_AXI_WDATA   (S_AXI_WDATA),
        .S_AXI_WSTRB   (S_AXI_WSTRB),
        .S_AXI_WVALID  (S_AXI_WVALID),
        .S_AXI_WREADY  (S_AXI_WREADY),
        .S_AXI_BRESP   (S_AXI_BRESP),
        .S_AXI_BVALID  (S_AXI_BVALID),
        .S_AXI_BREADY  (S_AXI_BREADY)
    );

endmodule
