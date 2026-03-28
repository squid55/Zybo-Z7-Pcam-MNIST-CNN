------------------------------------------------------------------------
-- CNN Convolution
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN/CNN_Convolution.vhdp
-- Calculates outputs for one convolution layer
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.cnn_config_package.all;

entity cnn_convolution is
    generic (
        Input_Columns  : natural := 28;
        Input_Rows     : natural := 28;
        Input_Values   : natural := 1;
        Filter_Columns : natural := 3;
        Filter_Rows    : natural := 3;
        Filters        : natural := 4;
        Strides        : natural := 1;
        Activation     : Activation_T := relu;
        Padding        : Padding_T := valid;
        Input_Cycles   : natural := 1;
        Value_Cycles   : natural := 1;
        Calc_Cycles    : natural := 1;
        Filter_Cycles  : natural := 1;
        Filter_Delay   : natural := 1;
        Expand         : boolean := true;
        Expand_Cycles  : natural := 0;
        Offset_In      : natural := 0;
        Offset_Out     : natural := 0;
        Offset         : integer := 0;
        Weights        : CNN_Weights_T
    );
    port (
        iStream : in  CNN_Stream_T;
        iData   : in  CNN_Values_T(Input_Values/Input_Cycles-1 downto 0);
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Filters/Filter_Cycles-1 downto 0)
    );
end entity cnn_convolution;

