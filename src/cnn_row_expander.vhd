------------------------------------------------------------------------
-- CNN Row Expander
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN/CNN_Row_Expander.vhdp
-- Buffers a row and creates oStream with more space between new data
-- Input:  -_-_-_-_________
-- Output: -___-___-___-___
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.cnn_config_package.all;

entity cnn_row_expander is
    generic (
        Input_Columns  : natural := 28;
        Input_Rows     : natural := 28;
        Input_Values   : natural := 1;
        Input_Cycles   : natural := 1;
        Output_Cycles  : natural := 2
    );
    port (
        iStream : in  CNN_Stream_T;
        iData   : in  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Input_Values/Input_Cycles-1 downto 0)
    );
end entity cnn_row_expander;

architecture rtl of cnn_row_expander is

    constant DATA_WIDTH : natural := (CNN_Value_Resolution + CNN_Value_Negative) * (Input_Values / Input_Cycles);

    type RAM_T is array (0 to Input_Columns * Input_Cycles - 1)
        of std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal Buffer_RAM   : RAM_T;
    signal RAM_Addr_In  : natural range 0 to Input_Columns * Input_Cycles - 1;
    signal RAM_Addr_Out : natural range 0 to Input_Columns * Input_Cycles - 1;
    signal RAM_Data_In  : std_logic_vector(DATA_WIDTH - 1 downto 0);
    signal RAM_Data_Out : std_logic_vector(DATA_WIDTH - 1 downto 0);

    signal Delay_Cnt    : natural range 0 to Output_Cycles - 1 := 0;
    signal Reset_Col    : std_logic := '0';
    signal oStream_Reg  : CNN_Stream_T;

begin

    oStream.Data_CLK <= iStream.Data_CLK;

    -- RAM write on falling edge
    process(iStream.Data_CLK)
    begin
        if falling_edge(iStream.Data_CLK) then
            Buffer_RAM(RAM_Addr_In) <= RAM_Data_In;
            RAM_Data_Out <= Buffer_RAM(RAM_Addr_Out);
        end if;
    end process;

    -- Main logic on rising edge
    process(iStream.Data_CLK)
        variable iData_Buf   : CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        variable Valid_Reg   : std_logic := '0';
        variable Column_Buf  : natural range 0 to Input_Columns - 1;
        variable Filter_Cnt  : natural range 0 to Input_Values - 1;
    begin
        if rising_edge(iStream.Data_CLK) then
            -- Buffer data to set RAM
            if iStream.Data_Valid = '1' then
                iData_Buf := iData;
            end if;

            -- Set new input data
            for i in 0 to Input_Values/Input_Cycles - 1 loop
                if CNN_Value_Negative = 0 then
                    RAM_Data_In(CNN_Value_Resolution*(i+1)-1 downto CNN_Value_Resolution*i)
                        <= std_logic_vector(to_unsigned(iData_Buf(i), CNN_Value_Resolution));
                else
                    RAM_Data_In((CNN_Value_Resolution+CNN_Value_Negative)*(i+1)-1 downto (CNN_Value_Resolution+CNN_Value_Negative)*i)
                        <= std_logic_vector(to_signed(iData_Buf(i), CNN_Value_Resolution+CNN_Value_Negative));
                end if;
            end loop;
            RAM_Addr_In <= iStream.Column * Input_Cycles + iStream.Filter;

            -- Count for output delay between new data
            if iStream.Data_Valid = '1' and Valid_Reg = '0' and iStream.Column = 0 then
                Delay_Cnt <= 0;
                Reset_Col <= '1';
            elsif Delay_Cnt < Output_Cycles - 1 then
                Delay_Cnt <= Delay_Cnt + 1;
            elsif iStream.Column > Column_Buf then
                Delay_Cnt <= 0;
            end if;
            Valid_Reg := iStream.Data_Valid;

            -- Set output data
            if Reset_Col = '1' then
                Reset_Col <= '0';
                Column_Buf := 0;
                Filter_Cnt := 0;
                oStream_Reg.Data_Valid <= '1';
            elsif Delay_Cnt = 0 and Column_Buf < Input_Columns - 1 then
                Column_Buf := Column_Buf + 1;
                Filter_Cnt := 0;
                oStream_Reg.Data_Valid <= '1';
            elsif Filter_Cnt < (Input_Cycles - 1) * (Input_Values / Input_Cycles) then
                Filter_Cnt := Filter_Cnt + Input_Values / Input_Cycles;
            else
                oStream_Reg.Data_Valid <= '0';
            end if;

            oStream_Reg.Column <= Column_Buf;
            oStream_Reg.Row    <= iStream.Row;
            oStream_Reg.Filter <= Filter_Cnt;
            RAM_Addr_Out <= Column_Buf * Input_Cycles + Filter_Cnt;

            oStream.Column     <= oStream_Reg.Column;
            oStream.Row        <= oStream_Reg.Row;
            oStream.Filter     <= oStream_Reg.Filter;
            oStream.Data_Valid <= oStream_Reg.Data_Valid;

            for i in 0 to Input_Values/Input_Cycles - 1 loop
                if CNN_Value_Negative = 0 then
                    oData(i) <= to_integer(unsigned(RAM_Data_Out(CNN_Value_Resolution*(i+1)-1 downto CNN_Value_Resolution*i)));
                else
                    oData(i) <= to_integer(signed(RAM_Data_Out((CNN_Value_Resolution+CNN_Value_Negative)*(i+1)-1 downto (CNN_Value_Resolution+CNN_Value_Negative)*i)));
                end if;
            end loop;
        end if;
    end process;

end architecture rtl;
