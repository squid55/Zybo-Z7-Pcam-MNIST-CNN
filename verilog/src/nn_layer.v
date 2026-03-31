//------------------------------------------------------------------------
// NN Layer - Fully Connected Layer (Verilog)
// Converted from VHDL: nn_layer.vhd
//
// [기능]
//   전결합(Fully Connected) 레이어 연산
//   모든 입력 뉴런과 모든 출력 뉴런 사이의 가중치 곱을 합산
//
//   이 프로젝트에서는:
//   - 입력: 72개 (3x3x8 = Flatten 결과)
//   - 출력: 10개 (숫자 0~9 각 클래스의 점수)
//   - 가중치: 72*10 + 10(bias) = 730개
//
// [동작 원리]
//   1. 입력이 시분할(Calc_Cycles_In)로 들어옴
//   2. ROM에서 가중치 로드
//   3. MAC(Multiply-Accumulate) 연산
//   4. 모든 입력 처리 완료 시 바이어스 가산
//   5. ReLU 활성화 적용
//   6. OUT_RAM에 저장 후 시분할 출력
//
// [Convolution과의 차이]
//   - Row Buffer 불필요 (공간 구조 없음)
//   - 1D 입력 → 1D 출력
//   - iCycle로 시분할 입력 위치 지정
//
// [VHDL과의 차이]
//   - CNN_Weights_T generic → ROM + parameter
//   - oCycle: natural range → bit vector
//------------------------------------------------------------------------
module nn_layer #(
    parameter INPUTS          = 72,
    parameter OUTPUTS         = 10,
    parameter [2:0] ACTIVATION = 3'd0,  // 0=relu
    parameter CALC_CYCLES_IN  = 72,
    parameter OUT_CYCLES      = 10,
    parameter OUT_DELAY       = 1,
    parameter CALC_CYCLES_OUT = 10,
    parameter OFFSET_IN       = 0,
    parameter OFFSET_OUT      = 0,
    parameter OFFSET          = 0,
    parameter VALUE_BITS      = 10,
    parameter WEIGHT_BITS     = 8
)(
    // Input stream
    input  wire        i_data_clk,
    input  wire        i_data_valid,
    input  wire [VALUE_BITS*(INPUTS/CALC_CYCLES_IN)-1:0] i_data,
    input  wire [$clog2(CALC_CYCLES_IN)-1:0] i_cycle,

    // Output stream
    output wire        o_data_clk,
    output reg         o_data_valid,
    output reg  [VALUE_BITS*(OUTPUTS/CALC_CYCLES_OUT)-1:0] o_data,
    output reg  [$clog2(OUTPUTS)-1:0] o_cycle
);

    localparam CALC_OUTPUTS = OUTPUTS / OUT_CYCLES;
    localparam CALC_INPUTS  = INPUTS / CALC_CYCLES_IN;
    localparam OUT_VALUES   = OUTPUTS / CALC_CYCLES_OUT;
    localparam OFFSET_DIFF  = OFFSET_OUT - OFFSET_IN;
    localparam VALUE_MAX    = (1 << VALUE_BITS) - 1;
    localparam BITS_MAX     = VALUE_BITS + ((OFFSET > 0) ? OFFSET : 0) + $clog2(INPUTS + 1) + 2;

    assign o_data_clk = i_data_clk;

    //------------------------------------------------------------------
    // Weight ROM
    //------------------------------------------------------------------
    // 가중치 배열: [OUTPUTS][INPUTS+1] (마지막 = bias)
    // 실제 초기화는 cnn_data_pkg.vh의 NN1_W 사용
    reg signed [WEIGHT_BITS-1:0] weight_rom [0:OUTPUTS*(INPUTS+1)-1];
    reg signed [WEIGHT_BITS-1:0] bias_rom   [0:OUTPUTS-1];

    //------------------------------------------------------------------
    // MAC 연산
    //------------------------------------------------------------------
    reg signed [BITS_MAX:0] sum [0:CALC_OUTPUTS-1];
    reg signed [VALUE_BITS:0] act_result [0:CALC_OUTPUTS-1];

    // ReLU 활성화 함수
    function signed [VALUE_BITS:0] relu_func;
        input signed [BITS_MAX:0] val;
        begin
            if (val > 0) begin
                if (val < VALUE_MAX)
                    relu_func = val[VALUE_BITS:0];
                else
                    relu_func = VALUE_MAX;
            end else begin
                relu_func = 0;
            end
        end
    endfunction

    //------------------------------------------------------------------
    // FC Layer 연산 흐름 (간략화)
    //
    // 매 클럭마다:
    //   1. i_data_valid && i_cycle==0 → 새 픽셀 시작, sum 초기화
    //   2. sum[o] += data[i] * weight[o][i_cycle*calc_inputs + i]
    //   3. i_cycle == last → bias 가산 + ReLU → 출력
    //
    // VHDL 원본의 Out_Cycles > 1일 때 SUM_RAM을 사용한
    // 시분할 처리 로직은 원본을 참조하세요.
    //------------------------------------------------------------------

    integer o, i;

    always @(posedge i_data_clk) begin
        o_data_valid <= 1'b0;

        if (i_data_valid) begin
            for (o = 0; o < CALC_OUTPUTS; o = o + 1) begin
                // 첫 사이클: 초기화
                if (i_cycle == 0)
                    sum[o] <= 0;

                // MAC 연산
                for (i = 0; i < CALC_INPUTS; i = i + 1) begin
                    sum[o] <= sum[o] +
                        (($signed(i_data[VALUE_BITS*(i+1)-1 -: VALUE_BITS]) *
                          weight_rom[o * (INPUTS+1) + i_cycle * CALC_INPUTS + i] +
                          (1 << (WEIGHT_BITS - OFFSET - 2)))
                         >>> (WEIGHT_BITS - OFFSET - 1));
                end

                // 마지막 사이클: bias + activation
                if (i_cycle == CALC_CYCLES_IN - 1) begin
                    act_result[o] <= relu_func(sum[o] + bias_rom[o]);
                end
            end
        end
    end

endmodule
