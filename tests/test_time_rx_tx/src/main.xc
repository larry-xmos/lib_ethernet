// Copyright (c) 2011, XMOS Ltd, All rights reserved
// This software is freely distributable under a derivative of the
// University of Illinois/NCSA Open Source License posted in
// LICENSE.txt and at <http://github.xcore.com/>
#include <xs1.h>
#include <platform.h>
#include "ethernet.h"
#include "xta_test_pragmas.h"
#include "debug_print.h"
#include "syscall.h"
#include "helpers.xc"

#include "ports.h"
port p_ctrl = on tile[0]: XS1_PORT_1C;

typedef enum {
  STATUS_ACTIVE,
  STATUS_DONE
} status_t;

typedef interface control_if {
  [[notification]] slave void status_changed();
  [[clears_notification]] void get_status(status_t &status);
} control_if;


#define NUM_PACKET_LENGTHS 64

void test_tx(client ethernet_tx_if tx, streaming chanend ? c_tx_hp)
{
  // Send a burst of frames to test the TX performance of the MAC layer and buffering
  // Just repeat the same frame numerous times to eliminate the frame setup time

  char data[ETHERNET_MAX_PACKET_SIZE];
  int lengths[NUM_PACKET_LENGTHS];

  const int header_bytes = 14;

  // Choose random packet lengths (but there must at least be a header)
  const int min_data_bytes = header_bytes;
  random_generator_t rand = random_create_generator_from_seed(1);
  for (int i = 0; i < NUM_PACKET_LENGTHS; i++) {
    int do_small_packet = (random_get_random_number(rand) & 0xff) > 50;
    if (do_small_packet)
      lengths[i] = random_get_random_number(rand) % (100 - min_data_bytes);
    else
      lengths[i] = random_get_random_number(rand) % (ETHERNET_MAX_PACKET_SIZE - min_data_bytes);

    lengths[i] += min_data_bytes;
  }

  // src/dst MAC addresses
  size_t j = 0;
  for (; j < 12; j++)
    data[j] = j;

  // Populate the packet with known data
  int x = 0;
  const int step = 10;
  for (; j < ETHERNET_MAX_PACKET_SIZE; j++) {
    x += step;
    data[j] = x;
  }

  while (1) {
    int do_burst = (random_get_random_number(rand) & 0xff) > 200;
    int len_index = random_get_random_number(rand) & (NUM_PACKET_LENGTHS - 1);
    int burst_len = 1;

    if (do_burst) {
      burst_len = random_get_random_number(rand) & 0xf;
    }

    for (int i = 0; i < burst_len; i++) {
      int length = lengths[len_index];

      // Send a valid length in the ether len/type field
      data[12] = (length - header_bytes) >> 8;
      data[13] = (length - header_bytes) & 0xff;

      if (isnull(c_tx_hp)) {
        tx.send_packet(data, length, ETHERNET_ALL_INTERFACES);
      }
      else {
        c_tx_hp <: length;
        sout_char_array(c_tx_hp, data, length);
      }
    }
  }
}

#if (RGMII) || (ETHERNET_SUPPORT_HP_QUEUES)

void test_rx(client ethernet_cfg_if cfg,
             streaming chanend c_rx_hp,
             client control_if ctrl)
{
  ethernet_macaddr_filter_t macaddr_filter;

  macaddr_filter.vlan = 0;
  macaddr_filter.appdata = 0;
  for (int i = 0; i < 6; i++)
    macaddr_filter.addr[i] = i;
  cfg.add_macaddr_filter(0, 1, macaddr_filter);

  int num_bytes = 0;
  int done = 0;
  while (!done) {
    ethernet_packet_info_t packet_info;

    #pragma ordered
    select {
    case sin_char_array(c_rx_hp, (char *)&packet_info, sizeof(packet_info)):
      unsigned char rxbuf[ETHERNET_MAX_PACKET_SIZE];
      sin_char_array(c_rx_hp, rxbuf, packet_info.len);
      num_bytes += packet_info.len;
      break;

    case ctrl.status_changed():
      status_t status;
      ctrl.get_status(status);
      if (status == STATUS_DONE)
        done = 1;
      break;
    }
  }
  debug_printf("Received %d bytes\n", num_bytes);
  while (1) {
    // Wait for the test to be terminated by testbench
  }
}

#else

