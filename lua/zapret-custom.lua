-- В модуле: lua/zapret-custom.lua из TheFirstNoob/Zapret-2-GUI (MIT, (c) 2026
-- TheFirstNoob), коммит b8eaa9d от 14.11.2026, без изменений; ниже добавлена
-- tls_multisplit_sni из custom_funcs.lua Zapret GUI (MIT, (c) 2025–2026
-- censorliber, автор loop-uh; копия Zapret GUI 21.1.7.232 в NetZapret) —
-- для стратегии «Zapret GUI: YouTube без QUIC + wssize». Нужны стратегиям
-- fake_disorder, z2r_rocket и zapret_gui_yt
--
-- zapret-custom.lua
-- Кастомные desync-функции для нестандартных стратегий обхода.
-- Загружать: --lua-init=@lua/zapret-lib.lua --lua-init=@lua/zapret-antidpi.lua --lua-init=@lua/zapret-custom.lua
--
-- Содержит ТОЛЬКО то, что НЕЛЬЗЯ сделать встроенными функциями.
-- См. docs/ZAPRET2_CUSTOM_LUA.md для полного анализа.
--
-- Функции:
--   tls_fake_disorder  — фейки сначала + 3-сегментный disorder для TLS
--   fake_disorder      — универсальный fake+disorder для любого TCP

