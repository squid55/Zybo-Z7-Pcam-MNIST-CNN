------------------------------------------------------------------------
-- CNN Pooling (Max Pooling)
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN/CNN_Pooling.vhdp
-- Finds maximum value in a matrix
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.cnn_config_package.all;

entity cnn_pooling is
    generic (
        Input_Columns  : natural := 28;
        Input_Rows     : natural := 28;
        Input_Values   : natural := 4;
        Filter_Columns : natural := 2;
        Filter_Rows    : natural := 2;
        Strides        : natural := 1;
        Padding        : Padding_T := valid;
        Input_Cycles   : natural := 1;
        Value_Cycles   : natural := 1;
        Filter_Cycles  : natural := 1;
        Filter_Delay   : natural := 1;
        Expand         : boolean := false;
        Expand_Cycles  : natural := 1
    );
    port (
        iStream : in  CNN_Stream_T;
        iData   : in  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Input_Values/Filter_Cycles-1 downto 0)
    );
end entity cnn_pooling;

architecture rtl of cnn_pooling is

    constant Calc_Cycles  : natural := Filter_Columns * Filter_Rows * Value_Cycles;
    constant matrix_values : natural := Filter_Columns * Filter_Rows;
    constant Calc_Outputs : natural := Input_Values / Value_Cycles;
    constant Out_Values   : natural := Input_Values / Filter_Cycles;

    signal Expand_Stream : CNN_Stream_T;
    signal Expand_Data   : CNN_Values_T(Input_Values/Input_Cycles-1 downto 0) := (others => 0);

    signal Matrix_Stream : CNN_Stream_T;
    signal Matrix_Data   : CNN_Values_T(Calc_Outputs-1 downto 0);
    signal Matrix_Column : natural range 0 to Input_Columns-1;
    signal Matrix_Row    : natural range 0 to Input_Rows-1;
    signal Matrix_Input  : natural range 0 to Value_Cycles-1;

    -- MAX RAM
    type MAX_set_t is array (0 to Calc_Outputs-1) of signed(CNN_Value_Resolution downto 0);
    type MAX_ram_t is array (natural range <>) of MAX_set_t;
    signal MAX_RAM     : MAX_ram_t(0 to Value_Cycles-1) := (others => (others => (others => '0')));
    signal MAX_Rd_Addr : natural range 0 to Value_Cycles-1;
    signal MAX_Rd_Data : MAX_set_t;
    signal MAX_Wr_Addr : natural range 0 to Value_Cycles-1;
    signal MAX_Wr_Data : MAX_set_t;
    signal MAX_Wr_Ena  : std_logic := '1';

    -- OUT RAM
    constant OUT_RAM_Elements : natural := min_val(Value_Cycles, Filter_Cycles);
    type OUT_set_t is array (0 to Input_Values/OUT_RAM_Elements-1) of signed(CNN_Value_Resolution downto 0);
    type OUT_ram_t is array (natural range <>) of OUT_set_t;
    signal OUT_RAM     : OUT_ram_t(0 to OUT_RAM_Elements-1) := (others => (others => (others => '0')));
    signal OUT_Rd_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Rd_Data : OUT_set_t;
    signal OUT_Wr_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Wr_Data : OUT_set_t;
    signal OUT_Wr_Ena  : std_logic := '1';

    signal oCycle_Cnt  : natural range 0 to Filter_Cycles-1;
    signal Delay_Cycle : natural range 0 to Filter_Delay-1 := Filter_Delay-1;
    signal Valid_Reg_O : std_logic;

