
//==============================================================================
//  文件名  : sd_card_sec_read_write.v
//  模块名  : sd_card_sec_read_write
//  功能    : 扇区读写状态机（CMD17 单块读 / CMD24 单块写）
//  时钟域  : sd_card_clk（100MHz）
//  说明    : 参考例程模块
//------------------------------------------------------------------------------
//  所属工程: 基于安路 EG4S20 的智能数字广告牌系统（赛题一 · 2026）
//==============================================================================

module sd_card_sec_read_write
#(
	parameter  SPI_LOW_SPEED_DIV = 248,         // spi clk speed = clk speed /((SPI_LOW_SPEED_DIV + 2) * 2 )
	parameter  SPI_HIGH_SPEED_DIV = 0           // spi clk speed = clk speed /((SPI_HIGH_SPEED_DIV + 2) * 2 )
)
(
	input            clk,
	input            rst,
	output reg       sd_init_done,
	input            sd_sec_read,
	input[31:0]      sd_sec_read_addr,
	output[7:0]      sd_sec_read_data,
	output           sd_sec_read_data_valid,
	output           sd_sec_read_end,
	input            sd_sec_write,
	input[31:0]      sd_sec_write_addr,
	input[7:0]       sd_sec_write_data,
	output           sd_sec_write_data_req,
	output           sd_sec_write_end,

	output reg[15:0] spi_clk_div,
	output reg       cmd_req,
	input            cmd_req_ack,
	input            cmd_req_error,
	output reg[47:0] cmd,
	output reg[7:0]  cmd_r1,
	output reg[15:0] cmd_data_len,
	output reg       block_read_req,
	input            block_read_valid,
	input[7:0]       block_read_data,
	input            block_read_req_ack,
	output reg       block_write_req,
	output[7:0]      block_write_data,
	input            block_write_data_rd,
	input            block_write_req_ack
);

localparam S_IDLE               = 0;
localparam S_CMD0               = 1;
localparam S_CMD8               = 2;
localparam S_CMD55              = 3;
localparam S_CMD41              = 4;
localparam S_CMD17              = 5;
localparam S_READ               = 6;
localparam S_CMD24              = 7;
localparam S_WRITE              = 8;
localparam S_ERR                = 14;
localparam S_WRITE_END          = 15;
localparam S_READ_END           = 16;
localparam S_WAIT_READ_WRITE    = 17;
localparam S_CMD16              = 18;

reg[4:0]                       state;
reg[31:0]                      sec_addr;

// ★ 状态停留超时 —— SD 通信故障自愈（2026-10-31 加）
//   现象：缩放等高频读卡场景下，某次 SD 命令无响应（卡进入通信中断的
//         中间态 / 电源波动 / 时序临界）→ 状态机停在命令状态无限重试 →
//         sd_init_done 恒 0（数码管位5=0）、画面卡旧图、必须断电重启。
//   处理：初始化完成后的"运行阶段"，任何工作状态停留超过 300ms，
//         强制回 S_IDLE 重新初始化，并重新走 100ms 上电等待。
//         卡恢复后系统自动重新扫描、重新显示，不需要人工重启。
//
//   ★★ 两个关键约束（第一版踩过坑）：
//   1. 只在 sd_init_done=1（初始化完成后）才启用超时！
//      初始化阶段卡可能几百毫秒才响应 CMD41（卡内部上电初始化），
//      超时若在初始化阶段生效，会把"慢卡"当故障反复掐掉 →
//      永远初始化不完 → 烧写后直接黑屏（位5=0）。
//   2. 阈值 300ms：运行中正常命令/读写单状态停留只有 µs~ms 级，
//      300ms 远大于正常值，不会误触发。
localparam [27:0] STALL_MAX = 28'd30_000_000;   // 300ms @100MHz
reg [4:0]                      state_d;
reg [27:0]                     stall_cnt;

always @(posedge clk or posedge rst) begin
	if (rst) begin
		state_d   <= S_IDLE;
		stall_cnt <= 28'd0;
	end else begin
		state_d <= state;
		if (state != state_d)
			stall_cnt <= 28'd0;              // 状态一变就重新计时
		else if (stall_cnt < STALL_MAX)
			stall_cnt <= stall_cnt + 28'd1;
	end
end

