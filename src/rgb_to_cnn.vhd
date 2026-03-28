------------------------------------------------------------------------
-- RGB to CNN Stream Converter
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/Filters/RGB_TO_CNN.vhdp
-- Converts rgb_stream to CNN_Stream_T with CNN_Values_T
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;
use work.cnn_config_package.all;

entity rgb_to_cnn is
    generic (
        Input_Values : natural := 1  -- 1-3 for R, RG or RGB
    );
    port (
        iStream : in  rgb_stream;
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Input_Values-1 downto 0)
    );
end entity rgb_to_cnn;

architecture rtl of rgb_to_cnn is

    signal Col_Reg     : natural range 0 to Image_Width-1 := Image_Width-1;
    signal oStream_Buf : CNN_Stream_T;
    signal oData_Buf   : CNN_Values_T(2 downto 0);

begin

    oStream.Data_CLK <= iStream.New_Pixel;

    process(iStream.New_Pixel)
    begin
        if rising_edge(iStream.New_Pixel) then
            if iStream.Column /= Col_Reg then
                oStream_Buf.Data_Valid <= '1';
            else
                oStream_Buf.Data_Valid <= '0';
            end if;

            oStream_Buf.Column <= iStream.Column;
            oStream_Buf.Row    <= iStream.Row;
            oData_Buf(0)       <= to_integer(unsigned(iStream.R));
            if Input_Values > 1 then
                oData_Buf(1) <= to_integer(unsigned(iStream.G));
            end if;
            if Input_Values > 2 then
                oData_Buf(2) <= to_integer(unsigned(iStream.B));
            end if;

            oStream.Column     <= oStream_Buf.Column;
            oStream.Row        <= oStream_Buf.Row;
            oStream.Data_Valid <= oStream_Buf.Data_Valid;
            oStream.Filter     <= 0;
            oData              <= oData_Buf(Input_Values-1 downto 0);

            Col_Reg <= iStream.Column;
        end if;
    end process;

end architecture rtl;
