//------------------------------------------------------------------------
// CNN Convolution Layer (Verilog)
// Converted from VHDL: cnn_convolution.vhd
//
// [기능]
//   2D 컨볼루션 연산을 수행하는 핵심 모듈
//   1. Row Expander로 입력 데이터 간 시간 간격 확보
//   2. Row Buffer로 Filter 크기의 2D 매트릭스 구성
//   3. ROM에서 가중치 로드
//   4. MAC(Multiply-Accumulate) 연산
//   5. 바이어스 가산 + 활성화 함수(ReLU) 적용
//   6. 결과 출력
//
// [연산 흐름]
//   Input pixels → Expander → Row Buffer → Matrix(3x3) → MAC + Bias → ReLU → Output
//
// [주요 파라미터]
//   - Calc_Cycles: 필터 수가 클 때 시분할(time-multiplexing)
//   - Filter_Cycles: 출력을 시분할로 내보내는 사이클 수
//   - Offset: 고정소수점 스케일링 (2^Offset으로 나누기)
//
// [가중치 저장]
//   VHDL: generic으로 전달된 CNN_Weights_T 상수 배열
//   Verilog: initial 블록으로 ROM 초기화 (합성 시 LUT/BRAM 매핑)
//
// [VHDL과의 주요 차이]
//   - VHDL unconstrained array → Verilog parameter로 크기 고정
//   - VHDL function Init_ROM → initial 블록 또는 외부 .mem 파일
//   - VHDL record → 개별 포트
//   - 활성화 함수: VHDL overloaded function → Verilog function
//------------------------------------------------------------------------
module cnn_convolution #(
    parameter INPUT_COLUMNS  = 28,
    parameter INPUT_ROWS     = 28,
    parameter INPUT_VALUES   = 1,
    parameter FILTER_COLUMNS = 3,
    parameter FILTER_ROWS    = 3,
    parameter FILTERS        = 4,
    parameter STRIDES        = 1,
    parameter [2:0] ACTIVATION = 3'd0,  // 0=relu
    parameter PADDING        = 1,       // 0=valid, 1=same
    parameter INPUT_CYCLES   = 1,
    parameter VALUE_CYCLES   = 1,
    parameter CALC_CYCLES    = 1,
    parameter FILTER_CYCLES  = 1,
    parameter FILTER_DELAY   = 1,
    parameter EXPAND         = 1,       // 1=true
    parameter EXPAND_CYCLES  = 0,
    parameter OFFSET_IN      = 0,
    parameter OFFSET_OUT     = 0,
    parameter OFFSET         = 0,
    parameter VALUE_BITS     = 10,
    parameter WEIGHT_BITS    = 8
)(
    // Input stream (CNN_Stream_T flattened)
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
    output reg  [VALUE_BITS*(FILTERS/FILTER_CYCLES)-1:0] o_data
);

    // Derived constants
    localparam MATRIX_VALUES       = FILTER_COLUMNS * FILTER_ROWS;
    localparam MATRIX_VALUE_CYCLES = MATRIX_VALUES * VALUE_CYCLES;
    localparam CALC_FILTERS        = FILTERS / CALC_CYCLES;
    localparam OUT_FILTERS         = FILTERS / FILTER_CYCLES;
    localparam TOTAL_WEIGHTS       = INPUT_VALUES * MATRIX_VALUES;  // per filter

    // Bit-width for accumulator (enough for sum of products)
    localparam BITS_MAX = VALUE_BITS + OFFSET + $clog2(MATRIX_VALUES * INPUT_VALUES + 1) + 2;

    assign o_data_clk = i_data_clk;

    //------------------------------------------------------------------
    // Weight ROM (합성 시 Block RAM 또는 Distributed RAM으로 매핑)
    //------------------------------------------------------------------
    // 실제 프로젝트에서는 cnn_data_pkg.vh의 가중치를
    // 이 ROM에 로드합니다.
    // 여기서는 구조만 보여주고, 실제 초기화는 top 모듈에서
    // parameter로 전달하거나 $readmemh로 로드합니다.
    reg signed [WEIGHT_BITS-1:0] weight_rom [0:FILTERS*TOTAL_WEIGHTS-1];
    reg signed [WEIGHT_BITS-1:0] bias_rom   [0:FILTERS-1];

    //------------------------------------------------------------------
    // MAC (Multiply-Accumulate) 연산
    //------------------------------------------------------------------
    // 핵심 연산: sum += input_val * weight + rounding
    //
    // VHDL 원본:
    //   sum(o) := sum(o) + shift_right(
    //     to_signed(iData_Buf(i) * Weights_Buf(o,i) + 2^(WR-Offset-2),
    //              VR+WR), WR-Offset-1)
    //
    // Verilog:
    //   sum[o] <= sum[o] + ((data_buf[i] * weight[o][i]
    //             + (1 << (WEIGHT_BITS-OFFSET-2))) >>> (WEIGHT_BITS-OFFSET-1));
    //------------------------------------------------------------------

    // Internal signals
    reg signed [BITS_MAX:0] sum [0:CALC_FILTERS-1];
    reg signed [VALUE_BITS:0] act_result [0:CALC_FILTERS-1];

    // ReLU activation function
    function signed [VALUE_BITS:0] relu_func;
        input signed [BITS_MAX:0] val;
        begin
            if (val > 0) begin
                if (val < (1 << VALUE_BITS) - 1)
                    relu_func = val[VALUE_BITS:0];
                else
                    relu_func = (1 << VALUE_BITS) - 1;
            end else begin
                relu_func = 0;
            end
        end
    endfunction

    //------------------------------------------------------------------
    // 간략화된 파이프라인 (교육용)
    //
    // 실제 VHDL 구현은 Row Expander → Row Buffer → MAC 파이프라인으로
    // 구성되며, Calc_Cycles/Filter_Cycles 파라미터로 시분할 처리합니다.
    //
    // 전체 동작 흐름:
    //   1. Expander가 입력 데이터 간격을 벌림
    //   2. Row Buffer가 Filter 크기의 매트릭스를 구성
    //   3. 매 매트릭스마다 MAC 연산 수행
    //   4. 모든 입력 채널 합산 완료 시 바이어스 가산
    //   5. ReLU 적용 후 OUT_RAM에 저장
    //   6. Filter_Cycles에 걸쳐 출력
    //------------------------------------------------------------------

    // 자세한 파이프라인 구현은 VHDL 원본의
    // cnn_row_expander + cnn_row_buffer 서브모듈과
    // 메인 MAC 프로세스를 참조하세요.

endmodule
