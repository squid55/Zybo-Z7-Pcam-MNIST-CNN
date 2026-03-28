------------------------------------------------------------------------
-- CNN Top Level - MNIST Digit Recognition
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/CNN.vhdp
-- Architecture: Conv1->Pool1->Conv2->Pool2->Conv3->Pool3->FC->Argmax
-- Input: 448x448 RGB stream -> Output: Digit 0-9 + Probability
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

library work;
use work.image_data_package.all;
use work.cnn_config_package.all;
use work.cnn_data_package.all;

entity cnn_top is
    generic (
        Input_Columns  : natural := 448;
        Input_Rows     : natural := 448;
        Column_Offset  : natural := 80;
        CNN_Columns    : natural := 28;
        CNN_Rows       : natural := 28
    );
    port (
        iStream     : in  rgb_stream;
        Prediction  : out natural range 0 to NN_Layer_1_Outputs-1;
        Probability : out CNN_Value_T
    );
end entity cnn_top;

architecture rtl of cnn_top is

    -- Preprocessing signals
    signal Pooling_iStream : rgb_stream;
    signal Pooling_oStream : rgb_stream;
    -- RGB to Grayscale: Gray = (77*R + 150*G + 29*B) >> 8
    -- Approximation of 0.299*R + 0.587*G + 0.114*B
    signal gray_val : std_logic_vector(7 downto 0);
    signal oStream_P       : CNN_Stream_T;
    signal oData_P         : CNN_Values_T(0 downto 0);

    -- Layer 1 signals
    signal oStream_12  : CNN_Stream_T;
    signal oData_12    : CNN_Values_T(Layer_1_Filters/4-1 downto 0);

    -- Pooling 1 signals
    signal oStream_P12 : CNN_Stream_T;
    signal oData_P12   : CNN_Values_T(Pooling_1_Values/4-1 downto 0);

    -- Layer 2 signals
    signal oStream_22  : CNN_Stream_T;
    signal oData_22    : CNN_Values_T(Layer_2_Filters/6-1 downto 0);

    -- Pooling 2 signals
    signal oStream_P22 : CNN_Stream_T;
    signal oData_P22   : CNN_Values_T(Pooling_2_Values/6-1 downto 0);

    -- Layer 3 signals
    signal oStream_32  : CNN_Stream_T;
    signal oData_32    : CNN_Values_T(Layer_3_Filters/8-1 downto 0);

    -- Pooling 3 signals
    signal oStream_P32 : CNN_Stream_T;
    signal oData_P32   : CNN_Values_T(Pooling_3_Values/8-1 downto 0);

    -- Flatten signals
    signal oStream_F   : CNN_Stream_T;
    signal oData_F     : CNN_Values_T(0 downto 0);

    -- NN Layer signals
    signal iStream_1N  : CNN_Stream_T;
    signal iData_1N    : CNN_Values_T(0 downto 0);
    signal oStream_1N  : CNN_Stream_T;
    signal oData_1N    : CNN_Values_T(NN_Layer_1_Outputs/10-1 downto 0);
    signal iCycle_1N   : natural range 0 to Flatten_Columns*Flatten_Rows*8 - 1;
    signal oCycle_1N   : natural range 0 to NN_Layer_1_Outputs-1;

    -- Output signals
    signal max_o        : CNN_Value_T;
    signal max_number_o : natural range 0 to NN_Layer_1_Outputs-1;

