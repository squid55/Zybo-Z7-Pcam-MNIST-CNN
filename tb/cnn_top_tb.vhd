------------------------------------------------------------------------
-- CNN Top Testbench
-- 28x28 테스트 이미지 (숫자 "1" 패턴)를 CNN에 입력하고
-- Prediction/Probability 출력을 확인
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

library work;
use work.image_data_package.all;
use work.cnn_config_package.all;
use work.cnn_data_package.all;

entity cnn_top_tb is
end entity cnn_top_tb;

architecture sim of cnn_top_tb is

    -- DUT signals
    signal iStream     : rgb_stream;
    signal Prediction  : natural range 0 to NN_Layer_1_Outputs-1;
    signal Probability : CNN_Value_T;

    -- Testbench control
    signal clk         : std_logic := '0';
    signal sim_done    : boolean := false;

    -- Image constants
    constant IMG_W : natural := 448;
    constant IMG_H : natural := 448;
    constant CLK_PERIOD : time := 40 ns;  -- 25 MHz pixel clock

    -- Simple digit "1" pattern (28x28, mapped to 448x448)
    -- Returns grayscale intensity for a given 28x28 coordinate
    function digit_one_pixel(row : natural; col : natural) return natural is
    begin
        -- Draw a vertical line (digit "1") in center area
        -- Column 12~15, Row 4~23 = white stroke
        -- Plus small top serif at row 4~6, col 10~15
        if row >= 4 and row <= 6 and col >= 10 and col <= 15 then
            return 220;  -- top serif
        elsif row >= 4 and row <= 23 and col >= 13 and col <= 15 then
            return 240;  -- vertical stroke
        elsif row >= 22 and row <= 24 and col >= 10 and col <= 18 then
            return 220;  -- bottom base
        else
            return 10;   -- background (near black)
        end if;
    end function;

begin

    -- Clock generation
    clk <= not clk after CLK_PERIOD/2 when not sim_done else '0';
    iStream.New_Pixel <= clk;

    -- DUT instantiation
    u_dut: entity work.cnn_top
        generic map (
            Input_Columns => IMG_W,
            Input_Rows    => IMG_H,
            Column_Offset => 80,
            CNN_Columns   => 28,
            CNN_Rows      => 28
        )
        port map (
            iStream     => iStream,
            Prediction  => Prediction,
            Probability => Probability
        );

    -- Stimulus process: generate 448x448 image stream
    p_stim: process
        variable pixel_row : natural;
        variable pixel_col : natural;
        variable cnn_row   : natural;
        variable cnn_col   : natural;
        variable gray      : natural;
    begin
        -- Initialize
        iStream.R <= (others => '0');
        iStream.G <= (others => '0');
        iStream.B <= (others => '0');
        iStream.Column <= 0;
        iStream.Row    <= 0;
        wait for CLK_PERIOD * 5;

        -- Send 2 full frames
        for frame in 0 to 1 loop
            report "=== Frame " & integer'image(frame) & " start ===";

            for r in 0 to IMG_H-1 loop
                for c in 0 to IMG_W-1 loop
                    -- Map 448x448 to 28x28 for pattern lookup
                    cnn_row := r / 16;  -- 448/28 = 16
                    cnn_col := c / 16;

                    if cnn_row < 28 and cnn_col < 28 then
                        gray := digit_one_pixel(cnn_row, cnn_col);
                    else
                        gray := 0;
                    end if;

                    -- Set RGB (grayscale: R=G=B)
                    iStream.R <= std_logic_vector(to_unsigned(gray, 8));
                    iStream.G <= std_logic_vector(to_unsigned(gray, 8));
                    iStream.B <= std_logic_vector(to_unsigned(gray, 8));

                    -- Set coordinates (with offset for Column)
                    iStream.Column <= (c + 80) mod Image_Width;
                    iStream.Row    <= r mod Image_Height;

                    wait for CLK_PERIOD;
                end loop;
            end loop;

            report "=== Frame " & integer'image(frame) & " end ===" &
                   " Prediction=" & integer'image(Prediction) &
                   " Probability=" & integer'image(Probability);
        end loop;

        -- Wait for pipeline to flush
        for i in 0 to 10000 loop
            iStream.R <= (others => '0');
            iStream.G <= (others => '0');
            iStream.B <= (others => '0');
            iStream.Column <= 0;
            iStream.Row    <= 0;
            wait for CLK_PERIOD;
        end loop;

        report "=== FINAL RESULT ===" &
               " Prediction=" & integer'image(Prediction) &
               " Probability=" & integer'image(Probability);

        sim_done <= true;
        wait;
    end process;

    -- Monitor process: watch for prediction changes
    p_monitor: process(clk)
        variable prev_pred : natural := 99;
    begin
        if rising_edge(clk) then
            if Prediction /= prev_pred and Probability > 0 then
                report ">> Prediction changed: " & integer'image(Prediction) &
                       " (prob=" & integer'image(Probability) & ")";
                prev_pred := Prediction;
            end if;
        end if;
    end process;

end architecture sim;
