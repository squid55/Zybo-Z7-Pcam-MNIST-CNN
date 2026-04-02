------------------------------------------------------------------------
-- AXI Stream to rgb_stream Bridge (v6 - aclk direct)
-- pixel_clk 생성을 제거하고 aclk을 CNN에 직접 전달
-- CNN은 Column 변화 감지로 Data_Valid를 생성하므로
-- aclk이 빠르게 돌아도 빈 사이클은 자동으로 무시됨
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;

entity axi_stream_to_rgb_stream is
    generic (
        INPUT_WIDTH  : natural := 1280;
        INPUT_HEIGHT : natural := 720
    );
    port (
        aclk         : in  std_logic;
        aresetn      : in  std_logic;
        s_axis_tdata : in  std_logic_vector(23 downto 0);
        s_axis_tvalid: in  std_logic;
        s_axis_tready: out std_logic;
        s_axis_tlast : in  std_logic;
        s_axis_tuser : in  std_logic;

        oStream      : out rgb_stream
    );
end entity axi_stream_to_rgb_stream;

architecture rtl of axi_stream_to_rgb_stream is

    signal col_cnt : natural range 0 to INPUT_WIDTH-1 := 0;
    signal row_cnt : natural range 0 to INPUT_HEIGHT-1 := 0;

begin

    s_axis_tready <= '1';

    -- aclk을 직접 CNN 클럭(New_Pixel)으로 사용
    -- pixel_clk 생성 없음 — CNN은 Column 변화로 유효 픽셀 감지
    oStream.New_Pixel <= aclk;

    process(aclk)
    begin
        if rising_edge(aclk) then
            if aresetn = '0' then
                col_cnt        <= 0;
                row_cnt        <= 0;
                oStream.R      <= (others => '0');
                oStream.G      <= (others => '0');
                oStream.B      <= (others => '0');
                oStream.Column <= 0;
                oStream.Row    <= 0;
            else
                if s_axis_tvalid = '1' then
                    oStream.R <= s_axis_tdata(23 downto 16);
                    oStream.G <= s_axis_tdata(15 downto 8);
                    oStream.B <= s_axis_tdata(7 downto 0);

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

                    if s_axis_tuser = '1' then
                        col_cnt <= 0;
                        row_cnt <= 0;
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
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