begin

    -- RGB to Grayscale conversion
    -- Gray = (77*R + 150*G + 29*B) >> 8  (approximation of BT.601)
    process(iStream.New_Pixel)
        variable r_mult : unsigned(15 downto 0);
        variable g_mult : unsigned(15 downto 0);
        variable b_mult : unsigned(15 downto 0);
        variable gray_sum : unsigned(15 downto 0);
    begin
        if rising_edge(iStream.New_Pixel) then
            r_mult  := to_unsigned(77, 8)  * unsigned(iStream.R);
            g_mult  := to_unsigned(150, 8) * unsigned(iStream.G);
            b_mult  := to_unsigned(29, 8)  * unsigned(iStream.B);
            gray_sum := r_mult + g_mult + b_mult;
            gray_val <= std_logic_vector(gray_sum(15 downto 8));
        end if;
    end process;

    -- Preprocessing: crop and forward grayscale
    process(iStream.New_Pixel)
    begin
        if rising_edge(iStream.New_Pixel) then
            if iStream.Row < Input_Rows then
                Pooling_iStream.Row <= iStream.Row;
            else
                Pooling_iStream.Row <= Input_Rows - 1;
            end if;

            if iStream.Row < Input_Rows and iStream.Column >= Column_Offset and iStream.Column < Input_Columns + Column_Offset then
                Pooling_iStream.Column <= iStream.Column - Column_Offset;
            else
                Pooling_iStream.Column <= Input_Columns - 1;
            end if;

            -- Use grayscale value instead of R-only
            Pooling_iStream.R <= gray_val;
        end if;
    end process;

    Pooling_iStream.New_Pixel <= iStream.New_Pixel;

    -- MAX Pooling (448x448 -> 28x28)
    u_max_pooling: entity work.max_pooling_pre
        generic map (
            Input_Columns  => Input_Columns,
            Input_Rows     => Input_Rows,
            Input_Values   => 1,
            Filter_Columns => Input_Columns / CNN_Columns,
            Filter_Rows    => Input_Rows / CNN_Rows
        )
        port map (
            iStream => Pooling_iStream,
            oStream => Pooling_oStream
        );

    -- RGB to CNN stream conversion
    u_rgb_to_cnn: entity work.rgb_to_cnn
        generic map (
            Input_Values => 1
        )
        port map (
            iStream => Pooling_oStream,
            oStream => oStream_P,
            oData   => oData_P
        );

    -- ===================== CNN LAYERS =====================

    -- Layer 1: Convolution (28x28x1 -> 28x28x4)
    u_conv1: entity work.cnn_convolution
        generic map (
            Input_Columns  => Layer_1_Columns,
            Input_Rows     => Layer_1_Rows,
            Input_Values   => Layer_1_Values,
            Filter_Columns => Layer_1_Filter_X,
            Filter_Rows    => Layer_1_Filter_Y,
            Filters        => Layer_1_Filters,
            Strides        => Layer_1_Strides,
            Activation     => Layer_1_Activation,
            Padding        => Layer_1_Padding,
            Value_Cycles   => 1,
            Calc_Cycles    => 4,
            Filter_Cycles  => 4,
            Expand_Cycles  => 240,
            Offset_In      => 0,
            Offset_Out     => Layer_1_Out_Offset - 3,
            Offset         => Layer_1_Offset,
            Weights        => Layer_1
        )
        port map (
            iStream => oStream_P,
            iData   => oData_P,
            oStream => oStream_12,
            oData   => oData_12
        );

    -- Pooling 1: Max Pool (28x28x4 -> 14x14x4)
    u_pool1: entity work.cnn_pooling
        generic map (
            Input_Columns  => Pooling_1_Columns,
            Input_Rows     => Pooling_1_Rows,
            Input_Values   => Pooling_1_Values,
            Filter_Columns => Pooling_1_Filter_X,
            Filter_Rows    => Pooling_1_Filter_Y,
            Strides        => Pooling_1_Strides,
            Padding        => Pooling_1_Padding,
            Input_Cycles   => 4,
            Value_Cycles   => 4,
            Filter_Cycles  => 4,
            Filter_Delay   => 1
        )
        port map (
            iStream => oStream_12,
            iData   => oData_12,
            oStream => oStream_P12,
            oData   => oData_P12
        );

    -- Layer 2: Convolution (14x14x4 -> 14x14x6)
    u_conv2: entity work.cnn_convolution
        generic map (
            Input_Columns  => Layer_2_Columns,
            Input_Rows     => Layer_2_Rows,
            Input_Values   => Layer_2_Values,
            Filter_Columns => Layer_2_Filter_X,
            Filter_Rows    => Layer_2_Filter_Y,
            Filters        => Layer_2_Filters,
            Strides        => Layer_2_Strides,
            Activation     => Layer_2_Activation,
            Padding        => Layer_2_Padding,
            Input_Cycles   => 4,
            Value_Cycles   => 4,
            Calc_Cycles    => 6,
            Filter_Cycles  => 6,
            Expand_Cycles  => 960,
            Offset_In      => Layer_1_Out_Offset,
            Offset_Out     => Layer_2_Out_Offset,
            Offset         => Layer_2_Offset,
            Weights        => Layer_2
        )
        port map (
            iStream => oStream_P12,
            iData   => oData_P12,
            oStream => oStream_22,
            oData   => oData_22
        );

    -- Pooling 2: Max Pool (14x14x6 -> 7x7x6)
    u_pool2: entity work.cnn_pooling
        generic map (
            Input_Columns  => Pooling_2_Columns,
            Input_Rows     => Pooling_2_Rows,
            Input_Values   => Pooling_2_Values,
            Filter_Columns => Pooling_2_Filter_X,
            Filter_Rows    => Pooling_2_Filter_Y,
            Strides        => Pooling_2_Strides,
            Padding        => Pooling_2_Padding,
            Input_Cycles   => 6,
            Value_Cycles   => 6,
            Filter_Cycles  => 6,
            Filter_Delay   => 1
        )
        port map (
            iStream => oStream_22,
            iData   => oData_22,
            oStream => oStream_P22,
            oData   => oData_P22
        );

    -- Layer 3: Convolution (7x7x6 -> 7x7x8)
    u_conv3: entity work.cnn_convolution
        generic map (
            Input_Columns  => Layer_3_Columns,
            Input_Rows     => Layer_3_Rows,
            Input_Values   => Layer_3_Values,
            Filter_Columns => Layer_3_Filter_X,
            Filter_Rows    => Layer_3_Filter_Y,
            Filters        => Layer_3_Filters,
            Strides        => Layer_3_Strides,
            Activation     => Layer_3_Activation,
            Padding        => Layer_3_Padding,
            Input_Cycles   => 6,
            Value_Cycles   => 6,
            Calc_Cycles    => 8,
            Filter_Cycles  => 8,
            Expand_Cycles  => 3840,
            Offset_In      => Layer_2_Out_Offset,
            Offset_Out     => Layer_3_Out_Offset,
            Offset         => Layer_3_Offset,
            Weights        => Layer_3
        )
        port map (
            iStream => oStream_P22,
            iData   => oData_P22,
            oStream => oStream_32,
            oData   => oData_32
        );

    -- Pooling 3: Max Pool (7x7x8 -> 3x3x8)
    u_pool3: entity work.cnn_pooling
        generic map (
            Input_Columns  => Pooling_3_Columns,
            Input_Rows     => Pooling_3_Rows,
            Input_Values   => Pooling_3_Values,
            Filter_Columns => Pooling_3_Filter_X,
            Filter_Rows    => Pooling_3_Filter_Y,
            Strides        => Pooling_3_Strides,
            Padding        => Pooling_3_Padding,
            Input_Cycles   => 8,
            Value_Cycles   => 8,
            Filter_Cycles  => 8,
            Filter_Delay   => NN_Layer_1_Outputs
        )
        port map (
            iStream => oStream_32,
            iData   => oData_32,
            oStream => oStream_P32,
            oData   => oData_P32
        );

    -- ===================== FLATTEN =====================

    oStream_F <= oStream_P32;
    oData_F   <= oData_P32;

    -- Flatten: convert 3D (3x3x8) to 1D index
    process(oStream_F.Data_CLK)
    begin
        if rising_edge(oStream_F.Data_CLK) then
            iCycle_1N             <= (oStream_F.Row * Flatten_Columns + oStream_F.Column) * Flatten_Values + oStream_F.Filter;
            iStream_1N.Data_Valid <= oStream_F.Data_Valid;
            iData_1N              <= oData_F;
        end if;
    end process;

    iStream_1N.Data_CLK <= oStream_F.Data_CLK;

    -- ===================== FC LAYER =====================

    u_nn_layer: entity work.nn_layer
        generic map (
            Inputs          => NN_Layer_1_Inputs,
            Outputs         => NN_Layer_1_Outputs,
            Activation      => NN_Layer_1_Activation,
            Calc_Cycles_In  => Flatten_Columns * Flatten_Rows * 8,
            Out_Cycles      => NN_Layer_1_Outputs,
            Calc_Cycles_Out => NN_Layer_1_Outputs,
            Offset_In       => Layer_3_Out_Offset,
            Offset_Out      => NN_Layer_1_Out_Offset,
            Offset          => NN_Layer_1_Offset,
            Weights         => NN_Layer_1
        )
        port map (
            iStream => iStream_1N,
            iData   => iData_1N,
            iCycle  => iCycle_1N,
            oStream => oStream_1N,
            oData   => oData_1N,
            oCycle  => oCycle_1N
        );

    -- ===================== ARGMAX =====================

    process(oStream_1N.Data_CLK)
        variable max_v        : CNN_Value_T;
        variable max_number_v : natural range 0 to NN_Layer_1_Outputs-1;
    begin
        if rising_edge(oStream_1N.Data_CLK) then
            if oStream_1N.Data_Valid = '1' then
                if oCycle_1N = 0 then
                    max_v        := 0;
                    max_number_v := 0;
                end if;
                if oData_1N(0) > max_v then
                    max_v        := oData_1N(0);
                    max_number_v := oCycle_1N;
                end if;
                if oCycle_1N = NN_Layer_1_Outputs-1 then
                    max_number_o <= max_number_v;
                    max_o        <= max_v;
                end if;
            end if;
        end if;
    end process;

    Prediction  <= max_number_o;
    Probability <= max_o;

end architecture rtl;
