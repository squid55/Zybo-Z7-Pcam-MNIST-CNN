------------------------------------------------------------------------
-- NN Layer (Fully Connected)
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN/NN_Layer.vhdp
-- Calculates outputs for one fully connected layer
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.cnn_config_package.all;

entity nn_layer is
    generic (
        Inputs          : natural := 16;
        Outputs         : natural := 8;
        Activation      : Activation_T := relu;
        Calc_Cycles_In  : natural := 1;
        Out_Cycles      : natural := 1;
        Out_Delay       : natural := 1;
        Calc_Cycles_Out : natural := 1;
        Offset_In       : natural := 0;
        Offset_Out      : natural := 0;
        Offset          : integer := 0;
        Weights         : CNN_Weights_T
    );
    port (
        iStream : in  CNN_Stream_T;
        iData   : in  CNN_Values_T(Inputs/Calc_Cycles_In-1 downto 0);
        iCycle  : in  natural range 0 to Calc_Cycles_In-1;
        oStream : out CNN_Stream_T;
        oData   : out CNN_Values_T(Outputs/Calc_Cycles_Out-1 downto 0);
        oCycle  : out natural range 0 to Calc_Cycles_Out-1
    );
end entity nn_layer;

architecture rtl of nn_layer is

    constant Calc_Outputs : natural := Outputs / Out_Cycles;
    constant Calc_Inputs  : natural := Inputs / Calc_Cycles_In;
    constant Out_Values   : natural := Outputs / Calc_Cycles_Out;
    constant Offset_Diff  : integer := Offset_Out - Offset_In;

    constant value_max : natural := 2**CNN_Value_Resolution - 1;
    constant bits_max  : natural := CNN_Value_Resolution + max_val(Offset, 0) + integer(ceil(log2(real(Inputs + 1))));

    -- Bias initialization
    function Init_Bias(weights_in : CNN_Weights_T; filt : natural; inp : natural) return CNN_Weights_T is
        variable Bias_Const : CNN_Weights_T(0 to filt-1, 0 to 0);
    begin
        for i in 0 to filt-1 loop
            Bias_Const(i, 0) := weights_in(i, inp);
        end loop;
        return Bias_Const;
    end function;

    constant Bias_Const : CNN_Weights_T(0 to Outputs-1, 0 to 0) := Init_Bias(Weights, Outputs, Inputs);

    -- ROM
    type ROM_Array is array (0 to Out_Cycles*Calc_Cycles_In-1)
        of std_logic_vector(Calc_Outputs * Calc_Inputs * CNN_Weight_Resolution - 1 downto 0);

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

    signal ROM      : ROM_Array := Init_ROM(Weights, Outputs, Inputs, Out_Cycles*Calc_Cycles_In, Calc_Outputs, Calc_Inputs);
    signal ROM_Addr : natural range 0 to Out_Cycles*Calc_Cycles_In-1;
    signal ROM_Data : std_logic_vector(Calc_Outputs * Calc_Inputs * CNN_Weight_Resolution - 1 downto 0);

    -- SUM RAM
    type sum_set_t is array (0 to Calc_Outputs-1) of signed(bits_max downto 0);
    type sum_ram_t is array (natural range <>) of sum_set_t;
    signal SUM_RAM     : sum_ram_t(0 to Out_Cycles-1) := (others => (others => (others => '0')));
    signal SUM_Rd_Addr : natural range 0 to Out_Cycles-1;
    signal SUM_Rd_Data : sum_set_t;
    signal SUM_Wr_Addr : natural range 0 to Out_Cycles-1;
    signal SUM_Wr_Data : sum_set_t;
    signal SUM_Wr_Ena  : std_logic := '1';

    -- OUT RAM
    constant OUT_RAM_Elements : natural := min_val(Out_Cycles, Calc_Cycles_Out);
    type OUT_set_t is array (0 to Outputs/OUT_RAM_Elements-1) of signed(CNN_Value_Resolution downto 0);
    type OUT_ram_t is array (natural range <>) of OUT_set_t;
    signal OUT_RAM     : OUT_ram_t(0 to OUT_RAM_Elements-1) := (others => (others => (others => '0')));
    signal OUT_Rd_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Rd_Data : OUT_set_t;
    signal OUT_Wr_Addr : natural range 0 to OUT_RAM_Elements-1;
    signal OUT_Wr_Data : OUT_set_t;
    signal OUT_Wr_Ena  : std_logic := '1';

    -- Control signals
    signal En          : boolean := false;
    signal iData_Buf   : CNN_Values_T(Inputs/Calc_Cycles_In-1 downto 0);
    signal Weights_Buf : CNN_Weights_T(0 to Calc_Outputs-1, 0 to Inputs/Calc_Cycles_In-1);
    signal last_input  : std_logic := '0';
    signal add_bias    : boolean := false;
    signal Offset_Buf  : natural range 0 to Outputs := 0;
    signal Count_Buf   : natural range 0 to Out_Cycles := 0;
    signal oCycle_Cnt  : natural range 0 to Calc_Cycles_Out-1 := Calc_Cycles_Out-1;
    signal Delay_Cycle : natural range 0 to Out_Delay-1 := Out_Delay-1;
    signal Valid_Reg_O : std_logic;

