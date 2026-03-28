------------------------------------------------------------------------
-- AXI Stream to rgb_stream Bridge
-- Pcam GammaCorrection 출력 (AXI Stream, 24-bit RGB888, 1280x720)
-- → CNN rgb_stream (R/G/B + Column + Row + New_Pixel)
--
-- 기능:
--   1. AXI Stream → rgb_stream 프로토콜 변환
--   2. 픽셀 카운터로 Column/Row 생성
--   3. tuser(SOF) / tlast(EOL) 기반 프레임/라인 동기화
--   4. tready를 통한 AXI 백프레셔 (T-탭이므로 항상 '1')
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;

entity axi_stream_to_rgb_stream is
    generic (
        INPUT_WIDTH  : natural := 1280;  -- Pcam 입력 해상도 폭
        INPUT_HEIGHT : natural := 720    -- Pcam 입력 해상도 높이
    );
    port (
        -- AXI Stream input (from GammaCorrection T-tap)
        aclk         : in  std_logic;
        aresetn      : in  std_logic;
        s_axis_tdata : in  std_logic_vector(23 downto 0);  -- [23:16]=R, [15:8]=G, [7:0]=B
        s_axis_tvalid: in  std_logic;
        s_axis_tready: out std_logic;
        s_axis_tlast : in  std_logic;                       -- End of line
        s_axis_tuser : in  std_logic;                       -- Start of frame

        -- rgb_stream output (to CNN)
        oStream      : out rgb_stream
    );
end entity axi_stream_to_rgb_stream;

architecture rtl of axi_stream_to_rgb_stream is

    signal col_cnt : natural range 0 to INPUT_WIDTH-1 := 0;
    signal row_cnt : natural range 0 to INPUT_HEIGHT-1 := 0;

    -- Pixel clock generation: toggles on each valid pixel
    signal pixel_clk     : std_logic := '0';
    signal pixel_clk_reg : std_logic := '0';

begin

    -- Always ready (T-tap, don't block the main pipeline)
    s_axis_tready <= '1';

    -- Pixel clock = aclk gated by tvalid
    -- CNN uses New_Pixel rising edge as clock
    oStream.New_Pixel <= pixel_clk;

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                col_cnt   <= 0;
                row_cnt   <= 0;
                pixel_clk <= '0';
                oStream.R <= (others => '0');
                oStream.G <= (others => '0');
                oStream.B <= (others => '0');
                oStream.Column <= 0;
                oStream.Row    <= 0;
            else
                if s_axis_tvalid = '1' then
                    -- Extract RGB888
                    oStream.R <= s_axis_tdata(23 downto 16);
                    oStream.G <= s_axis_tdata(15 downto 8);
                    oStream.B <= s_axis_tdata(7 downto 0);

                    -- Set coordinates (clamp to image_data_package range)
                    if col_cnt < Image_Width then
                        oStream.Column <= col_cnt;
                    else
                        oStream.Column <= Image_Width - 1;
                    end if;

                    if row_cnt < Image_Height then
                        oStream.Row <= row_cnt;
                    else
                        oStream.Row <= Image_Height - 1;
                    end if;

                    -- Frame sync: tuser = SOF (Start of Frame)
                    if s_axis_tuser = '1' then
                        col_cnt <= 0;
                        row_cnt <= 0;
                    -- Line sync: tlast = EOL (End of Line)
                    elsif s_axis_tlast = '1' then
                        col_cnt <= 0;
                        if row_cnt < INPUT_HEIGHT - 1 then
                            row_cnt <= row_cnt + 1;
                        end if;
                    else
                        if col_cnt < INPUT_WIDTH - 1 then
                            col_cnt <= col_cnt + 1;
                        end if;
                    end if;

                    -- Toggle pixel clock (creates rising edge for CNN)
                    pixel_clk <= not pixel_clk;
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
