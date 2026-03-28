------------------------------------------------------------------------
-- Image Data Package
-- Converted from VHDP to standard VHDL for Vivado
-- Original: OnSemi_CNN_Ultra/Libraries/OnSemi_Image_Data_USB.vhdp
-- Author: Leon Beier (Protop Solutions UG, 2020)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

package image_data_package is

    constant Image_Width    : natural := 646;
    constant Image_Height   : natural := 483;
    constant Image_FPS      : natural := 30;
    constant Image_Exposure : natural := 100;

    -- HDMI Timing
    constant HDMI_Width  : natural := 640;
    constant HDMI_Height : natural := 480;

    constant HBP_Len   : natural := 47;
    constant HFP_Len   : natural := 16;
    constant HSLEN_Len : natural := 96;

    constant VBP_Len   : natural := 33;
    constant VFP_Len   : natural := 10;
    constant VSLEN_Len : natural := 2;

    type rgb_data is record
        R : std_logic_vector(7 downto 0);
        G : std_logic_vector(7 downto 0);
        B : std_logic_vector(7 downto 0);
    end record rgb_data;

    type rgb_stream is record
        R         : std_logic_vector(7 downto 0);
        G         : std_logic_vector(7 downto 0);
        B         : std_logic_vector(7 downto 0);
        Column    : natural range 0 to Image_Width-1;
        Row       : natural range 0 to Image_Height-1;
        New_Pixel : std_logic;
    end record rgb_stream;

end package image_data_package;

package body image_data_package is
end package body image_data_package;