begin

    oStream.Data_CLK <= iStream.Data_CLK;

    -- ROM read
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            ROM_Data <= ROM(ROM_Addr);
        end if;
    end process;

    -- SUM RAM
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if SUM_Wr_Ena = '1' then
                SUM_RAM(SUM_Wr_Addr) <= SUM_Wr_Data;
            end if;
        end if;
    end process;
    SUM_Rd_Data <= SUM_RAM(SUM_Rd_Addr);

    -- OUT RAM
    process(iStream.Data_CLK)
    begin
        if rising_edge(iStream.Data_CLK) then
            if OUT_Wr_Ena = '1' then
                OUT_RAM(OUT_Wr_Addr) <= OUT_Wr_Data;
            end if;
        end if;
    end process;
    OUT_Rd_Data <= OUT_RAM(OUT_Rd_Addr);

    -- Main computation
    process(iStream.Data_CLK)
        variable Weights_Buf_Var : CNN_Weights_T(0 to Calc_Outputs-1, 0 to Calc_Inputs-1);
        variable sum         : sum_set_t := (others => (others => '0'));
        variable sum_buf     : sum_set_t := (others => (others => '0'));
        variable Out_Offset  : natural range 0 to Outputs := 0;
        variable Out_Count   : natural range 0 to Out_Cycles := 0;
        variable Element_Cnt : natural range 0 to Out_Cycles*Calc_Cycles_In-1 := 0;
        variable input_v     : natural range 0 to Inputs-1;

        type Act_sum_t is array (Calc_Outputs-1 downto 0) of signed(CNN_Value_Resolution downto 0);
        variable Act_sum : Act_sum_t;

        constant Act_sum_buf_cycles : natural := Out_Cycles/OUT_RAM_Elements;
        type Act_sum_buf_t is array (Act_sum_buf_cycles-1 downto 0) of Act_sum_t;
        variable Act_sum_buf     : Act_sum_buf_t;
        variable Act_sum_buf_cnt : natural range 0 to Act_sum_buf_cycles-1 := 0;

        variable oCycle_Cnt_Var : natural range 0 to Calc_Cycles_Out-1 := Calc_Cycles_Out-1;
    begin
        if rising_edge(iStream.Data_CLK) then
            last_input <= '0';
            add_bias   <= false;

            -- Decode weights from ROM
            for s in 0 to Calc_Inputs-1 loop
                for f in 0 to Calc_Outputs-1 loop
                    Weights_Buf_Var(f, s) := to_integer(signed(ROM_Data(CNN_Weight_Resolution*(1+s*Calc_Outputs+f)-1 downto CNN_Weight_Resolution*(s*Calc_Outputs+f))));
                end loop;
            end loop;

            -- Bias addition and activation
            if add_bias then
                for o in 0 to Calc_Outputs-1 loop
                    if Offset >= 0 then
                        sum_buf(o) := resize(sum_buf(o) + resize(shift_left(to_signed(Bias_Const(o+Offset_Buf, 0), CNN_Weight_Resolution+Offset), Offset), bits_max+1), bits_max+1);
                    else
                        sum_buf(o) := resize(sum_buf(o) + resize(shift_right(to_signed(Bias_Const(o+Offset_Buf, 0), CNN_Weight_Resolution), abs(Offset)), bits_max+1), bits_max+1);
                    end if;

                    if Offset_Diff > 0 then
                        sum_buf(o) := shift_right(sum_buf(o), Offset_Diff);
                    elsif Offset_Diff < 0 then
                        sum_buf(o) := shift_left(sum_buf(o), abs(Offset_Diff));
                    end if;

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

                if Out_Cycles = OUT_RAM_Elements then
                    OUT_Wr_Addr <= Count_Buf;
                    for i in 0 to Calc_Outputs-1 loop
                        OUT_Wr_Data(i) <= Act_sum(i);
                    end loop;
                else
                    Act_sum_buf_cnt := Count_Buf mod Act_sum_buf_cycles;
                    Act_sum_buf(Act_sum_buf_cnt) := Act_sum;
                    if Act_sum_buf_cnt = Act_sum_buf_cycles-1 then
                        OUT_Wr_Addr <= Count_Buf/Act_sum_buf_cycles;
                        for i in 0 to Act_sum_buf_cycles-1 loop
                            for j in 0 to Calc_Outputs-1 loop
                                OUT_Wr_Data(Calc_Outputs*i + j) <= Act_sum_buf(i)(j);
                            end loop;
                        end loop;
                    end if;
                end if;
            end if;

            -- MAC computation
            if En then
                if Out_Cycles > 1 then
                    sum := SUM_Rd_Data;
                end if;

                if input_v = 0 then
                    sum := (others => (others => '0'));
                end if;

                for o in 0 to Calc_Outputs-1 loop
                    for i in 0 to Inputs/Calc_Cycles_In-1 loop
                        sum(o) := resize(sum(o) + resize(shift_right(to_signed(iData_Buf(i) * Weights_Buf_Var(o, i) + (2**(CNN_Weight_Resolution-Offset-2)), CNN_Value_Resolution+CNN_Weight_Resolution), CNN_Weight_Resolution-Offset-1), bits_max+1), bits_max+1);
                    end loop;
                end loop;

                Offset_Buf <= Out_Offset;
                Count_Buf  <= Out_Count;

                if input_v = (Inputs/Calc_Cycles_In)*(Calc_Cycles_In-1) then
                    if Out_Offset = Outputs - Calc_Outputs then
                        last_input <= '1';
                    end if;
                    sum_buf  := sum;
                    add_bias <= true;
                end if;

                if Out_Cycles > 1 then
                    SUM_Wr_Data <= sum;
                end if;
            end if;

            -- Input control
            if iStream.Data_Valid = '1' then
                En         <= true;
                iData_Buf  <= iData;
                Out_Offset := 0;
                Out_Count  := 0;
                input_v    := Calc_Inputs * iCycle;

                if iCycle = 0 then
                    Element_Cnt := 0;
                else
                    Element_Cnt := Element_Cnt + 1;
                end if;
            elsif Out_Count < Out_Cycles-1 then
                Out_Offset  := Out_Offset + Calc_Outputs;
                Out_Count   := Out_Count + 1;
                Element_Cnt := Element_Cnt + 1;
            else
                En         <= false;
                Out_Offset := Outputs;
            end if;

            SUM_Wr_Addr <= SUM_Rd_Addr;
            SUM_Rd_Addr <= Out_Count;

            -- ROM address
            if iStream.Data_Valid = '1' or Out_Offset < Outputs then
                if Element_Cnt < Out_Cycles*Calc_Cycles_In-1 then
                    ROM_Addr <= Element_Cnt + 1;
                else
                    ROM_Addr <= 0;
                end if;
            end if;

            -- Output stage
            Valid_Reg_O <= '0';
            if last_input = '1' then
                oCycle_Cnt_Var := 0;
                Delay_Cycle    <= 0;
                Valid_Reg_O    <= '1';
            elsif Delay_Cycle < Out_Delay-1 then
                Delay_Cycle <= Delay_Cycle + 1;
            elsif oCycle_Cnt < Calc_Cycles_Out-1 then
                Delay_Cycle    <= 0;
                oCycle_Cnt_Var := oCycle_Cnt + 1;
                Valid_Reg_O    <= '1';
            end if;
            oCycle_Cnt <= oCycle_Cnt_Var;

            OUT_Rd_Addr <= oCycle_Cnt_Var / (Calc_Cycles_Out/OUT_RAM_Elements);

            if Delay_Cycle = 0 then
                for i in 0 to Out_Values-1 loop
                    if Calc_Cycles_Out = OUT_RAM_Elements then
                        oData(i) <= to_integer(OUT_Rd_Data(i));
                    else
                        oData(i) <= to_integer(OUT_Rd_Data(i + (oCycle_Cnt mod (Calc_Cycles_Out/OUT_RAM_Elements))*Out_Values));
                    end if;
                end loop;
                oCycle             <= oCycle_Cnt * (Outputs/Calc_Cycles_Out);
                oStream.Data_Valid <= Valid_Reg_O;
            else
                oStream.Data_Valid <= '0';
            end if;
        end if;
    end process;

end architecture rtl;
