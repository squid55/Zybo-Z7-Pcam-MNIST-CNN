------------------------------------------------------------------------
-- CNN Result AXI-Lite Register
-- CNN의 Prediction/Probability를 Zynq PS(ARM)에서 읽을 수 있도록
-- AXI-Lite 슬레이브 인터페이스 제공
--
-- Register Map:
--   0x00: Prediction  (4-bit, read-only, 0~9)
--   0x04: Probability (10-bit, read-only, 0~1023)
--   0x08: Status      (bit0=result_valid, read-only)
------------------------------------------------------------------------
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity cnn_result_axilite is
    port (
        -- CNN result inputs
        prediction  : in  natural range 0 to 9;
        probability : in  natural range 0 to 1023;

        -- AXI-Lite Slave interface
        S_AXI_ACLK    : in  std_logic;
        S_AXI_ARESETN : in  std_logic;

        S_AXI_ARADDR  : in  std_logic_vector(3 downto 0);
        S_AXI_ARVALID : in  std_logic;
        S_AXI_ARREADY : out std_logic;

        S_AXI_RDATA   : out std_logic_vector(31 downto 0);
        S_AXI_RRESP   : out std_logic_vector(1 downto 0);
        S_AXI_RVALID  : out std_logic;
        S_AXI_RREADY  : in  std_logic;

        -- Write channel (unused but required for AXI-Lite)
        S_AXI_AWADDR  : in  std_logic_vector(3 downto 0);
        S_AXI_AWVALID : in  std_logic;
        S_AXI_AWREADY : out std_logic;
        S_AXI_WDATA   : in  std_logic_vector(31 downto 0);
        S_AXI_WSTRB   : in  std_logic_vector(3 downto 0);
        S_AXI_WVALID  : in  std_logic;
        S_AXI_WREADY  : out std_logic;
        S_AXI_BRESP   : out std_logic_vector(1 downto 0);
        S_AXI_BVALID  : out std_logic;
        S_AXI_BREADY  : in  std_logic
    );
end entity cnn_result_axilite;

architecture rtl of cnn_result_axilite is

    signal arready_reg : std_logic := '0';
    signal rvalid_reg  : std_logic := '0';
    signal rdata_reg   : std_logic_vector(31 downto 0) := (others => '0');

    -- Sync CNN results to AXI clock domain
    signal pred_sync : natural range 0 to 9 := 0;
    signal prob_sync : natural range 0 to 1023 := 0;

begin

    -- Sync CNN outputs
    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            pred_sync <= prediction;
            prob_sync <= probability;
        end if;
    end process;

    -- Write channel: accept and ignore (read-only registers)
    S_AXI_AWREADY <= '1';
    S_AXI_WREADY  <= '1';
    S_AXI_BRESP   <= "00";
    S_AXI_BVALID  <= S_AXI_AWVALID and S_AXI_WVALID;

    -- Read channel
    S_AXI_ARREADY <= arready_reg;
    S_AXI_RDATA   <= rdata_reg;
    S_AXI_RRESP   <= "00";  -- OKAY
    S_AXI_RVALID  <= rvalid_reg;

    process(S_AXI_ACLK)
    begin
        if rising_edge(S_AXI_ACLK) then
            if S_AXI_ARESETN = '0' then
                arready_reg <= '0';
                rvalid_reg  <= '0';
                rdata_reg   <= (others => '0');
            else
                -- Default
                arready_reg <= '0';

                -- Read address handshake
                if S_AXI_ARVALID = '1' and arready_reg = '0' and rvalid_reg = '0' then
                    arready_reg <= '1';

                    -- Decode address
                    case S_AXI_ARADDR(3 downto 2) is
                        when "00" =>  -- 0x00: Prediction
                            rdata_reg <= std_logic_vector(to_unsigned(pred_sync, 32));
                        when "01" =>  -- 0x04: Probability
                            rdata_reg <= std_logic_vector(to_unsigned(prob_sync, 32));
                        when "10" =>  -- 0x08: Status (always valid)
                            rdata_reg <= x"00000001";
                        when others =>
                            rdata_reg <= (others => '0');
                    end case;

                    rvalid_reg <= '1';
                end if;

                -- Read data handshake
                if rvalid_reg = '1' and S_AXI_RREADY = '1' then
                    rvalid_reg <= '0';
                end if;
            end if;
        end if;
    end process;

end architecture rtl;