architecture rtl of cnn_convolution is

    constant matrix_values       : natural := Filter_Columns * Filter_Rows;
    constant Matrix_Value_Cycles : natural := matrix_values * Value_Cycles;
    constant Calc_Filters        : natural := Filters / Calc_Cycles;
    constant Out_Filters         : natural := Filters / Filter_Cycles;
    constant Calc_Steps          : natural := Input_Values * matrix_values / Matrix_Value_Cycles;
    constant Offset_Diff         : integer := Offset_Out - Offset_In;

    constant value_max : natural := 2**CNN_Value_Resolution - 1;
    constant bits_max  : natural := CNN_Value_Resolution + max_val(Offset, 0) + integer(ceil(log2(real(matrix_values * Input_Values + 1))));

    -- Bias initialization
    function Init_Bias(weights_in : CNN_Weights_T; filt : natural; inp : natural) return CNN_Weights_T is
        variable Bias_Const : CNN_Weights_T(0 to filt-1, 0 to 0);
    begin
        for i in 0 to filt-1 loop
            Bias_Const(i, 0) := weights_in(i, inp);
        end loop;
        return Bias_Const;
    end function;

    constant Bias_Const : CNN_Weights_T(0 to Filters-1, 0 to 0) := Init_Bias(Weights, Filters, matrix_values * Input_Values);

    -- ROM type and initialization
    type ROM_Array is array (0 to Calc_Cycles * Matrix_Value_Cycles - 1)
        of std_logic_vector(Calc_Filters * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

    function Init_ROM(weights_in : CNN_Weights_T; filt : natural; inp : natural;
                      elements : natural; calc_filt : natural; calc_stp : natural) return ROM_Array is
        variable rom_reg     : ROM_Array;
        variable filters_cnt : natural range 0 to filt := 0;
        variable inputs_cnt  : natural range 0 to inp := 0;
        variable element_cnt : natural range 0 to elements := 0;
        variable this_weight : std_logic_vector(CNN_Weight_Resolution-1 downto 0);
    begin
        filters_cnt := 0;
        inputs_cnt  := 0;
        element_cnt := 0;
        while inputs_cnt < inp loop
            filters_cnt := 0;
            while filters_cnt < filt loop
                for s in 0 to calc_stp-1 loop
                    for f in 0 to calc_filt-1 loop
                        this_weight := std_logic_vector(to_signed(weights_in(filters_cnt+f, inputs_cnt+s), CNN_Weight_Resolution));
                        rom_reg(element_cnt)(CNN_Weight_Resolution*(1+s*calc_filt+f)-1 downto CNN_Weight_Resolution*(s*calc_filt+f)) := this_weight;
                    end loop;
                end loop;
                filters_cnt := filters_cnt + calc_filt;
                element_cnt := element_cnt + 1;
            end loop;
            inputs_cnt := inputs_cnt + calc_stp;
        end loop;
        return rom_reg;
    end function;

    signal ROM      : ROM_Array := Init_ROM(Weights, Filters, Input_Values*matrix_values, Calc_Cycles*Matrix_Value_Cycles, Calc_Filters, Calc_Steps);
    signal ROM_Addr : natural range 0 to Calc_Cycles * Matrix_Value_Cycles - 1;
    signal ROM_Data : std_logic_vector(Calc_Filters * Calc_Steps * CNN_Weight_Resolution - 1 downto 0);

    -- Expand signals
    signal Expand_Stream : CNN_Stream_T;
    signal Expand_Data   : CNN_Values_T(Input_Values/Input_Cycles-1 downto 0) := (others => 0);

    -- Matrix signals
    signal Matrix_Stream : CNN_Stream_T;
    signal Matrix_Data   : CNN_Values_T(Calc_Steps-1 downto 0) := (others => 0);
    signal Matrix_Column : natural range 0 to Filter_Columns-1;
    signal Matrix_Row    : natural range 0 to Filter_Rows-1;
    signal Matrix_Input  : natural range 0 to Value_Cycles-1;

    -- SUM RAM
    type sum_set_t is array (0 to Calc_Filters-1) of signed(bits_max downto 0);
    type sum_ram_t is array (natural range <>) of sum_set_t;
    signal SUM_RAM     : sum_ram_t(0 to Calc_Cycles-1) := (others => (others => (others => '0')));
    signal SUM_Rd_Addr : natural range 0 to Calc_Cycles-1;
    signal SUM_Rd_Data : sum_set_t;
    signal SUM_Wr_Addr : natural range 0 to Calc_Cycles-1;
    signal SUM_Wr_Data : sum_set_t;
    signal SUM_Wr_Ena  : std_logic := '1';

    -- OUT RAM
    constant OUT_RAM_Elements : natural := min_val(Calc_Cycles, Filter_Cycles);
    type OUT_set_t is array (0 to Filters/OUT_RAM_Elements-1) of signed(CNN_Value_Resolution downto 0);
    type OUT_ram_t is array (natural range <>) of OUT_set_t;
    signal OUT_RAM     : OUT_ram_t(0 to OUT_RAM_Elements-1) := (others => (others => (others => '0')));
    signal OUT_Rd_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Rd_Data : OUT_set_t;
    signal OUT_Wr_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Wr_Data : OUT_set_t;
    signal OUT_Wr_Ena  : std_logic := '1';

    -- Internal control signals
    signal En         : boolean := false;
    signal iData_Buf  : CNN_Values_T((Input_Values*matrix_values)/Matrix_Value_Cycles-1 downto 0);
    signal Weights_Buf : CNN_Weights_T(0 to Calc_Filters-1, 0 to matrix_values*Input_Values/Matrix_Value_Cycles-1);
    signal last_input : std_logic := '0';
    signal add_bias   : boolean := false;
    signal Calc_buf2  : natural range 0 to Calc_Cycles-1 := 0;
    signal Valid_Reg_O : std_logic;
    signal oCycle_Cnt  : natural range 0 to Filter_Cycles-1 := Filter_Cycles-1;
    signal Delay_Cycle : natural range 0 to Filter_Delay-1 := Filter_Delay-1;

begin

    -- Expand generate
    gen_expand: if Expand generate
        u_expander: entity work.cnn_row_expander
            generic map (
                Input_Columns => Input_Columns,
                Input_Rows    => Input_Rows,
                Input_Values  => Input_Values,
                Input_Cycles  => Input_Cycles,
                Output_Cycles => max_val(Matrix_Value_Cycles*Calc_Cycles+1, Expand_Cycles)
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
            Calc_Cycles    => Calc_Cycles,
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

    -- ROM read
    process(Matrix_Stream.Data_CLK)
    begin
        if rising_edge(Matrix_Stream.Data_CLK) then
            ROM_Data <= ROM(ROM_Addr);
        end if;
    end process;

    oStream.Data_CLK <= Matrix_Stream.Data_CLK;

    -- SUM RAM process
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if SUM_Wr_Ena = '1' then
                SUM_RAM(SUM_Wr_Addr) <= SUM_Wr_Data;
            end if;
        end if;
    end process;
    SUM_Rd_Data <= SUM_RAM(SUM_Rd_Addr);

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

    -- Main computation process
    process(Matrix_Stream.Data_CLK)
        variable Cycle_Cnt   : natural range 0 to Matrix_Value_Cycles-1;
        variable cycle_buf   : natural range 0 to Matrix_Value_Cycles-1;
        variable Calc_Cnt    : natural range 0 to Calc_Cycles-1 := Calc_Cycles-1;
        variable Calc_buf    : natural range 0 to Calc_Cycles-1;
        variable Element_Cnt : natural range 0 to Calc_Cycles*Matrix_Value_Cycles-1;
        variable Element_buf : natural range 0 to Calc_Cycles*Matrix_Value_Cycles-1;
        variable Valid_Reg   : std_logic;

        variable Weights_Buf_Var : CNN_Weights_T(0 to Calc_Filters-1, 0 to matrix_values*Input_Values/Matrix_Value_Cycles-1);
        variable input_v    : natural range 0 to matrix_values*Input_Values-1;

        variable sum     : sum_set_t := (others => (others => '0'));
        variable sum_buf : sum_set_t := (others => (others => '0'));

        type Act_sum_t is array (Calc_Filters-1 downto 0) of signed(CNN_Value_Resolution downto 0);
        variable Act_sum : Act_sum_t;

        variable oCycle_Cnt_Var : natural range 0 to Filter_Cycles-1 := Filter_Cycles-1;
        variable oColumn_Buf : natural range 0 to CNN_Input_Columns-1;
        variable oRow_Buf    : natural range 0 to CNN_Input_Rows-1;

        constant Act_sum_buf_cycles : natural := Calc_Cycles/OUT_RAM_Elements;
        type Act_sum_buf_t is array (Act_sum_buf_cycles-1 downto 0) of Act_sum_t;
        variable Act_sum_buf     : Act_sum_buf_t;
        variable Act_sum_buf_cnt : natural range 0 to Act_sum_buf_cycles-1 := 0;
    begin
        if rising_edge(Matrix_Stream.Data_CLK) then
            -- Save previous state
            Calc_buf    := Calc_Cnt;
            cycle_buf   := Cycle_Cnt;
            Element_buf := Element_Cnt;

            if Matrix_Stream.Data_Valid = '1' then
                En        <= true;
                iData_Buf <= Matrix_Data;

                if Valid_Reg = '0' then
                    Element_Cnt := 0;
                elsif Element_Cnt < Calc_Cycles*Matrix_Value_Cycles-1 then
                    Element_Cnt := Element_Cnt + 1;
                end if;

                if Valid_Reg = '0' then
                    Cycle_Cnt := 0;
                    Calc_Cnt  := 0;
                elsif Calc_Cnt < Calc_Cycles-1 then
                    Calc_Cnt := Calc_Cnt + 1;
                elsif Cycle_Cnt < Matrix_Value_Cycles-1 then
                    Calc_Cnt  := 0;
                    Cycle_Cnt := Cycle_Cnt + 1;
                end if;
            end if;
            Valid_Reg := Matrix_Stream.Data_Valid;

            SUM_Wr_Addr <= SUM_Rd_Addr;
            SUM_Rd_Addr <= Calc_Cnt;

            -- ROM address
            if Matrix_Stream.Data_Valid = '1' then
                input_v := (matrix_values*Input_Values/Matrix_Value_Cycles)*Cycle_Cnt;
                if Element_Cnt < Calc_Cycles*Matrix_Value_Cycles-1 then
                    ROM_Addr <= Element_Cnt + 1;
                else
                    ROM_Addr <= 0;
                end if;
            else
                En <= false;
            end if;

            -- Decode weights from ROM
            for s in 0 to Calc_Steps-1 loop
                for f in 0 to Calc_Filters-1 loop
                    Weights_Buf_Var(f, s) := to_integer(signed(ROM_Data(CNN_Weight_Resolution*(1+s*Calc_Filters+f)-1 downto CNN_Weight_Resolution*(s*Calc_Filters+f))));
                end loop;
            end loop;

            last_input <= '0';
            add_bias   <= false;

            -- Bias addition and activation
            if add_bias then
                for o in 0 to Calc_Filters-1 loop
                    if Offset >= 0 then
                        sum_buf(o) := resize(sum_buf(o) + resize(shift_left(to_signed(Bias_Const(o+Calc_buf2*Calc_Filters, 0), CNN_Weight_Resolution+Offset), Offset), bits_max+1), bits_max+1);
                    else
                        sum_buf(o) := resize(sum_buf(o) + resize(shift_right(to_signed(Bias_Const(o+Calc_buf2*Calc_Filters, 0), CNN_Weight_Resolution), abs(Offset)), bits_max+1), bits_max+1);
                    end if;

                    if Offset_Diff > 0 then
                        sum_buf(o) := shift_right(sum_buf(o), Offset_Diff);
                    elsif Offset_Diff < 0 then
                        sum_buf(o) := shift_left(sum_buf(o), abs(Offset_Diff));
                    end if;

                    -- Activation function
                    if Activation = relu then
                        Act_sum(o) := resize(relu_f(sum_buf(o), value_max), CNN_Value_Resolution+1);
                    elsif Activation = linear then
                        Act_sum(o) := resize(linear_f(sum_buf(o), value_max), CNN_Value_Resolution+1);
                    elsif Activation = leaky_relu then
                        Act_sum(o) := resize(leaky_relu_f(sum_buf(o), value_max, bits_max), CNN_Value_Resolution+1);
                    elsif Activation = step_func then
                        Act_sum(o) := resize(step_f(sum_buf(o)), CNN_Value_Resolution+1);
                    elsif Activation = sign_func then
                        Act_sum(o) := resize(sign_f(sum_buf(o)), CNN_Value_Resolution+1);
                    end if;
                end loop;

                if Calc_Cycles = OUT_RAM_Elements then
                    OUT_Wr_Addr <= Calc_buf2;
                    for i in 0 to Calc_Filters-1 loop
                        OUT_Wr_Data(i) <= Act_sum(i);
                    end loop;
                else
                    Act_sum_buf_cnt := Calc_buf2 mod Act_sum_buf_cycles;
                    Act_sum_buf(Act_sum_buf_cnt) := Act_sum;
                    if Act_sum_buf_cnt = Act_sum_buf_cycles-1 then
                        OUT_Wr_Addr <= Calc_buf2/Act_sum_buf_cycles;
                        for i in 0 to Act_sum_buf_cycles-1 loop
                            for j in 0 to Calc_Filters-1 loop
                                OUT_Wr_Data(Calc_Filters*i + j) <= Act_sum_buf(i)(j);
                            end loop;
                        end loop;
                    end if;
                end if;
            end if;

            -- MAC computation
            if En then
                if Calc_Cycles > 1 then
                    sum := SUM_Rd_Data;
                end if;

                if cycle_buf = 0 then
                    sum := (others => (others => '0'));
                end if;

                Calc_buf2 <= Calc_buf;

                for o in 0 to Calc_Filters-1 loop
                    for i in 0 to (Input_Values*matrix_values/Matrix_Value_Cycles)-1 loop
                        sum(o) := resize(sum(o) + resize(shift_right(to_signed(iData_Buf(i) * Weights_Buf_Var(o, i) + (2**(CNN_Weight_Resolution-Offset-2)), CNN_Value_Resolution+CNN_Weight_Resolution), CNN_Weight_Resolution-Offset-1), bits_max+1), bits_max+1);
                    end loop;
                end loop;

                if cycle_buf = Matrix_Value_Cycles-1 then
                    if Calc_buf = Calc_Cycles-1 then
                        last_input <= '1';
                    end if;
                    sum_buf  := sum;
                    add_bias <= true;
                end if;

                if Calc_Cycles > 1 then
                    SUM_Wr_Data <= sum;
                end if;
            end if;

            -- Output stage
            Valid_Reg_O <= '0';
            if last_input = '1' then
                oCycle_Cnt_Var := 0;
                Delay_Cycle    <= 0;
                Valid_Reg_O    <= '1';
                oColumn_Buf    := Matrix_Stream.Column;
                oRow_Buf       := Matrix_Stream.Row;
            elsif Delay_Cycle < Filter_Delay-1 then
                Delay_Cycle <= Delay_Cycle + 1;
            elsif oCycle_Cnt < Filter_Cycles-1 then
                Delay_Cycle    <= 0;
                oCycle_Cnt_Var := oCycle_Cnt + 1;
                Valid_Reg_O    <= '1';
            end if;
            oCycle_Cnt <= oCycle_Cnt_Var;

            OUT_Rd_Addr <= oCycle_Cnt_Var / (Filter_Cycles/OUT_RAM_Elements);

            if Valid_Reg_O = '1' then
                for i in 0 to Out_Filters-1 loop
                    if Filter_Cycles = OUT_RAM_Elements then
                        oData(i) <= to_integer(OUT_Rd_Data(i));
                    else
                        oData(i) <= to_integer(OUT_Rd_Data(i + (oCycle_Cnt mod (Filter_Cycles/OUT_RAM_Elements))*Out_Filters));
                    end if;
                end loop;
                oStream.Filter     <= oCycle_Cnt * Out_Filters;
                oStream.Data_Valid <= '1';
                oStream.Row        <= oRow_Buf;
                oStream.Column     <= oColumn_Buf;
            else
                oStream.Data_Valid <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
