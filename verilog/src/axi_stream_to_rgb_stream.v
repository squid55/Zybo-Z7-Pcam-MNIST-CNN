//------------------------------------------------------------------------
// AXI Stream to RGB Stream Bridge (Verilog)
// Converted from VHDL: axi_stream_to_rgb_stream.vhd
//
// [기능]
//   Pcam GammaCorrection의 AXI Stream 출력(24-bit RGB888)을
//   CNN이 사용하는 rgb_stream 형식으로 변환
//   - AXI Stream → 개별 R/G/B + Column/Row + pixel_clk
//   - tuser(SOF), tlast(EOL)로 프레임/라인 동기화
//   - T-tap이므로 tready 항상 '1' (백프레셔 없음)
//
// [VHDL과의 차이]
//   VHDL의 rgb_stream record → 개별 output 포트로 평탄화
//------------------------------------------------------------------------
module axi_stream_to_rgb_stream #(
    parameter INPUT_WIDTH  = 1280,  // Pcam 입력 해상도 폭
    parameter INPUT_HEIGHT = 720    // Pcam 입력 해상도 높이
)(
    // AXI Stream input (from GammaCorrection T-tap)
    input  wire        aclk,
    input  wire        aresetn,
    input  wire [23:0] s_axis_tdata,   // [23:16]=R, [15:8]=G, [7:0]=B
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,    // End of Line
    input  wire        s_axis_tuser,    // Start of Frame

    // rgb_stream output (flattened from VHDL record)
    output reg  [7:0]  o_r,
    output reg  [7:0]  o_g,
    output reg  [7:0]  o_b,
    output reg  [10:0] o_column,       // max 1279
    output reg  [9:0]  o_row,          // max 719
    output reg         o_new_pixel      // pixel clock (CNN 구동 클럭)
);

    // T-tap: 메인 파이프라인을 차단하지 않도록 항상 ready
    assign s_axis_tready = 1'b1;

    reg [$clog2(INPUT_WIDTH)-1:0]  col_cnt;
    reg [$clog2(INPUT_HEIGHT)-1:0] row_cnt;
    reg pixel_clk;

    // pixel_clk을 출력으로 전달
    always @(*) o_new_pixel = pixel_clk;

    always @(posedge aclk) begin
        if (!aresetn) begin
            col_cnt   <= 0;
            row_cnt   <= 0;
            pixel_clk <= 1'b0;
            o_r       <= 8'd0;
            o_g       <= 8'd0;
            o_b       <= 8'd0;
            o_column  <= 0;
            o_row     <= 0;
        end else begin
            if (s_axis_tvalid) begin
                // RGB888 추출
                o_r <= s_axis_tdata[23:16];
                o_g <= s_axis_tdata[15:8];
                o_b <= s_axis_tdata[7:0];

                // 좌표 설정 (image_data_package 범위로 클램프)
                o_column <= (col_cnt < 646) ? col_cnt[10:0] : 11'd645;
                o_row    <= (row_cnt < 483) ? row_cnt[9:0]  : 10'd482;

                // 프레임/라인 동기화
                if (s_axis_tuser) begin
                    // SOF: 프레임 시작
                    col_cnt <= 0;
                    row_cnt <= 0;
                end else if (s_axis_tlast) begin
                    // EOL: 라인 끝
                    col_cnt <= 0;
                    if (row_cnt < INPUT_HEIGHT - 1)
                        row_cnt <= row_cnt + 1;
                end else begin
                    if (col_cnt < INPUT_WIDTH - 1)
                        col_cnt <= col_cnt + 1;
                end

                // CNN용 픽셀 클럭 토글 (매 유효 픽셀마다)
                pixel_clk <= ~pixel_clk;
            end
        end
    end

endmodule
