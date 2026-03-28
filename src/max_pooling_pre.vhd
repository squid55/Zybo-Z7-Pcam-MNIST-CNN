------------------------------------------------------------------------
-- MAX Pooling (Preprocessing - RGB domain)
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/Filters/MAX_Pooling.vhdp
-- Downscales RGB image by max pooling (e.g. 448x448 -> 28x28)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;

entity max_pooling_pre is
    generic (
        Input_Columns  : natural := 28;
        Input_Rows     : natural := 28;
        Input_Values   : natural := 1;
        Filter_Columns : natural := 3;
        Filter_Rows    : natural := 3
    );
    port (
        iStream : in  rgb_stream;
        oStream : out rgb_stream
    );
end entity max_pooling_pre;

architecture rtl of max_pooling_pre is

    constant RAM_Bits  : natural := 8 * Input_Values;
    constant RAM_Width : natural := Input_Columns / Filter_Columns;

    signal RAM_Addr_Out : natural range 0 to RAM_Width - 1;
    signal RAM_Addr_In  : natural range 0 to RAM_Width - 1;
    signal RAM_Data_In  : std_logic_vector(23 downto 0);
    signal RAM_Data_Out : std_logic_vector(23 downto 0);
    signal RAM_Enable   : std_logic := '0';

    type RAM_T is array (RAM_Width-1 downto 0) of std_logic_vector(RAM_Bits-1 downto 0);
    signal Buffer_RAM : RAM_T := (others => (others => '0'));

    signal Col_Reg     : natural range 0 to Image_Width-1;
    signal iStream_Buf : rgb_stream;
    signal oStream_Buf : rgb_stream;

begin

    oStream.New_Pixel <= iStream.New_Pixel;

    -- RAM write
    process(iStream.New_Pixel)
    begin
        if rising_edge(iStream.New_Pixel) then
            if RAM_Enable = '1' then
                Buffer_RAM(RAM_Addr_In) <= RAM_Data_In(RAM_Bits-1 downto 0);
            end if;
        end if;
    end process;

    RAM_Data_Out(RAM_Bits-1 downto 0) <= Buffer_RAM(RAM_Addr_Out);

    -- Main process
    process(iStream.New_Pixel)
        variable max_Col_Buf : rgb_data;
        variable max_Col_Cnt : natural range 0 to Filter_Columns-1 := Filter_Columns-1;
    begin
        if rising_edge(iStream.New_Pixel) then
            iStream_Buf.R <= iStream.R;
            if Input_Values > 1 then
                iStream_Buf.G <= iStream.G;
            end if;
            if Input_Values > 2 then
                iStream_Buf.B <= iStream.B;
            end if;
            iStream_Buf.Column <= iStream.Column;
            iStream_Buf.Row    <= iStream.Row;

            oStream.R      <= oStream_Buf.R;
            oStream.G      <= oStream_Buf.G;
            oStream.B      <= oStream_Buf.B;
            oStream.Column <= oStream_Buf.Column;
            oStream.Row    <= oStream_Buf.Row;

            if iStream_Buf.Column /= Col_Reg and iStream_Buf.Column < Input_Columns and iStream_Buf.Row < Input_Rows then
                if max_Col_Cnt < Filter_Columns-1 then
                    max_Col_Cnt := max_Col_Cnt + 1;
                else
                    max_Col_Cnt := 0;
                end if;

                if iStream_Buf.Column = 0 then
                    max_Col_Cnt := 0;
                end if;

                if max_Col_Cnt = 0 then
                    max_Col_Buf.R := iStream_Buf.R;
                    max_Col_Buf.G := iStream_Buf.G;
                    max_Col_Buf.B := iStream_Buf.B;
                else
                    if unsigned(iStream_Buf.R) > unsigned(max_Col_Buf.R) then
                        max_Col_Buf.R := iStream_Buf.R;
                    end if;
                    if Input_Values > 1 and unsigned(iStream_Buf.G) > unsigned(max_Col_Buf.G) then
                        max_Col_Buf.G := iStream_Buf.G;
                    end if;
                    if Input_Values > 2 and unsigned(iStream_Buf.B) > unsigned(max_Col_Buf.B) then
                        max_Col_Buf.B := iStream_Buf.B;
                    end if;
                end if;

                if max_Col_Cnt = Filter_Columns-1 then
                    if iStream_Buf.Row mod Filter_Rows > 0 then
                        if unsigned(RAM_Data_Out(7 downto 0)) > unsigned(max_Col_Buf.R) then
                            max_Col_Buf.R := RAM_Data_Out(7 downto 0);
                        end if;
                        if Input_Values > 1 and unsigned(RAM_Data_Out(15 downto 8)) > unsigned(max_Col_Buf.G) then
                            max_Col_Buf.G := RAM_Data_Out(15 downto 8);
                        end if;
                        if Input_Values > 2 and unsigned(RAM_Data_Out(23 downto 16)) > unsigned(max_Col_Buf.B) then
                            max_Col_Buf.B := RAM_Data_Out(23 downto 16);
                        end if;
                    end if;

                    if iStream_Buf.Row mod Filter_Rows = Filter_Rows-1 then
                        oStream_Buf.R <= max_Col_Buf.R;
                        if Input_Values > 1 then
                            oStream_Buf.G <= max_Col_Buf.G;
                        end if;
                        if Input_Values > 2 then
                            oStream_Buf.B <= max_Col_Buf.B;
                        end if;
                        oStream_Buf.Column <= iStream_Buf.Column / Filter_Columns;
                        oStream_Buf.Row    <= iStream_Buf.Row / Filter_Rows;
                    else
                        RAM_Data_In(7 downto 0) <= max_Col_Buf.R;
                        if Input_Values > 1 then
                            RAM_Data_In(15 downto 8) <= max_Col_Buf.G;
                        end if;
                        if Input_Values > 2 then
                            RAM_Data_In(23 downto 16) <= max_Col_Buf.B;
                        end if;
                    end if;

                    RAM_Addr_In <= iStream_Buf.Column / Filter_Columns;
                end if;

                RAM_Addr_Out <= iStream_Buf.Column / Filter_Columns;
            end if;

            Col_Reg <= iStream_Buf.Column;
        end if;
    end process;

end architecture rtl;