// ★ 上电等待计数器（2026-10-06 加）
//   SD 卡规范要求：上电稳定至少 1ms 之后才能收第一条命令，且要给它 74 个以上时钟。
//   原来复位一放开就立刻发 CMD0，遇到"卡还处在上次通信中断的中间态"时，
//   卡会一直不应答 → 初始化永远完不成 → 数码管位5 恒为 0、图片/音乐/字幕全没有。
//   这种状态靠按键复位救不回来（卡本身没有重新上电），必须断电才行。
//   这里先等约 100ms 再开始初始化，让卡有时间稳定下来。
localparam [27:0] PWR_WAIT_MAX = 28'd10_000_000;      // 100ms @100MHz
reg [27:0]                    pwr_wait;
assign sd_sec_read_data_valid = (state == S_READ) && block_read_valid;
assign sd_sec_read_data = block_read_data;
assign sd_sec_read_end = (state == S_READ_END);
assign sd_sec_write_data_req = (state == S_WRITE) && block_write_data_rd;
assign block_write_data = sd_sec_write_data;
assign sd_sec_write_end = (state == S_WRITE_END);

always@(posedge clk or posedge rst)
begin
	if(rst == 1'b1)
	begin
		state <= S_IDLE;
		cmd_req <= 1'b0;
		cmd_data_len <= 16'd0;
		cmd_r1 <= 8'd0;
		cmd <= 48'd0;
		spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
		block_write_req <= 1'b0;
		block_read_req <= 1'b0;
		sec_addr <= 32'd0;
		sd_init_done <= 1'b0;
		pwr_wait <= 28'd0;
	end
	else if ((stall_cnt >= STALL_MAX) &&
	         sd_init_done &&                        // ★ 只在初始化完成后的运行阶段启用！
	         (state != S_IDLE) &&
	         (state != S_WAIT_READ_WRITE))
	begin
		// ★ SD 通信故障自愈：运行中工作状态卡住超过 300ms → 强制重新初始化。
		//   清掉所有命令/读写请求，回到 S_IDLE 重新走 100ms 上电等待；
		//   卡一旦恢复，初始化成功，上层自动重新扫描并恢复显示。
		state           <= S_IDLE;
		cmd_req         <= 1'b0;
		block_read_req  <= 1'b0;
		block_write_req <= 1'b0;
		sd_init_done    <= 1'b0;
		pwr_wait        <= 28'd0;
	end
	else
		case(state)
			S_IDLE:
			begin
				sd_init_done <= 1'b0;
				spi_clk_div <= SPI_LOW_SPEED_DIV[15:0];
				// ★ 先等约 100ms 让 SD 卡上电稳定，再开始初始化
				if (pwr_wait < PWR_WAIT_MAX)
					pwr_wait <= pwr_wait + 28'd1;
				else
					state <= S_CMD0;
			end
			S_CMD0:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD8;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd0,8'h00,8'h00,8'h00,8'h00,8'h95};
				end
			end
			S_CMD8:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD55;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd4;
					cmd_r1 <= 8'h01;
					cmd <= {8'd8,8'h00,8'h00,8'h01,8'haa,8'h87};
				end
			end
			S_CMD55:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD41;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h01;
					cmd <= {8'd55,8'h00,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD41:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_CMD16;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd41,8'h40,8'h00,8'h00,8'h00,8'hff};
				end
			end
			S_CMD16:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WAIT_READ_WRITE;
					cmd_req <= 1'b0;
					sd_init_done <= 1'b1;
					spi_clk_div <= SPI_HIGH_SPEED_DIV[15:0];
				end
				else if(cmd_req_ack)
				begin
					state <= S_CMD55;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd16,32'd512,8'hff};
				end
			end			
			S_WAIT_READ_WRITE:
			begin
				if(sd_sec_write ==  1'b1)
				begin
					state <= S_CMD24;
					sec_addr <= sd_sec_write_addr;
				end
				else if(sd_sec_read == 1'b1)
				begin
					state <= S_CMD17;
					sec_addr <= sd_sec_read_addr;
				end

				spi_clk_div <= 16'd0;
			end
			S_CMD24:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_WRITE;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd24,sec_addr,8'hff};

				end
			end
			S_WRITE:
			begin
				if(block_write_req_ack == 1'b1)
				begin
					block_write_req <= 1'b0;
					state <= S_WRITE_END;
				end
				else
					block_write_req <= 1'b1;
			end
			S_CMD17:
			begin
				if(cmd_req_ack & ~cmd_req_error)
				begin
					state <= S_READ;
					cmd_req <= 1'b0;
				end
				else
				begin
					cmd_req <= 1'b1;
					cmd_data_len <= 16'd0;
					cmd_r1 <= 8'h00;
					cmd <= {8'd17,sec_addr,8'hff};
				end
			end
			S_READ:
			begin
				if(block_read_req_ack)
				begin
					state <= S_READ_END;
					block_read_req <= 1'b0;
				end
				else
				begin
					block_read_req <= 1'b1;
				end
			end
			S_WRITE_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			S_READ_END:
			begin
				state <= S_WAIT_READ_WRITE;
			end
			default:
				state <= S_IDLE;
		endcase
end
endmodule