--[[
tls_fake_disorder — fake flood + multidisorder для TLS.
  fakes=N        — количество фейков (default 4)
  pos=<markers>  — позиции для multidisorder (default "host,endhost")
  nodrop
]]
function tls_fake_disorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data > 0 and desync.l7payload == "tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 4
			if not desync.arg.blob then
				error("tls_fake_disorder: 'blob' arg required")
			end
			local fake_payload = blob(desync, desync.arg.blob)
			if desync.reasm_data and desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, fake_payload, desync.arg.tls_mod, desync.reasm_data)
				if pl then fake_payload = pl end
			end

			local opts_fake = { rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg }
			local opts_orig = { rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = { tcp_ts_up = desync.arg.tcp_ts_up } }

			for i = 1, num_fakes do
				local dis = deepcopy(desync.dis)
				dis.payload = fake_payload
				if dis.ip then dis.ip.ip_ttl = 2 end
				if dis.ip6 then dis.ip6.ip6_hlim = 2 end
				rawsend_dissect(dis, opts_fake.rawsend)
			end

			local pos1 = resolve_pos(data, desync.l7payload, "host")
			local pos2 = resolve_pos(data, desync.l7payload, "endhost")
			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				local part1 = string.sub(data, 1, pos1 - 1)
				local part2 = string.sub(data, pos1, pos2 - 1)
				local part3 = string.sub(data, pos2)
				if not rawsend_payload_segmented(desync, part3, pos2 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part2, pos1 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			else
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			end

			replay_drop_set(desync)
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

--[[
fake_disorder — универсальный fake+disorder для любого TCP payload.
  fakes=N        — количество фейков (default 4)
  pos1=<marker>  — первая позиция (default "host")
  pos2=<marker>  — вторая позиция (default "endhost")
  nodrop
]]
function fake_disorder(ctx, desync)
	if not desync.dis.tcp then
		if not desync.dis.icmp then instance_cutoff_shim(ctx, desync) end
		return
	end
	direction_cutoff_opposite(ctx, desync)
	local data = desync.reasm_data or desync.dis.payload
	if #data > 0 and direction_check(desync) and payload_check(desync) then
		if replay_first(desync) then
			local num_fakes = tonumber(desync.arg.fakes) or 4
			if not desync.arg.blob then
				error("fake_disorder: 'blob' arg required")
			end
			local fake_payload = blob(desync, desync.arg.blob)
			if desync.reasm_data and desync.arg.tls_mod then
				local pl = tls_mod_shim(desync, fake_payload, desync.arg.tls_mod, desync.reasm_data)
				if pl then fake_payload = pl end
			end

			local opts_fake = { rawsend = rawsend_opts(desync), reconstruct = reconstruct_opts(desync), ipfrag = {}, ipid = desync.arg, fooling = desync.arg }
			local opts_orig = { rawsend = rawsend_opts_base(desync), reconstruct = {}, ipfrag = {}, ipid = desync.arg, fooling = { tcp_ts_up = desync.arg.tcp_ts_up } }

			for i = 1, num_fakes do
				local dis = deepcopy(desync.dis)
				dis.payload = fake_payload
				rawsend_dissect(dis, opts_fake.rawsend)
			end

			local spos1 = desync.arg.pos1 or "host"
			local spos2 = desync.arg.pos2 or "endhost"
			local pos1 = resolve_pos(data, desync.l7payload, spos1)
			local pos2 = resolve_pos(data, desync.l7payload, spos2)
			if pos1 and pos2 and pos1 > 1 and pos2 > pos1 and pos2 <= #data then
				local part1 = string.sub(data, 1, pos1 - 1)
				local part2 = string.sub(data, pos1, pos2 - 1)
				local part3 = string.sub(data, pos2)
				if not rawsend_payload_segmented(desync, part3, pos2 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part2, pos1 - 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			else
				local part1 = string.sub(data, 1, 1)
				local part2 = string.sub(data, 2)
				if not rawsend_payload_segmented(desync, part2, 1, opts_orig) then return VERDICT_PASS end
				if not rawsend_payload_segmented(desync, part1, 0, opts_orig) then return VERDICT_PASS end
			end

			replay_drop_set(desync)
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
		if replay_drop(desync) then
			return desync.arg.nodrop and VERDICT_PASS or VERDICT_DROP
		end
	end
end

DLOG("zapret-custom.lua loaded: tls_fake_disorder, fake_disorder")

-- tls_multisplit_sni — из custom_funcs.lua Zapret GUI без изменений: ClientHello
-- режется по 17 точкам вокруг имени сайта и уходит частями в обратном порядке;
-- seqovl — у второй части, если помещается перед ней (иначе отменяется)
function tls_multisplit_sni(ctx, desync)
	if not desync.dis.tcp then
		instance_cutoff(ctx)
		return
	end
	direction_cutoff_opposite(ctx, desync)
	
	local data = desync.reasm_data or desync.dis.payload
	if #data>0 and desync.l7payload=="tls_client_hello" and direction_check(desync) then
		if replay_first(desync) then
			-- Get extensive split positions around SNI
			local spos = "1,host-2,host,host+1,host+2,midsld-1,midsld,midsld+1,sld,sld+1,sld+2,endhost-2,endhost-1,endhost,sniext,sniext+1,sniext+2"
			
			if b_debug then DLOG("tls_multisplit_sni: split pos: "..spos) end
			local pos = resolve_multi_pos(data, desync.l7payload, spos)
			if b_debug then DLOG("tls_multisplit_sni: resolved split pos: "..table.concat(zero_based_pos(pos)," ")) end
			delete_pos_1(pos)
			
			if #pos>0 then
				local seqovl = tonumber(desync.arg.seqovl) or 211
				local seqovl_pat = desync.arg.seqovl_pattern and blob(desync, desync.arg.seqovl_pattern) or blob(desync, "fake_default_tls")
				
				-- Send in disorder order (last to first)
				for i=#pos,0,-1 do
					local pos_start = pos[i] or 1
					local pos_end = i<#pos and pos[i+1]-1 or #data
					local part = string.sub(data,pos_start,pos_end)
					local part_seqovl = 0
					
					-- Apply seqovl to second part (in original order)
					if i==1 and seqovl > 0 then
						part_seqovl = seqovl
						if part_seqovl >= (pos[1]-1) then
							DLOG("tls_multisplit_sni: seqovl cancelled, too large")
							part_seqovl = 0
						else
							part = pattern(seqovl_pat, 1, part_seqovl) .. part
						end
					end
					
					if b_debug then DLOG("tls_multisplit_sni: sending part "..(i+1).." "..(pos_start-1).."-"..(pos_end-1).." len="..#part.." seqovl="..part_seqovl) end
					if not rawsend_payload_segmented(desync, part, pos_start-1-part_seqovl) then
						return VERDICT_PASS
					end
				end
				replay_drop_set(desync)
				return VERDICT_DROP
			else
				DLOG("tls_multisplit_sni: no valid split positions")
			end
		else
			DLOG("tls_multisplit_sni: not acting on further replay pieces")
		end
		
		if replay_drop(desync) then
			return VERDICT_DROP
		end
	end
end
