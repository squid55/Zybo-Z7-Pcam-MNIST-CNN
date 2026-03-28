------------------------------------------------------------------------
-- CNN Config Package
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/CNN_Config.vhdp
-- Author: Leon Beier (Protop Solutions UG, 2020)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use ieee.math_real.all;

package cnn_config_package is

    constant CNN_Value_Resolution     : natural := 10;
    constant CNN_Weight_Resolution    : natural := 8;
    constant CNN_Parameter_Resolution : natural := 8;

    constant CNN_Input_Columns : natural := 448;
    constant CNN_Input_Rows    : natural := 448;
    constant CNN_Max_Filters   : natural := 8;

    -- Values are always positive (ReLU)
    constant CNN_Value_Negative : natural := 0;
    subtype CNN_Value_T is natural range 0 to 2**CNN_Value_Resolution - 1;

    type CNN_Values_T       is array (natural range <>) of CNN_Value_T;
    type CNN_Value_Matrix_T is array (natural range <>, natural range <>, natural range <>) of CNN_Value_T;

    subtype CNN_Weight_T is integer range (-(2**(CNN_Weight_Resolution-1)-1)) to (2**(CNN_Weight_Resolution-1)-1);
    type CNN_Weights_T   is array (natural range <>, natural range <>) of CNN_Weight_T;

    subtype CNN_Parameter_T is integer range (-(2**(CNN_Parameter_Resolution-1)-1)) to (2**(CNN_Parameter_Resolution-1)-1);
    type CNN_Parameters_T   is array (natural range <>, natural range <>) of CNN_Parameter_T;

    type CNN_Stream_T is record
        Column     : natural range 0 to CNN_Input_Columns-1;
        Row        : natural range 0 to CNN_Input_Rows-1;
        Filter     : natural range 0 to CNN_Max_Filters-1;
        Data_Valid : std_logic;
        Data_CLK   : std_logic;
    end record CNN_Stream_T;

    type Activation_T is (relu, linear, leaky_relu, step_func, sign_func);
    type Padding_T    is (valid, same);

    constant leaky_relu_mult : CNN_Weight_T := (2**(CNN_Weight_Resolution-1))/10;

    function max_val(a : integer; b : integer) return integer;
    function min_val(a : integer; b : integer) return integer;

    function relu_f(i : integer; max : integer) return integer;
    function relu_f(i : signed; max : integer) return signed;

    function linear_f(i : integer; max : integer) return integer;
    function linear_f(i : signed; max : integer) return signed;

    function leaky_relu_f(i : integer; max : integer; max_bits : integer) return integer;
    function leaky_relu_f(i : signed; max : integer; max_bits : integer) return signed;

    function step_f(i : integer) return integer;
    function step_f(i : signed) return signed;

    function sign_f(i : integer) return integer;
    function sign_f(i : signed) return signed;

    function Bool_Select(Sel : boolean; Value : natural; Alternative : natural) return natural;

end package cnn_config_package;

package body cnn_config_package is

    function max_val(a : integer; b : integer) return integer is
    begin
        if a > b then
            return a;
        else
            return b;
        end if;
    end function;

    function min_val(a : integer; b : integer) return integer is
    begin
        if a < b then
            return a;
        else
            return b;
        end if;
    end function;

    function relu_f(i : integer; max : integer) return integer is
    begin
        if i > 0 then
            if i < max then
                return i;
            else
                return max;
            end if;
        else
            return 0;
        end if;
    end function;

    function relu_f(i : signed; max : integer) return signed is
    begin
        if i > 0 then
            if i < to_signed(max, i'length) then
                return i;
            else
                return to_signed(max, i'length);
            end if;
        else
            return to_signed(0, i'length);
        end if;
    end function;

    function linear_f(i : integer; max : integer) return integer is
    begin
        if i < max then
            if i > max*(-1) then
                return i;
            else
                return max*(-1);
            end if;
        else
            return max;
        end if;
    end function;

    function linear_f(i : signed; max : integer) return signed is
    begin
        if i < to_signed(max, i'length) then
            if abs(i) < to_signed(max, i'length) then
                return i;
            else
                return to_signed(max*(-1), i'length);
            end if;
        else
            return to_signed(max, i'length);
        end if;
    end function;

    function leaky_relu_f(i : integer; max : integer; max_bits : integer) return integer is
        variable i_reg : integer range (-(2**max_bits-1)) to (2**max_bits-1);
    begin
        if i > 0 then
            if i < max then
                return i;
            else
                return max;
            end if;
        else
            i_reg := to_integer(shift_right(to_signed(i * leaky_relu_mult, max_bits+CNN_Weight_Resolution-1), CNN_Weight_Resolution-1));
            if i_reg > max*(-1) then
                return i_reg;
            else
                return max*(-1);
            end if;
        end if;
    end function;

    function leaky_relu_f(i : signed; max : integer; max_bits : integer) return signed is
        variable i_reg : signed(max_bits-1 downto 0);
    begin
        if i > 0 then
            if i < to_signed(max, i'length) then
                return i;
            else
                return to_signed(max, i'length);
            end if;
        else
            i_reg := resize(shift_right(resize(i, max_bits+CNN_Weight_Resolution-1) * to_signed(leaky_relu_mult, max_bits+CNN_Weight_Resolution-1), CNN_Weight_Resolution-1), max_bits);
            if i_reg > to_signed(max*(-1), i'length) then
                return resize(i_reg, i'length);
            else
                return to_signed(max*(-1), i'length);
            end if;
        end if;
    end function;

    function step_f(i : integer) return integer is
    begin
        if i >= 0 then
            return 2**(CNN_Weight_Resolution-1);
        else
            return 0;
        end if;
    end function;

    function step_f(i : signed) return signed is
    begin
        if i >= 0 then
            return to_signed(2**(CNN_Weight_Resolution-1), i'length);
        else
            return to_signed(0, i'length);
        end if;
    end function;

    function sign_f(i : integer) return integer is
    begin
        if i > 0 then
            return 2**(CNN_Weight_Resolution-1);
        elsif i < 0 then
            return (2**(CNN_Weight_Resolution-1))*(-1);
        else
            return 0;
        end if;
    end function;

    function sign_f(i : signed) return signed is
    begin
        if i > 0 then
            return to_signed(2**(CNN_Weight_Resolution-1), i'length);
        elsif i < 0 then
            return to_signed((2**(CNN_Weight_Resolution-1))*(-1), i'length);
        else
            return to_signed(0, i'length);
        end if;
    end function;

    function Bool_Select(Sel : boolean; Value : natural; Alternative : natural) return natural is
    begin
        if Sel then
            return Value;
        else
            return Alternative;
        end if;
    end function;

end package body cnn_config_package;
