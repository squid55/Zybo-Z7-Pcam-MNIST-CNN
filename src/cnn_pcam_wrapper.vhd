------------------------------------------------------------------------
-- CNN Pcam Wrapper
-- Pcam AXI Stream → CNN → AXI-Lite Result 전체 래퍼
--
-- Vivado Block Design에서 이 모듈을 IP로 추가하여:
--   1. GammaCorrection 출력 AXI Stream을 T-탭으로 연결
--   2. AXI-Lite로 PS(ARM)에서 Prediction/Probability 읽기
--
-- Block Design 연결:
--   GammaCorrection.m_axis_video ─┬─→ VDMA (원본 경로 유지)
--                                 └─→ cnn_pcam_wrapper.s_axis_*
--   PS.M_AXI_GP0 → cnn_pcam_wrapper.S_AXI_* (결과 읽기)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;
use work.cnn_config_package.all;
use work.cnn_data_package.all;

entity cnn_pcam_wrapper is
    generic (
        -- Pcam 입력 해상도
        INPUT_WIDTH    : natural := 1280;
        INPUT_HEIGHT   : natural := 720;
        -- CNN 파라미터
        CNN_IMG_SIZE   : natural := 448;
        CNN_OFFSET     : natural := 80;
        CNN_SIZE       : natural := 28
    );
    port (
        -- Clock and Reset
        aclk           : in  std_logic;
        aresetn        : in  std_logic;

        -- AXI Stream input (T-tap from GammaCorrection)
        s_axis_tdata   : in  std_logic_vector(23 downto 0);
        s_axis_tvalid  : in  std_logic;
        s_axis_tready  : out std_logic;
        s_axis_tlast   : in  std_logic;
        s_axis_tuser   : in  std_logic;

        -- Direct outputs (active inference indicators)
        prediction_out : out std_logic_vector(3 downto 0);
        probability_out: out std_logic_vector(9 downto 0);

        -- AXI-Lite Slave (PS reads CNN results)
        S_AXI_ARADDR   : in  std_logic_vector(3 downto 0);
        S_AXI_ARVALID  : in  std_logic;
        S_AXI_ARREADY  : out std_logic;
        S_AXI_RDATA    : out std_logic_vector(31 downto 0);
        S_AXI_RRESP    : out std_logic_vector(1 downto 0);
        S_AXI_RVALID   : out std_logic;
        S_AXI_RREADY   : in  std_logic;
        S_AXI_AWADDR   : in  std_logic_vector(3 downto 0);
        S_AXI_AWVALID  : in  std_logic;
        S_AXI_AWREADY  : out std_logic;
        S_AXI_WDATA    : in  std_logic_vector(31 downto 0);
        S_AXI_WSTRB    : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID   : in  std_logic;
        S_AXI_WREADY   : out std_logic;
        S_AXI_BRESP    : out std_logic_vector(1 downto 0);
        S_AXI_BVALID   : out std_logic;
        S_AXI_BREADY   : in  std_logic
    );
end entity cnn_pcam_wrapper;

architecture rtl of cnn_pcam_wrapper is

    -- Internal signals
    signal rgb_stream_int : rgb_stream;
    signal prediction_int : natural range 0 to NN_Layer_1_Outputs-1;
    signal probability_int: CNN_Value_T;

begin

    -- Direct outputs for LED/debug
    prediction_out  <= std_logic_vector(to_unsigned(prediction_int, 4));
    probability_out <= std_logic_vector(to_unsigned(probability_int, 10));

    -- AXI Stream → rgb_stream bridge
    u_bridge: entity work.axi_stream_to_rgb_stream
        generic map (
            INPUT_WIDTH  => INPUT_WIDTH,
            INPUT_HEIGHT => INPUT_HEIGHT
        )
        port map (
            aclk          => aclk,
            aresetn       => aresetn,
            s_axis_tdata  => s_axis_tdata,
            s_axis_tvalid => s_axis_tvalid,
            s_axis_tready => s_axis_tready,
            s_axis_tlast  => s_axis_tlast,
            s_axis_tuser  => s_axis_tuser,
            oStream       => rgb_stream_int
        );

    -- CNN core
    u_cnn: entity work.cnn_top
        generic map (
            Input_Columns => CNN_IMG_SIZE,
            Input_Rows    => CNN_IMG_SIZE,
            Column_Offset => CNN_OFFSET,
            CNN_Columns   => CNN_SIZE,
            CNN_Rows      => CNN_SIZE
        )
        port map (
            iStream     => rgb_stream_int,
            Prediction  => prediction_int,
            Probability => probability_int
        );

    -- AXI-Lite result register
    u_result: entity work.cnn_result_axilite
        port map (
            prediction    => prediction_int,
            probability   => probability_int,
            S_AXI_ACLK    => aclk,
            S_AXI_ARESETN => aresetn,
            S_AXI_ARADDR  => S_AXI_ARADDR,
            S_AXI_ARVALID => S_AXI_ARVALID,
            S_AXI_ARREADY => S_AXI_ARREADY,
            S_AXI_RDATA   => S_AXI_RDATA,
            S_AXI_RRESP   => S_AXI_RRESP,
            S_AXI_RVALID  => S_AXI_RVALID,
            S_AXI_RREADY  => S_AXI_RREADY,
            S_AXI_AWADDR  => S_AXI_AWADDR,
            S_AXI_AWVALID => S_AXI_AWVALID,
            S_AXI_AWREADY => S_AXI_AWREADY,
            S_AXI_WDATA   => S_AXI_WDATA,
            S_AXI_WSTRB   => S_AXI_WSTRB,
            S_AXI_WVALID  => S_AXI_WVALID,
            S_AXI_WREADY  => S_AXI_WREADY,
            S_AXI_BRESP   => S_AXI_BRESP,
            S_AXI_BVALID  => S_AXI_BVALID,
            S_AXI_BREADY  => S_AXI_BREADY
        );

end architecture rtl;
