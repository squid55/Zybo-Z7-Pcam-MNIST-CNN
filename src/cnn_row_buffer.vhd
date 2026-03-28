------------------------------------------------------------------------
-- CNN Row Buffer
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN/CNN_Row_Buffer.vhdp
-- Buffers rows to output a matrix for convolution/pooling
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.cnn_config_package.all;

entity cnn_row_buffer is
    generic (
        Input_Columns  : natural := 28;
        Input_Rows     : natural := 28;
        Input_Values   : natural := 1;
        Filter_Columns : natural := 3;
        Filter_Rows    : natural := 3;
        Input_Cycles   : natural := 1;
        Value_Cycles   : natural := 1;
        Calc_Cycles    : natural := 1;
        Strides        : natural := 1;
        Padding        : Padding_T := valid
    );
    port (
        iStream : in  CNN_Stream_T;
        iData   : in  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Input_Values/Value_Cycles-1 downto 0);
        oRow    : buffer natural range 0 to Filter_Rows-1;
        oColumn : buffer natural range 0 to Filter_Columns-1;
        oInput  : buffer natural range 0 to Value_Cycles-1
    );
end entity cnn_row_buffer;

architecture rtl of cnn_row_buffer is

    function RAM_Rows_F(fr : natural; ic : natural) return natural is
    begin
        if ic = 2 then
            return fr + 1;
        else
            return fr;
        end if;
    end function;

    constant RAM_Rows  : natural := RAM_Rows_F(Filter_Rows, Input_Columns);
    constant RAM_Bits  : natural := (CNN_Value_Resolution + CNN_Value_Negative) * (Input_Values / Value_Cycles);
    constant RAM_Width : natural := Input_Columns * RAM_Rows * Value_Cycles;

    signal RAM_Addr_Out : natural range 0 to RAM_Width - 1;
    signal RAM_Addr_In  : natural range 0 to RAM_Width - 1;
    signal RAM_Data_In  : std_logic_vector(RAM_Bits - 1 downto 0);
    signal RAM_Data_Out : std_logic_vector(RAM_Bits - 1 downto 0);
    signal RAM_Enable   : std_logic := '0';

    type RAM_T is array (RAM_Width - 1 downto 0) of std_logic_vector(RAM_Bits - 1 downto 0);
    signal Buffer_RAM : RAM_T := (others => (others => '0'));

    signal oStream_Reg   : CNN_Stream_T;
    signal oRow_O_Reg    : natural range 0 to RAM_Rows - 1;
    signal oColumn_O_Reg : natural range 0 to Filter_Columns - 1;
    signal oInput_Reg    : natural range 0 to Value_Cycles - 1;
    signal oRow_Reg      : natural range 0 to Input_Rows - 1 := 0;
    signal oColumn_Reg   : natural range 0 to Input_Columns - 1 := 0;
    signal oRow_RAM_Reg  : natural range 0 to RAM_Rows - 1;
    signal oData_En_Reg  : std_logic := '0';

