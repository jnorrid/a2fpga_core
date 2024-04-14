//
// Top module for Tang Nano 20K and A2N20v1 Apple II card
//
// (c) 2023,2024 Ed Anuff <ed@a2fpga.com> 
//
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
//
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
// ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
// OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
//

// Using the Gowin IDE
`define GW_IDE

module top #(
    parameter int CLOCK_SPEED_HZ = 54_000_000,
    parameter int MEM_MHZ = CLOCK_SPEED_HZ / 1_000_000,

    parameter bit SCANLINES_ENABLE = 1,
    parameter bit APPLE_SPEAKER_ENABLE = 1,

    parameter bit SUPERSPRITE_ENABLE = 1,
    parameter SUPERSPRITE_SLOT = 7,
    parameter bit SUPERSPRITE_FORCE_VDP_OVERLAY = 0,

    parameter bit MOCKINGBOARD_ENABLE = 1,
    parameter MOCKINGBOARD_SLOT = 4,

    parameter bit SUPERSERIAL_ENABLE = 0,
    parameter SUPERSERIAL_SLOT = 2,

    parameter bit CLEAR_APPLE_VIDEO_RAM = 1,    // Clear video ram on startup
    parameter bit HDMI_SLEEP_ENABLE = 1,        // Sleep HDMI output on CPU stop
    parameter bit IRQ_OUT_ENABLE = 1,           // Allow driving IRQ to Apple bus
    parameter bit BUS_DATA_OUT_ENABLE = 1       // Allow driving data to Apple bus

) (
    // fpga clocks
    input clk,

    // fpga buttons
    input s1,
    input s2,

    // A2 signals
    input a2_reset_n,
    input a2_phi1,
    input a2_7M,

    // A2Bridge signals
    output [1:0] a2_bridge_sel,
    output a2_bridge_bus_a_oe,
    output a2_bridge_bus_d_oe,
    output a2_bridge_rd,
    output a2_bridge_wr,
    inout [7:0] a2_bridge_d,

    // hdmi ports
    output tmds_clk_p,
    output tmds_clk_n,
    output [2:0] tmds_d_p,
    output [2:0] tmds_d_n,

    // leds
    output reg [4:0] led,

    // uart
    output  uart_tx,
    input  uart_rx


);

    wire rst_n = ~s1;

    // Clocks

    wire clk_logic_w;
    wire clk_logic_p_w;
    wire clk_logic_lock_w;
    wire clk_pixel_w;
    wire clk_hdmi_w;
    wire clk_hdmi_lock_w;
    wire hdmi_rst_n_w;
    wire a2_2M;

    // PLL - 100Mhz from 27
    clk_logic clk_logic_inst (
        .clkout(clk_logic_w),  //output clkout
        .lock(clk_logic_lock_w),  //output lock
        .clkoutp(clk_logic_p_w),  //output clkoutp
        .clkoutd(clk_pixel_w),  //output clkoutd
        .reset(~rst_n),  //input reset
        .clkin(clk)  //input clkin
    );

    // PLL - 125Mhz from 25
    clk_hdmi clk_hdmi_inst (
        .clkout(clk_hdmi_w),  //output clkout
        .lock(clk_hdmi_lock_w),  //output lock
        .reset(~clk_logic_lock_w),  //input reset
        .clkin(clk_pixel_w)  //input clkin
    );

    // Reset

    wire device_reset_n_w = rst_n & clk_logic_lock_w & clk_hdmi_lock_w;

    wire system_reset_n_w = device_reset_n_w & a2_reset_n;

    // Translate Phi1 into the clk_logic clock domain and derive Phi0 and edges
    // delays Phi1 by 2 cycles = 40ns
    wire phi1;
    wire phi0;
    wire phi1_posedge;
    wire phi1_negedge;
    wire clk_2m_posedge_w = phi1_posedge | phi1_negedge;
    cdc cdc_phi1 (
        .clk(clk_logic_w),
        .i(a2_phi1),
        .o(phi1),
        .o_n(phi0),
        .o_posedge(phi1_posedge),
        .o_negedge(phi1_negedge)
    );

    wire clk_7m_w;
    wire clk_7m_posedge_w;
    wire clk_7m_negedge_w;
    wire clk_14m_posedge_w = clk_7m_posedge_w | clk_7m_negedge_w;
    cdc cdc_7m (
        .clk(clk_logic_w),
        .i(a2_7M),
        .o(clk_7m_w),
        .o_n(),
        .o_posedge(clk_7m_posedge_w),
        .o_negedge(clk_7m_negedge_w)
    );

    // Interface to Apple II

    // data and address latches on input

    a2bus_if a2bus_if (
        .clk_logic(clk_logic_w),
        .clk_pixel(clk_pixel_w),
        .system_reset_n(system_reset_n_w),
        .device_reset_n(device_reset_n_w),
        .phi0(phi0),
        .phi1(phi1),
        .phi1_posedge(phi1_posedge),
        .phi1_negedge(phi1_negedge),
        .clk_2m_posedge(clk_2m_posedge_w),
        .clk_7m(clk_7m_w),
        .clk_7m_posedge(clk_7m_posedge_w),
        .clk_7m_negedge(clk_7m_negedge_w),
        .clk_14m_posedge(clk_14m_posedge_w)
    );

    wire sleep_w;
    wire data_in_strobe_w;

    wire irq_n_w;

    wire data_out_en_w;
    wire [7:0] data_out_w;

    wire [7:0] a2_bridge_d_buf_w;
    wire [7:0] a2_bridge_d_o_w;
    wire a2_bridge_d_oe_w;

    wire [3:0] dip_switches_n_w;
    wire sw_scanlines_w = !dip_switches_n_w[0];
    wire sw_apple_speaker_w = !dip_switches_n_w[1];
    wire sw_slot_7_w = !dip_switches_n_w[2];
    wire sw_gs_w = !dip_switches_n_w[3];

    IOBUF a2_bridge_d_iobuf[7:0] (
        .O  (a2_bridge_d_buf_w),
        .IO (a2_bridge_d),
        .I  (a2_bridge_d_o_w),
        .OEN(!a2_bridge_d_oe_w)
    );

    apple_bus #(
        .CLOCK_SPEED_HZ(CLOCK_SPEED_HZ)
    ) apple_bus (
        .a2bus_if(a2bus_if),

        .a2_bridge_sel_o(a2_bridge_sel),
        .a2_bridge_bus_a_oe_o(a2_bridge_bus_a_oe),
        .a2_bridge_bus_d_oe_o(a2_bridge_bus_d_oe),
        .a2_bridge_rd_o(a2_bridge_rd),
        .a2_bridge_wr_o(a2_bridge_wr),
        .a2_bridge_d_i(a2_bridge_d_buf_w),
        .a2_bridge_d_o(a2_bridge_d_o_w),
        .a2_bridge_d_oe_o(a2_bridge_d_oe_w),

        .data_out_en_i(data_out_en_w),
        .data_out_i(data_out_w),

        .irq_n_i(irq_n_w),

        .dip_switches_n_o(dip_switches_n_w),

        .sleep_o(sleep_w)
    );

    // Memory

    a2mem_if a2mem_if();

    wire [15:0] video_address_w;
    wire video_bank_w;
    wire video_rd_w;
    wire [31:0] video_data_w;

    wire vgc_active_w;
    wire [12:0] vgc_address_w;
    wire vgc_rd_w;
    wire [31:0] vgc_data_w;

    apple_memory #(
        .VGC_MEMORY(1)
    ) apple_memory (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_address_i(video_address_w),
        .video_rd_i(video_rd_w),
        .video_data_o(video_data_w),

        .vgc_active_i(vgc_active_w),
        .vgc_address_i(vgc_address_w),
        .vgc_rd_i(vgc_rd_w),
        .vgc_data_o(vgc_data_w)
    );

    // Video

    video_control_if video_control_if();
    assign video_control_if.enable = 1'b0;
    assign video_control_if.TEXT_MODE = 1'b0;
    assign video_control_if.MIXED_MODE = 1'b0;
    assign video_control_if.PAGE2 = 1'b0;
    assign video_control_if.HIRES_MODE = 1'b0;
    assign video_control_if.AN3 = 1'b0;
    assign video_control_if.STORE80 = 1'b0;
    assign video_control_if.COL80 = 1'b0;
    assign video_control_if.ALTCHAR = 1'b0;
    assign video_control_if.TEXT_COLOR = 4'b0;
    assign video_control_if.BACKGROUND_COLOR = 4'b0;
    assign video_control_if.BORDER_COLOR = 4'b0;
    assign video_control_if.MONOCHROME_MODE = 1'b0;
    assign video_control_if.MONOCHROME_DHIRES_MODE = 1'b0;
    assign video_control_if.SHRG_MODE = 1'b0;

    wire [9:0] hdmi_x;
    wire [9:0] hdmi_y;
    wire apple_vga_active;
    wire [7:0] apple_vga_r;
    wire [7:0] apple_vga_g;
    wire [7:0] apple_vga_b;

    apple_video apple_video (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_control_if(video_control_if),

        .screen_x_i(hdmi_x),
        .screen_y_i(hdmi_y),

        .video_address_o(video_address_w),
        .video_bank_o(video_bank_w),
        .video_rd_o(video_rd_w),
        .video_data_i(video_data_w),

        .video_active_o(apple_vga_active),
        .video_r_o(apple_vga_r),
        .video_g_o(apple_vga_g),
        .video_b_o(apple_vga_b)
    );

    wire [7:0] vgc_vga_r;
    wire [7:0] vgc_vga_g;
    wire [7:0] vgc_vga_b;

    vgc vgc (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .video_control_if(video_control_if),

        .cx_i(hdmi_x),
        .cy_i(hdmi_y),

        .apple_vga_r_i(apple_vga_r),
        .apple_vga_g_i(apple_vga_g),
        .apple_vga_b_i(apple_vga_b),

        .vgc_vga_r_o(vgc_vga_r),
        .vgc_vga_g_o(vgc_vga_g),
        .vgc_vga_b_o(vgc_vga_b),

        .R_o(),
        .G_o(),
        .B_o(),

        .vgc_active_o(vgc_active_w),
        .vgc_address_o(vgc_address_w),
        .vgc_rd_o(vgc_rd_w),
        .vgc_data_i(vgc_data_w)
    );

    // SuperSprite

    wire VDP_OVERLAY_SW;
    wire APPLE_VIDEO_SW;
    wire [0:7] ssp_d_w;
    wire ssp_rd;
    wire [3:0] vdp_r;
    wire [3:0] vdp_g;
    wire [3:0] vdp_b;
    wire vdp_transparent;
    wire vdp_ext_video;
    wire vdp_irq_n;
    wire [15:0] ssp_audio_w;
    wire vdp_unlocked_w;
    wire [3:0] vdp_gmode_w;
    wire scanlines_w;

    wire [7:0] rgb_r_w;
    wire [7:0] rgb_g_w;
    wire [7:0] rgb_b_w;

    f18a_gpu_if f18a_gpu_if();
    assign f18a_gpu_if.running = 1'b0;
    assign f18a_gpu_if.pause_ack = 1'b1;
    assign f18a_gpu_if.vwe = 1'b0;
    assign f18a_gpu_if.vaddr = 14'b0;
    assign f18a_gpu_if.vdout = 8'b0;
    assign f18a_gpu_if.pwe = 1'b0;
    assign f18a_gpu_if.paddr = 6'b0;
    assign f18a_gpu_if.pdout = 12'b0;
    assign f18a_gpu_if.rwe = 1'b0;
    assign f18a_gpu_if.raddr = 13'b0;
    assign f18a_gpu_if.gstatus = 7'b0;

    SuperSprite #(
        .ENABLE(SUPERSPRITE_ENABLE),
        .SLOT(SUPERSPRITE_SLOT),
        .FORCE_VDP_OVERLAY(SUPERSPRITE_FORCE_VDP_OVERLAY)
    ) supersprite (
        .a2bus_if(a2bus_if),

        .data_o(ssp_d_w),
        .rd_en_o(ssp_rd),
        .irq_n_o(vdp_irq_n),

        .screen_x_i(hdmi_x),
        .screen_y_i(hdmi_y),
        .apple_vga_r_i(vgc_vga_r),
        .apple_vga_g_i(vgc_vga_g),
        .apple_vga_b_i(vgc_vga_b),
        .apple_vga_active_i(apple_vga_active),

        .scanlines_i(SCANLINES_ENABLE | sw_scanlines_w),

        .ssp_r_o(rgb_r_w),
        .ssp_g_o(rgb_g_w),
        .ssp_b_o(rgb_b_w),

        .scanlines_o(scanlines_w),

        .vdp_ext_video_o(vdp_ext_video),
        .vdp_unlocked_o(vdp_unlocked_w),
        .vdp_gmode_o(vdp_gmode_w),

        .f18a_gpu_if(f18a_gpu_if),

        .ssp_audio_o(ssp_audio_w)
    );

    // Mockingboard

    wire [7:0] mb_d_w;
    wire mb_rd;
    wire mb_irq_n;
    wire [9:0] mb_audio_l;
    wire [9:0] mb_audio_r;

    Mockingboard #(
        .ENABLE(MOCKINGBOARD_ENABLE),
        .SLOT(MOCKINGBOARD_SLOT)
    ) mockingboard (
        .a2bus_if(a2bus_if),  // use system_reset_n

        .data_o(mb_d_w),
        .rd_en_o(mb_rd),
        .irq_n_o(mb_irq_n),

        .audio_l_o(mb_audio_l),
        .audio_r_o(mb_audio_r)
    );

    // SuperSerial Card

    wire [7:0] ssc_d_w;
    wire ssc_rd;
    wire ssc_irq_n;
    wire ssc_rom_en;

    wire ssc_uart_rx;
    wire ssc_uart_tx;
    assign ssc_uart_rx = uart_rx;
    assign uart_tx = ssc_uart_tx;

    SuperSerial #(
        .ENABLE(SUPERSERIAL_ENABLE),
        .SLOT(SUPERSERIAL_SLOT)
    ) superserial (
        .a2bus_if(a2bus_if),
        .a2mem_if(a2mem_if),

        .data_o(ssc_d_w),
        .rd_en_o(ssc_rd),
        .irq_n_o(ssc_irq_n),

        .rom_en_o(ssc_rom_en),
        .uart_rx_i(ssc_uart_rx),
        .uart_tx_o(ssc_uart_tx)
    );

    // Data output

    assign data_out_en_w = ssp_rd || mb_rd || ssc_rd;

    assign data_out_w = ssc_rd ? ssc_d_w :
        ssp_rd ? ssp_d_w : 
        mb_rd ? mb_d_w : 
        a2bus_if.data;

    // Interrupts

    assign irq_n_w = (mb_irq_n && vdp_irq_n && ssc_irq_n) || !IRQ_OUT_ENABLE;

    // HDMI

    localparam AUDIO_RATE = 44100;
    localparam AUDIO_BIT_WIDTH = 16;
    localparam AUDIO_CLK_COUNT = (CLOCK_SPEED_HZ / 2) / AUDIO_RATE;
    logic [$clog2(AUDIO_CLK_COUNT)-1:0] audio_counter_r;
    logic clk_audio_r;

    always_ff @(posedge clk_pixel_w)
    begin
        audio_counter_r <= (audio_counter_r == AUDIO_CLK_COUNT) ? 1'd0 : audio_counter_r + 1'd1;
        clk_audio_r <= audio_counter_r == AUDIO_CLK_COUNT;
    end

    reg speaker_bit;
    always @(posedge clk_logic_w or negedge system_reset_n_w) begin
        if (!system_reset_n_w) begin
            speaker_bit <= 1'b0;
        end else if (phi1_posedge && (a2bus_if.addr[15:0] == 16'hC030) && !a2bus_if.m2sel_n) 
            speaker_bit <= !speaker_bit;
    end

    // Apple intermal audio toggles a +5V signal to a speaker.  We cannot simply leave a square wave
    // indefinitaley on the HDMI audio line, so we need to generate a pulse of a maximum length.
    // If we don't do this, the HDMI audio line will essentially have an amplitude offset, which
    // will cause the HDMI receiver to clip the audio or amplify anything such as the Mockingboard
    // audio that is added to it.

    reg speaker_audio;
    reg [7:0] speaker_audio_counter;
    reg prev_speaker_bit;

    always_ff @(posedge clk_pixel_w) begin
        if (clk_audio_r) begin
            if (speaker_bit != prev_speaker_bit) begin
                speaker_audio_counter <= 8'b11111111;
            end else if (speaker_audio_counter != 0) begin
                speaker_audio_counter <= speaker_audio_counter - 8'd1;
            end
            prev_speaker_bit <= speaker_bit;

            if (prev_speaker_bit && (speaker_audio_counter != 0)) begin
                speaker_audio <= APPLE_SPEAKER_ENABLE | sw_apple_speaker_w;
            end else begin
                speaker_audio <= 1'b0;
            end
        end
    end

    ////
    logic [2:0] tmds;
    wire tmdsClk;

    //wire [15:0] sample = {ssp_psg_mix_audio_o, 2'b00};
    reg [15:0] audio_sample_word[1:0], audio_sample_word0[1:0];
    always @(posedge clk_pixel_w) begin  // crossing clock domain
        audio_sample_word0[0] <= ssp_audio_w + {mb_audio_l, 4'b00} + {speaker_audio, 13'b0};
        audio_sample_word[0]  <= audio_sample_word0[0];
        audio_sample_word0[1] <= ssp_audio_w + {mb_audio_r, 4'b00} + {speaker_audio, 13'b0};
        audio_sample_word[1]  <= audio_sample_word0[1];
    end

    wire scanline_en = scanlines_w && hdmi_y[0];

    hdmi #(
        .VIDEO_ID_CODE(2),
        .DVI_OUTPUT(0),
        .VIDEO_REFRESH_RATE(59.94),
        .IT_CONTENT(1),
        .AUDIO_RATE(AUDIO_RATE),
        .AUDIO_BIT_WIDTH(AUDIO_BIT_WIDTH),
        .VENDOR_NAME({"Unknown", 8'd0}),  // Must be 8 bytes null-padded 7-bit ASCII
        .PRODUCT_DESCRIPTION({"FPGA", 96'd0}),  // Must be 16 bytes null-padded 7-bit ASCII
        .SOURCE_DEVICE_INFORMATION(8'h00), // See README.md or CTA-861-G for the list of valid codes
        .START_X(0),
        .START_Y(0)
    ) hdmi (
        .clk_pixel_x5(clk_hdmi_w),
        .clk_pixel(clk_pixel_w),
        .clk_audio(clk_audio_r),
        .rgb({
            scanline_en ? {1'b0, rgb_r_w[7:1]} : rgb_r_w,
            scanline_en ? {1'b0, rgb_g_w[7:1]} : rgb_g_w,
            scanline_en ? {1'b0, rgb_b_w[7:1]} : rgb_b_w
        }),
        .reset(~device_reset_n_w),
        .audio_sample_word(audio_sample_word),
        .tmds(tmds),
        .tmds_clock(tmdsClk),
        .cx(hdmi_x),
        .cy(hdmi_y),
        .frame_width(),
        .frame_height(),
        .screen_width(),
        .screen_height()
    );

    // Gowin LVDS output buffer
    ELVDS_TBUF tmds_bufds[3:0] (
        .I({clk_pixel_w, tmds}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n}),
        .OEN(sleep_w && HDMI_SLEEP_ENABLE)
    );

    always @(posedge clk_logic_w) begin 
        if (!s2) led <= {!a2mem_if.TEXT_MODE, !a2mem_if.MIXED_MODE, !a2mem_if.HIRES_MODE, !a2mem_if.AN3, !a2mem_if.STORE80};
        else led <= {!vdp_unlocked_w, ~vdp_gmode_w};
        //else led <= {!vdp_unlocked_w, dip_switches_n_w};
    end


endmodule