void test_rx(client ethernet_cfg_if cfg,
             client ethernet_rx_if rx,
             client control_if ctrl)
{
  ethernet_macaddr_filter_t macaddr_filter;

  macaddr_filter.vlan = 0;
  for (int i = 0; i < 6; i++)
    macaddr_filter.addr[i] = i;

  size_t index = rx.get_index();
  cfg.add_macaddr_filter(index, 0, macaddr_filter);

  int num_bytes = 0;
  int done = 0;
  while (!done) {
    #pragma ordered
    select {
    case rx.packet_ready():
      unsigned char rxbuf[ETHERNET_MAX_PACKET_SIZE];
      ethernet_packet_info_t packet_info;
      rx.get_packet(packet_info, rxbuf, ETHERNET_MAX_PACKET_SIZE);
      num_bytes += packet_info.len;
      break;

    case ctrl.status_changed():
      status_t status;
      ctrl.get_status(status);
      if (status == STATUS_DONE)
        done = 1;
      break;
    }
  }
  debug_printf("Received %d bytes\n", num_bytes);
  while (1) {
    // Wait for the test to be terminated by testbench
  }
}

#endif

void control(port p_ctrl, server control_if ctrl)
{
  int tmp;
  status_t current_status = STATUS_ACTIVE;

  while (1) {
    select {
    case current_status != STATUS_DONE => p_ctrl when pinseq(1) :> tmp:
      current_status = STATUS_DONE;
      ctrl.status_changed();
      break;
    case ctrl.get_status(status_t &status):
      status = current_status;
      break;
    }
  }
}

#define ETH_RX_BUFFER_SIZE_WORDS 1600

#define NUM_CFG_IF 1
#define NUM_RX_LP_IF 1
#define NUM_TX_LP_IF 1

int main()
{
  ethernet_cfg_if i_cfg[NUM_CFG_IF];
  ethernet_rx_if i_rx_lp[NUM_RX_LP_IF];
  ethernet_tx_if i_tx_lp[NUM_TX_LP_IF];
  streaming chan c_rx_hp;
  streaming chan c_tx_hp;
  control_if i_ctrl;

  par {
    #if RGMII

    on tile[1]: rgmii_ethernet_mac(i_cfg, NUM_CFG_IF,
                                   i_rx_lp, NUM_RX_LP_IF,
                                   i_tx_lp, NUM_TX_LP_IF,
                                   c_rx_hp, c_tx_hp,
                                   p_eth_rxclk, p_eth_rxer, p_eth_rxd_1000, p_eth_rxd_10_100,
                                   p_eth_rxd_interframe, p_eth_rxdv, p_eth_rxdv_interframe,
                                   p_eth_txclk_in, p_eth_txclk_out, p_eth_txer, p_eth_txen,
                                   p_eth_txd, eth_rxclk, eth_rxclk_interframe, eth_txclk,
                                   eth_txclk_out);

    on tile[0]: test_tx(i_tx_lp[0], c_tx_hp);
    on tile[0]: test_rx(i_cfg[0], c_rx_hp, i_ctrl);

    #else // RGMII

    #if RT
    on tile[0]: mii_ethernet_rt(i_cfg, NUM_CFG_IF,
                                i_rx_lp, NUM_RX_LP_IF,
                                i_tx_lp, NUM_TX_LP_IF,
                                c_rx_hp, c_tx_hp,
                                p_eth_rxclk, p_eth_rxerr, p_eth_rxd, p_eth_rxdv,
                                p_eth_txclk, p_eth_txen, p_eth_txd,
                                eth_rxclk, eth_txclk,
                                2000, 2000, 2000, 2000, 1);
    on tile[0]: filler(0x1111);

    #if ETHERNET_SUPPORT_HP_QUEUES
    on tile[0]: test_tx(i_tx_lp[0], c_tx_hp);
    on tile[0]: test_rx(i_cfg[0], c_rx_hp, i_ctrl);
    #else
    on tile[0]: test_tx(i_tx_lp[0], null);
    on tile[0]: test_rx(i_cfg[0], i_rx_lp[0], i_ctrl);
    #endif

    #else
    on tile[0]: mii_ethernet(i_cfg, NUM_CFG_IF,
                             i_rx_lp, NUM_RX_LP_IF,
                             i_tx_lp, NUM_TX_LP_IF,
                             p_eth_rxclk, p_eth_rxerr, p_eth_rxd, p_eth_rxdv,
                             p_eth_txclk, p_eth_txen, p_eth_txd,
                             p_eth_dummy,
                             eth_rxclk, eth_txclk,
                             ETH_RX_BUFFER_SIZE_WORDS);
    on tile[0]: filler(0x1111);
    on tile[0]: filler(0x2222);
    on tile[0]: filler(0x3333);

    on tile[0]: test_tx(i_tx_lp[0], null);
    on tile[0]: test_rx(i_cfg[0], i_rx_lp[0], i_ctrl);

    #endif // RT
    #endif // RGMII

    on tile[0]: control(p_ctrl, i_ctrl);
  }
  return 0;
}