begin

    oStream.Data_CLK <= iStream.Data_CLK;

    -- RAM write process
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if RAM_Enable = '1' then
                Buffer_RAM(RAM_Addr_In) <= RAM_Data_In;
            end if;
        end if;
    end process;

    -- RAM read process (falling edge)
    process(iStream.Data_CLK)
    begin
        if falling_edge(iStream.Data_CLK) then
            RAM_Data_Out <= Buffer_RAM(RAM_Addr_Out);
        end if;
    end process;

    -- Main processing
    process(iStream.Data_CLK)
        -- Input variables
        variable iRow_RAM    : natural range 0 to RAM_Rows - 1 := 0;
        variable iRow_Reg    : natural range 0 to Input_Rows - 1 := 0;
        variable iValue_RAM  : natural range 0 to Value_Cycles - 1 := 0;
        variable iValue_Cnt  : natural range 0 to Input_Values - 1 := 0;
        variable iValue_Reg  : natural range 0 to Input_Values - 1 := 0;
        variable iColumn_Reg : natural range 0 to Input_Columns - 1 := 0;
        -- Output variables
        variable oColumn_Calc : natural range 0 to Input_Columns - 1 := 0;
        variable Valid_Reg    : std_logic;
        variable Row_Cntr     : integer range (-1)*(Filter_Rows)/2 to (Filter_Rows-1)/2 := (-1)*(Filter_Rows)/2;
        variable Column_Cntr  : integer range (-1)*(Filter_Columns)/2 to (Filter_Columns-1)/2 := (-1)*(Filter_Columns)/2;
        variable Value_Cntr   : natural range 0 to Value_Cycles - 1 := 0;
        variable Calc_Cntr    : natural range 0 to Calc_Cycles - 1 := 0;
    begin
        if rising_edge(iStream.Data_CLK) then
            -- Input: Track row changes
            if iRow_Reg /= iStream.Row then
                if iRow_RAM < RAM_Rows - 1 then
                    iRow_RAM := iRow_RAM + 1;
                else
                    iRow_RAM := 0;
                end if;
            end if;

            -- RAM Value Input calculation
            if Input_Cycles = 1 then
                if (Input_Columns > 1 and iColumn_Reg /= iStream.Column) or
                   (Input_Columns <= 1 and iRow_Reg /= iStream.Row) then
                    iValue_RAM := 0;
                elsif iValue_RAM < Value_Cycles - 1 then
                    iValue_RAM := iValue_RAM + 1;
                end if;
                iValue_Cnt := iValue_RAM;
            elsif Input_Cycles <= Value_Cycles then
                if iValue_Reg /= iStream.Filter then
                    iValue_RAM := iStream.Filter * (Value_Cycles / Input_Cycles);
                    iValue_Cnt := 0;
                elsif iValue_RAM < (iStream.Filter + 1) * (Value_Cycles / Input_Cycles) - 1 then
                    iValue_RAM := iValue_RAM + 1;
                    iValue_Cnt := iValue_Cnt + 1;
                end if;
            else
                if iValue_Reg /= iStream.Filter then
                    iValue_RAM := iStream.Filter / (Input_Cycles / Value_Cycles);
                    iValue_Cnt := iStream.Filter mod (Input_Cycles / Value_Cycles);
                end if;
            end if;

            RAM_Addr_In <= iValue_RAM + (iStream.Column + iRow_RAM * Input_Columns) * Value_Cycles;

            -- RAM Data In
            if Input_Cycles = Value_Cycles then
                for i in 0 to Input_Values/Input_Cycles - 1 loop
                    RAM_Data_In((i+1)*(CNN_Value_Resolution+CNN_Value_Negative)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative))
                        <= std_logic_vector(to_unsigned(iData(i), CNN_Value_Resolution+CNN_Value_Negative));
                end loop;
            elsif Input_Cycles < Value_Cycles then
                for i in 0 to Input_Values/Value_Cycles - 1 loop
                    RAM_Data_In((i+1)*(CNN_Value_Resolution+CNN_Value_Negative)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative))
                        <= std_logic_vector(to_unsigned(iData(i + iValue_Cnt*(Input_Values/Value_Cycles)), CNN_Value_Resolution+CNN_Value_Negative));
                end loop;
            else
                for i in 0 to Input_Values/Input_Cycles - 1 loop
                    RAM_Data_In((i+1+iValue_Cnt*(Input_Values/Input_Cycles))*(CNN_Value_Resolution+CNN_Value_Negative)-1 downto (i+iValue_Cnt*(Input_Values/Input_Cycles))*(CNN_Value_Resolution+CNN_Value_Negative))
                        <= std_logic_vector(to_unsigned(iData(i), CNN_Value_Resolution+CNN_Value_Negative));
                end loop;
            end if;

            RAM_Enable <= iStream.Data_Valid;

            -- Output: Column tracking
            if Input_Columns > 1 then
                oColumn_Calc := (iStream.Column - (Filter_Columns-1)/2) mod Input_Columns;
                if oColumn_Reg > oColumn_Calc then
                    oRow_Reg    <= (iStream.Row - (Filter_Rows-1)/2) mod Input_Rows;
                    oRow_RAM_Reg <= (iRow_RAM - (Filter_Rows-1)/2) mod RAM_Rows;
                end if;
                oColumn_Reg <= oColumn_Calc;
            else
                oColumn_Reg <= 0;
                oRow_Reg    <= (iStream.Row - (Filter_Rows-1)/2) mod Input_Rows;
            end if;

            -- Output counter logic
            if (Input_Columns > 1 and oColumn_Reg /= oStream_Reg.Column) or
               (Input_Columns <= 1 and oRow_Reg /= oStream_Reg.Row) then
                Row_Cntr    := (-1)*(Filter_Rows)/2;
                Column_Cntr := (-1)*(Filter_Columns)/2;
                Value_Cntr  := 0;
                Calc_Cntr   := 0;
                Valid_Reg   := '1';
            elsif Calc_Cntr < Calc_Cycles - 1 then
                Calc_Cntr := Calc_Cntr + 1;
            else
                Calc_Cntr := 0;
                if Value_Cntr < Value_Cycles - 1 then
                    Value_Cntr := Value_Cntr + 1;
                else
                    Value_Cntr := 0;
                    if Column_Cntr < (Filter_Columns-1)/2 then
                        Column_Cntr := Column_Cntr + 1;
                    elsif Row_Cntr < (Filter_Rows-1)/2 then
                        Column_Cntr := (-1)*(Filter_Columns)/2;
                        Row_Cntr    := Row_Cntr + 1;
                    else
                        Valid_Reg := '0';
                    end if;
                end if;
            end if;

            RAM_Addr_Out <= (((oRow_RAM_Reg + Row_Cntr) mod RAM_Rows) * Input_Columns + (oColumn_Reg + Column_Cntr) mod Input_Columns) * Value_Cycles + Value_Cntr;

            oStream_Reg.Column <= oColumn_Reg;
            oStream_Reg.Row    <= oRow_Reg;
            oStream_Reg.Filter <= 0;
            oRow_O_Reg         <= Row_Cntr + Filter_Rows/2;
            oColumn_O_Reg      <= Column_Cntr + Filter_Columns/2;
            oInput_Reg         <= Value_Cntr;

            if oColumn_Reg + Column_Cntr < 0 or oColumn_Reg + Column_Cntr > Input_Columns - 1
               or oRow_Reg + Row_Cntr < 0 or oRow_Reg + Row_Cntr > Input_Rows - 1 then
                oData_En_Reg <= '0';
            else
                oData_En_Reg <= '1';
            end if;

            -- Output with padding mode
            if Padding = valid then
                if Valid_Reg = '1'
                    and oColumn_Reg >= Filter_Columns/2 and oColumn_Reg < Input_Columns - (Filter_Columns-1)/2
                    and oRow_Reg >= Filter_Rows/2 and oRow_Reg < Input_Rows - (Filter_Rows-1)/2
                    and (oColumn_Reg - Filter_Columns/2) mod Strides = 0
                    and (oRow_Reg - Filter_Rows/2) mod Strides = 0 then
                    oStream_Reg.Data_Valid <= '1';
                else
                    oStream_Reg.Data_Valid <= '0';
                end if;

                if oStream_Reg.Data_Valid = '1' then
                    oStream.Column     <= (oStream_Reg.Column - Filter_Columns/2) / Strides;
                    oStream.Row        <= (oStream_Reg.Row - Filter_Rows/2) / Strides;
                    oStream.Filter     <= oStream_Reg.Filter;
                    oStream.Data_Valid <= '1';
                    oRow               <= oRow_O_Reg;
                    oColumn            <= oColumn_O_Reg;
                    oInput             <= oInput_Reg;
                    for i in 0 to Input_Values/Value_Cycles - 1 loop
                        oData(i) <= to_integer(unsigned(RAM_Data_Out((i+1)*(CNN_Value_Resolution+CNN_Value_Negative)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative))));
                    end loop;
                else
                    oStream.Data_Valid <= '0';
                end if;
            else -- same padding
                if Valid_Reg = '1' and oColumn_Reg mod Strides = 0 and oRow_Reg mod Strides = 0 then
                    oStream_Reg.Data_Valid <= '1';
                else
                    oStream_Reg.Data_Valid <= '0';
                end if;

                if oStream_Reg.Data_Valid = '1' then
                    oStream.Column     <= oStream_Reg.Column / Strides;
                    oStream.Row        <= oStream_Reg.Row / Strides;
                    oStream.Filter     <= oStream_Reg.Filter;
                    oStream.Data_Valid <= '1';
                    oRow               <= oRow_O_Reg;
                    oColumn            <= oColumn_O_Reg;
                    oInput             <= oInput_Reg;
                    for i in 0 to Input_Values/Value_Cycles - 1 loop
                        oData(i) <= to_integer(unsigned(RAM_Data_Out((i+1)*(CNN_Value_Resolution+CNN_Value_Negative)-1 downto i*(CNN_Value_Resolution+CNN_Value_Negative))));
                    end loop;
                else
                    oStream.Data_Valid <= '0';
                end if;

                if oData_En_Reg = '0' then
                    oData <= (others => 0);
                end if;
            end if;

            iRow_Reg    := iStream.Row;
            iColumn_Reg := iStream.Column;
            iValue_Reg  := iStream.Filter;
        end if;
    end process;

end architecture rtl;
