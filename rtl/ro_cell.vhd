-- ro_cell.vhd — RO 单元 (自研 v2, 2026-10-29)
--   弃用上游 ring_oscillator (纯走线环): keep 线网无逻辑单元锚点, 布线器把
--   20 段"直通"布成任意长路径, 实测环频仅数百 Hz (板上 RO_CNT 诊断 0-2 沿/百万拍)。
--   本版: 24 级 LUT 反相器链环 (每级一个 LUT, 布线受单元约束, 周期 ~20-50ns),
--   输出 TFF 二分 (9-23MHz, 100MHz 采样奈奎斯特安全), keep 防合并。
--   结构参考: 上游 RuochenDai78 RO-PUF + stnolting/neoTRNG 反相链概念。
library IEEE;
use IEEE.std_logic_1164.all;

entity ro_cell is
  generic (CHAIN_WIDTH : positive := 32);   -- 偶数; 32 级: 二分后 18-38MHz, 100MHz 采样安全
  port (
    rstn   : in  std_logic;                  -- 1=振荡, 0=停振锁 0
    ro_out : out std_logic);
end entity ro_cell;

architecture wrap of ro_cell is
  signal chain : std_logic_vector(CHAIN_WIDTH downto 0);
  signal out_s : std_logic;

  attribute keep : string;
  attribute keep of chain : signal is "true";
  attribute keep of out_s : signal is "true";
  attribute keep_hierarchy : string;
  attribute keep_hierarchy of wrap : architecture is "yes";
begin

  chain(0) <= not chain(CHAIN_WIDTH) or (not rstn);  -- or 结构: 停振锁 1, 释放瞬间 1->0 跳变沿绕环 -> 保证起振 (and 版停在直流稳态永不起振, 2026-10-29 板上实测)
  inv_gen : for i in 1 to CHAIN_WIDTH generate
    chain(i) <= not chain(i-1);                     -- 反相器级 (LUT1)
  end generate;

  tff : process (rstn, chain(0))
  begin
    if (rstn = '0') then
      out_s <= '0';
    elsif (rising_edge(chain(0))) then
      out_s <= not out_s;                           -- 二分 -> 采样安全频率
    end if;
  end process;

  ro_out <= out_s;
end architecture wrap;
