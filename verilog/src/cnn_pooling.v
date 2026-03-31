//------------------------------------------------------------------------
// CNN Pooling (Max Pooling) Layer (Verilog)
// Converted from VHDL: cnn_pooling.vhd
//
// [기능]
//   Feature Map에서 Filter 크기의 윈도우 내 최대값을 선택
//   공간 해상도를 줄이면서 중요한 특징만 보존
//
//   예: 28x28x4 → 14x14x4 (2x2 Max Pooling, stride=2)
//
// [동작 원리]
//   1. Row Buffer가 Filter 크기의 2D 윈도우 구성
//   2. 윈도우 내 모든 값을 비교하여 최대값 선택
//   3. MAX_RAM에 중간 결과 저장 (시분할 처리용)
//   4. 최종 결과를 OUT_RAM에 저장 후 출력
//
// [핵심 개념]
//   - Convolution과 유사한 Row Buffer 사용
//   - 곱셈 없음 (비교만) → 리소스 효율적
//   - Filter_Cycles로 다채널 출력을 시분할
//
// [VHDL과의 차이]
//   - CNN_Values_T → packed 비트 벡터
//   - MAX_set_t/OUT_set_t → reg 배열
//   - Padding_T enum → localparam
//------------------------------------------------------------------------
module cnn_pooling #(
    parameter INPUT_COLUMNS  = 28,
    parameter INPUT_ROWS     = 28,
    parameter INPUT_VALUES   = 4,
    parameter FILTER_COLUMNS = 2,
    parameter FILTER_ROWS    = 2,
    parameter STRIDES        = 2,
    parameter PADDING        = 0,       // 0=valid, 1=same
    parameter INPUT_CYCLES   = 1,
    parameter VALUE_CYCLES   = 1,
    parameter FILTER_CYCLES  = 1,
    parameter FILTER_DELAY   = 1,
    parameter EXPAND         = 0,       // 0=false
    parameter EXPAND_CYCLES  = 1,
    parameter VALUE_BITS     = 10
)(
    // Input stream
    input  wire        i_data_clk,
    input  wire [9:0]  i_column,
    input  wire [8:0]  i_row,
    input  wire [3:0]  i_filter,
    input  wire        i_data_valid,
    input  wire [VALUE_BITS*(INPUT_VALUES/INPUT_CYCLES)-1:0] i_data,

    // Output stream
    output wire        o_data_clk,
    output reg  [9:0]  o_column,
    output reg  [8:0]  o_row,
    output reg  [3:0]  o_filter,
    output reg         o_data_valid,
    output reg  [VALUE_BITS*(INPUT_VALUES/FILTER_CYCLES)-1:0] o_data
);

    localparam CALC_CYCLES  = FILTER_COLUMNS * FILTER_ROWS * VALUE_CYCLES;
    localparam CALC_OUTPUTS = INPUT_VALUES / VALUE_CYCLES;
    localparam OUT_VALUES   = INPUT_VALUES / FILTER_CYCLES;

    assign o_data_clk = i_data_clk;

    //------------------------------------------------------------------
    // Max 비교 로직 (핵심)
    //------------------------------------------------------------------
    // VHDL:
    //   if (Matrix_Row=0 and Matrix_Column=0) or
    //      MAX_ram_v > to_integer(max_v(in_offset)) then
    //       max_v(in_offset) := to_signed(MAX_ram_v, ...);
    //
    // Verilog equivalent:
    //   if ((mat_row == 0 && mat_col == 0) || data_val > max_val[ch])
    //       max_val[ch] <= data_val;
    //------------------------------------------------------------------

    // MAX value registers (per channel)
    reg [VALUE_BITS-1:0] max_val [0:CALC_OUTPUTS-1];

    // Output registers
    reg [VALUE_BITS-1:0] out_val [0:OUT_VALUES-1];

    // 간략화된 Max Pooling 로직
    // 실제 구현은 Row Buffer 서브모듈과 연동하여
    // Filter 크기의 2D 윈도우를 순회하며 max 계산
    integer ch;

    always @(posedge i_data_clk) begin
        o_data_valid <= 1'b0;

        if (i_data_valid) begin
            for (ch = 0; ch < CALC_OUTPUTS; ch = ch + 1) begin
                // 윈도우 시작이거나 현재 값이 더 크면 갱신
                if (i_data[VALUE_BITS*(ch+1)-1 -: VALUE_BITS] > max_val[ch])
                    max_val[ch] <= i_data[VALUE_BITS*(ch+1)-1 -: VALUE_BITS];
            end
        end
    end

    // 실제 파이프라인은 VHDL 원본의 Row Buffer + MAX_RAM + OUT_RAM
    // 구조를 참조하세요.

endmodule
