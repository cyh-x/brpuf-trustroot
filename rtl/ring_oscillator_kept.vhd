library IEEE;
use IEEE.std_logic_1164.all;
use IEEE.numeric_std.all;

entity ring_oscillator is
  generic (
    CHAIN_WIDTH : positive := 50);      -- must be an even number
  port (
    rstn   : in  std_logic;
    output : out std_logic);
end entity ring_oscillator;

-- [LOCAL PATCH 2026-10-29, strongpuf_port / Vivado 2026.1] ----------------------
-- 上游用 Altera 的 syn_keep 属性; Xilinx 下无效 => Vivado 2026.1 会把结构完全
-- 相同的 256 个 RO 时序等效合并成 1 个 (ax7020_port/fpga_puf 同款事故)。
-- 换成 Xilinx 的 keep + keep_hierarchy, 其余逻辑与上游逐位一致。
-- 上游: github.com/RuochenDai78/EEE5716_...Ring-Oscillator-PUF...-for-FPGA (master)
architecture rtl of ring_oscillator is
  signal chain                : unsigned(CHAIN_WIDTH downto 0);
  signal output_s             : std_logic;
  attribute keep              : string;
  attribute keep of chain     : signal is "true";
  attribute keep_hierarchy    : string;
  attribute keep_hierarchy of rtl : architecture is "yes";
begin
  U0_GEN_OSC_CHAIN : for i in 1 to CHAIN_WIDTH
  generate
    chain(i) <= chain(i - 1);
  end generate;
  chain(0) <= not chain(CHAIN_WIDTH) or (not rstn);

  U1_PROC_TFF : process (rstn, chain(0))
  begin
    if rstn = '0' then
      output_s <= '0';
    else
      if rising_edge(chain(0)) then
        output_s <= not output_s;
      end if;
    end if;
  end process;
  output <= output_s;
end architecture rtl;