begin

    -- Expand generate
    gen_expand: if Expand generate
        u_expander: entity work.cnn_row_expander
            generic map (
                Input_Columns => Input_Columns,
                Input_Rows    => Input_Rows,
                Input_Values  => Input_Values,
                Input_Cycles  => Input_Cycles,
                Output_Cycles => max_val(Calc_Cycles+1, Expand_Cycles)
            )
            port map (
                iStream => iStream,
                iData   => iData,
                oStream => Expand_Stream,
                oData   => Expand_Data
            );
    end generate;

    gen_no_expand: if not Expand generate
        Expand_Data   <= iData;
        Expand_Stream <= iStream;
    end generate;

    -- Row Buffer
    u_row_buffer: entity work.cnn_row_buffer
        generic map (
            Input_Columns  => Input_Columns,
            Input_Rows     => Input_Rows,
            Input_Values   => Input_Values,
            Filter_Columns => Filter_Columns,
            Filter_Rows    => Filter_Rows,
            Input_Cycles   => Input_Cycles,
            Value_Cycles   => Value_Cycles,
            Strides        => Strides,
            Padding        => Padding
        )
        port map (
            iStream => Expand_Stream,
            iData   => Expand_Data,
            oStream => Matrix_Stream,
            oData   => Matrix_Data,
            oRow    => Matrix_Row,
            oColumn => Matrix_Column,
            oInput  => Matrix_Input
        );

    oStream.Data_CLK <= Matrix_Stream.Data_CLK;

    -- MAX RAM process
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if MAX_Wr_Ena = '1' then
                MAX_RAM(MAX_Wr_Addr) <= MAX_Wr_Data;
            end if;
        end if;
    end process;
    MAX_Rd_Data <= MAX_RAM(MAX_Rd_Addr);

    -- OUT RAM process
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if OUT_Wr_Ena = '1' then
                OUT_RAM(OUT_Wr_Addr) <= OUT_Wr_Data;
            end if;
        end if;
    end process;
    OUT_Rd_Data <= OUT_RAM(OUT_Rd_Addr);

    -- Main pooling process
    process(Matrix_Stream.Data_CLK)
        variable max_v       : MAX_set_t;
        variable last_input  : std_logic;
        variable input_start : natural range 0 to Input_Values := 0;
        variable MAX_ram_v   : CNN_Value_T;

        variable oCycle_Cnt_Var : natural range 0 to Filter_Cycles-1;

        constant Act_sum_buf_cycles : natural := Value_Cycles/OUT_RAM_Elements;
        type Act_sum_buf_t is array (Act_sum_buf_cycles-1 downto 0) of MAX_set_t;
        variable Act_sum_buf     : Act_sum_buf_t;
        variable Act_sum_buf_cnt : natural range 0 to Act_sum_buf_cycles-1 := 0;
    begin
        if rising_edge(Matrix_Stream.Data_CLK) then
            oStream.Data_Valid <= '0';
            last_input := '0';

            if Matrix_Stream.Data_Valid = '1' then
                if Value_Cycles > 1 then
                    max_v := MAX_Rd_Data;
                    if Matrix_Input < Value_Cycles-1 then
                        MAX_Rd_Addr <= Matrix_Input + 1;
                    else
                        MAX_Rd_Addr <= 0;
                    end if;
                end if;

                input_start := Matrix_Input * Calc_Outputs;
                for in_offset in 0 to Calc_Outputs-1 loop
                    MAX_ram_v := Matrix_Data(in_offset);
                    if (Matrix_Row = 0 and Matrix_Column = 0) or MAX_ram_v > to_integer(max_v(in_offset)) then
                        max_v(in_offset) := to_signed(MAX_ram_v, CNN_Value_Resolution+1);
                    end if;
                end loop;

                if Matrix_Column = Filter_Columns-1 and Matrix_Row = Filter_Rows-1 then
                    if Matrix_Input = Value_Cycles-1 then
                        last_input := '1';
                    end if;

                    if Value_Cycles = OUT_RAM_Elements then
                        OUT_Wr_Addr <= Matrix_Input;
                        for i in 0 to Calc_Outputs-1 loop
                            OUT_Wr_Data(i) <= max_v(i);
                        end loop;
                    else
                        Act_sum_buf_cnt := Matrix_Input mod Act_sum_buf_cycles;
                        Act_sum_buf(Act_sum_buf_cnt) := max_v;
                        if Act_sum_buf_cnt = Act_sum_buf_cycles-1 then
                            OUT_Wr_Addr <= Matrix_Input/Act_sum_buf_cycles;
                            for i in 0 to Act_sum_buf_cycles-1 loop
                                for j in 0 to Calc_Outputs-1 loop
                                    OUT_Wr_Data(Calc_Outputs*i + j) <= Act_sum_buf(i)(j);
                                end loop;
                            end loop;
                        end if;
                    end if;

                    if Value_Cycles > 1 then
                        MAX_Wr_Data <= max_v;
                        MAX_Wr_Addr <= Matrix_Input;
                    end if;
                end if;
            end if;

            -- Output stage
            Valid_Reg_O <= '0';
            if last_input = '1' then
                oCycle_Cnt_Var := 0;
                Delay_Cycle    <= 0;
                oStream.Column <= Matrix_Stream.Column;
                oStream.Row    <= Matrix_Stream.Row;
                Valid_Reg_O    <= '1';
            elsif Delay_Cycle < Filter_Delay-1 then
                Delay_Cycle <= Delay_Cycle + 1;
            elsif oCycle_Cnt < Filter_Cycles-1 then
                Delay_Cycle    <= 0;
                oCycle_Cnt_Var := oCycle_Cnt + 1;
                Valid_Reg_O    <= '1';
            end if;
            oCycle_Cnt <= oCycle_Cnt_Var;

            OUT_Rd_Addr <= oCycle_Cnt_Var / (Filter_Cycles/OUT_RAM_Elements);

            if Delay_Cycle = 0 then
                for i in 0 to Out_Values-1 loop
                    if Filter_Cycles = OUT_RAM_Elements then
                        oData(i) <= to_integer(OUT_Rd_Data(i));
                    else
                        oData(i) <= to_integer(OUT_Rd_Data(i + (oCycle_Cnt mod (Filter_Cycles/OUT_RAM_Elements))*Out_Values));
                    end if;
                end loop;
                oStream.Filter     <= oCycle_Cnt * (Input_Values/Filter_Cycles);
                oStream.Data_Valid <= Valid_Reg_O;
            else
                oStream.Data_Valid <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
