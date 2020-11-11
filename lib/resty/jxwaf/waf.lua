require "resty.core"
local cjson = require "cjson.safe"
local request = require "resty.jxwaf.request"
local transform = require "resty.jxwaf.transform"
local operator = require "resty.jxwaf.operator"
local resty_random = require "resty.random"
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local table_sort = table.sort
local table_concat = table.concat
local http = require "resty.jxwaf.http"
local upload = require "resty.upload"
local limitreq = require "resty.jxwaf.limitreq"
local iputils = require "resty.jxwaf.iputils"
local exit_code = require "resty.jxwaf.exit_code"
local uuid = require "resty.jxwaf.uuid"
local ngx_md5 = ngx.md5
local string_find = string.find
local string_sub = string.sub
local loadstring = loadstring
local tonumber = tonumber
local type = type
local string_lower = string.lower
local process = require "ngx.process"
local ngx_decode_base64 = ngx.decode_base64
local aes = require "resty.aes"
local _M = {}
_M.version = "20200918"


local _config_path = "/opt/jxwaf/nginx/conf/jxwaf/jxwaf_config.json"
local _local_config_path = "/opt/jxwaf/nginx/conf/jxwaf/jxwaf_local_config.json"
local _config_geo_path = "/opt/jxwaf/nginx/conf/jxwaf/GeoLite2-Country.mmdb"
local _update_waf_rule = {}
local _config_info = {}
local _jxcheck = nil
local _bot_check = nil
local _keycheck = nil
local _md5 = ""
local bot_check_standard_info = {}
local bot_check_image_info = {}
local bot_check_slipper_info = {}
local bot_check_standard_key = {}
local bot_check_image_key = {}
local bot_check_slipper_key = {}
local _log_conf = {}
local _auto_update = "true"
local _auto_update_period = "60"
local _waf_node_monitor = "true"
local _waf_node_monitor_period = "60"

local function _process_rule()
  for k,v in pairs(_update_waf_rule) do
    if v['domain_set'] and (v['domain_set']['enc_https'] == "true") then
      local decrypt_private_key = _decrypt_https_key(v['domain_set']['private_key'])
      _update_waf_rule[k]['domain_set']['private_key'] = decrypt_private_key
    end
  end
end

local function _sort_rules(a,b)
    if a.rule_level == b.rule_level then
      return tonumber(a.rule_id)<tonumber(b.rule_id)
    else
      return tonumber(a.rule_level)>tonumber(b.rule_level)
    end
end

function _M.get_log_config()
  return _log_conf
end

function _M.get_config_info()
	return _config_info
end

function _M.get_update_waf_rule()
	return _update_waf_rule
end


local function _owasp_black_ip_stat(req_host,check_mode)
  if req_host['protection_set']['evil_ip_handle'] == "true" then
    if req_host['evil_ip_handle_set']['block_option'][check_mode] then
      local period = req_host['evil_ip_handle_set']['period']
      local count = req_host['evil_ip_handle_set']['count']
      local mode = req_host['evil_ip_handle_set']['mode']
      local handle = req_host['evil_ip_handle_set']['handle']
      local attack_ip_check = ngx.shared.black_owasp_attack_ip
      local ip_addr = request.request['REMOTE_ADDR']()
      local check_black_ip = {}
      check_black_ip[1] = "owasp_black_ip"
      check_black_ip[2] =  ip_addr
      local key_check_black_ip = table_concat(check_black_ip)
      local check_black_ip_count = attack_ip_check:incr(key_check_black_ip, 1, 0, tonumber(period)) 
      if check_black_ip_count and check_black_ip_count > tonumber(count) then
        local black_ip_info = {}
        black_ip_info['protection_info'] = mode
        black_ip_info['protecion_handle'] = handle
        if (mode == 'block' ) and tonumber(handle) > 0 then
          attack_ip_check:set(ip_addr,cjson.encode(black_ip_info),tonumber(handle))
        end
        if (mode == 'block' ) and tonumber(handle) == 0 then
          attack_ip_check:set(ip_addr,cjson.encode(black_ip_info))
        end
        if mode == 'observe'  then
          attack_ip_check:set(ip_addr,cjson.encode(black_ip_info))
        end
        local waf_log = {}
        waf_log['log_type'] = "owasp_attack"
        waf_log['protection_type'] = "black_ip-"..check_mode
        waf_log['protection_info'] = "add_black_ip"
        ngx.ctx.waf_log = waf_log
      end
    end
  end
end


local function _cc_black_ip_stat(req_host,check_mode)
  if req_host['protection_set']['cc_attack_ip_protection'] == "true" then
    if req_host['cc_attack_ip_set']['block_option'][check_mode] then
      local check_period = req_host['cc_attack_ip_set']['check_period']
      local check_count = req_host['cc_attack_ip_set']['check_count']
      local block_time = req_host['cc_attack_ip_set']['block_time']
      local block_mode = req_host['cc_attack_ip_set']['block_mode']
      local attack_ip_check = ngx.shared.black_cc_attack_ip
      local ip_addr = request.request['REMOTE_ADDR']()
      local check_black_ip = {}
      check_black_ip[1] = "cc_black_ip"
      check_black_ip[2] =  ip_addr
      local key_check_black_ip = table_concat(check_black_ip)
      local check_black_ip_count = attack_ip_check:incr(key_check_black_ip, 1, 0, tonumber(check_period)) 
      if check_black_ip_count and check_black_ip_count > tonumber(check_count) then
        local black_ip_info = {}
        black_ip_info['protection_info'] = block_mode
        black_ip_info['protecion_handle'] = block_time
        if (block_mode == 'block' or block_mode == 'network_layer_block') and tonumber(block_time) > 0 then
          attack_ip_check:set(ip_addr,cjson.encode(black_ip_info),tonumber(handle))
        end
        if (block_mode == 'block' or block_mode == 'network_layer_block') and tonumber(block_time) == 0 then
          attack_ip_check:set(ip_addr,cjson.encode(black_ip_info))
        end
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "black_ip-"..check_mode
        waf_log['protection_info'] = "add_black_ip"
        ngx.ctx.waf_log = waf_log
      end
    end
  end
end





local function _process_request(var)
	local t = request.request[var.rule_var]()
	if type(t) ~= "string" and type(t) ~= "table" then
    local waf_log = {}
    waf_log['log_type'] = "error"
    waf_log['protection_type'] = "process_request"
    waf_log['protection_info'] = "run fail,can not decode http args ",type(t).."   "..var.rule_var
    ngx.ctx.waf_log = waf_log
		ngx.log(ngx.ERR,"run fail,can not decode http args ",type(t).."   "..var.rule_var)
		ngx.log(ngx.ERR,ngx.req.raw_header())
		exit_code.return_error()
	end
	if type(t) == "string" then
		return t
	end
	
	local rule_var = var.rule_var
	if (rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "ARGS_HEADERS" or rule_var == "ARGS_COOKIES" ) then
		if( type(var.rule_specific) == "table" ) then
			local specific_result = {}
			for _,v in ipairs(var.rule_specific) do
				local specific = t[v]
				if specific ~= nil then
					specific_result[v] = specific
				end
			end
			return specific_result
		end
    
		if( type(var.rule_ignore) == "table" ) then
			local ignore_result = {}
      for k,v in pairs(t) do
				ignore_result[k] = v 
			end
			for _,v in ipairs(var.rule_ignore) do
				ignore_result[string_lower(v)] = nil
			end
			return ignore_result
		end				
	end
	
	return t
end



function _M.process_request(var)
	return _process_request(var)
end



local function _process_transform(process_request,rule_transform,var)
  if type(process_request) ~= "string" and type(process_request) ~= "table" then
    local waf_log = {}
    waf_log['log_type'] = "error"
    waf_log['protection_type'] = "process_transform"
    waf_log['protection_info'] = "run fail,can not transfrom http args"
    ngx.ctx.waf_log = waf_log
    ngx.log(ngx.ERR,"run fail,can not transfrom http args")
    exit_code.return_error()
  end

	if  type(rule_transform) ~= "table" then
    local waf_log = {}
    waf_log['log_type'] = "error"
    waf_log['protection_type'] = "process_transform"
    waf_log['protection_info'] = "run fail,can not decode config file,transfrom error"
    ngx.ctx.waf_log = waf_log
    ngx.log(ngx.ERR,"run fail,can not decode config file,transfrom error")
    exit_code.return_error()
  end

	if type(process_request) == "string" then
		local string_result = process_request
		for _,v in ipairs(rule_transform) do
			string_result = transform.request[v](string_result)				
		end
		return 	string_result
	end

	local result = {}
	local rule_var = var.rule_var
	if (rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "ARGS_HEADERS" or rule_var == "ARGS_COOKIES" ) then
		for k,v in pairs(process_request) do
      if type(v) == "table" then
      local _result_table = {}
      for _,_v in ipairs(v) do
        local _result = _v
        for _,__v in ipairs(rule_transform) do
          _result = transform.request[__v](_result)
        end 
        if type(_result) == "string" then
          table_insert(_result_table,_result)
        end
      end
      result[k] = _result_table
      else
        local _result = v
        for _,_v in ipairs(rule_transform) do
          _result = transform.request[_v](_result)
        end
        if type(_result) == "string" then
          result[k] = _result
        end
      end
    end
	else
		for _,v in ipairs(process_request) do
			local _result = v
			for _,_v in ipairs(rule_transform) do
				_result = transform.request[_v](_result)
			end
			if type(_result) == "string" then
				table_insert(result,_result)
			end
		end
	end
	return result 
end


local function _process_operator( process_transform , match , var , rule )
	local rule_operator = match.rule_operator
	local rule_pattern = match.rule_pattern
	local rule_var = var.rule_var
	if type(process_transform) ~= "string" and type(process_transform) ~= "table" then
    local waf_log = {}
    waf_log['log_type'] = "error"
    waf_log['protection_type'] = "process_operator"
    waf_log['protection_info'] = "run fail,can not operator http args"
    ngx.ctx.waf_log = waf_log
		ngx.log(ngx.ERR,"run fail,can not operator http args")
    exit_code.return_error()
  end
	if type(rule_operator) ~= "string" and type(rule_pattern) ~= "string" then
    local waf_log = {}
    waf_log['log_type'] = "error"
    waf_log['protection_type'] = "process_operator"
    waf_log['protection_info'] = "rule_operator and rule_pattern error"
    ngx.ctx.waf_log = waf_log
		ngx.log(ngx.ERR,"rule_operator and rule_pattern error")
		exit_code.return_error()
	end
	
	if type(process_transform) == "string" then
		local result ,value
		result,value = operator.request[rule_operator](process_transform,rule_pattern)
		if result  then
			return result,value,rule_var
		else
			return result
		end
	end

	if (rule_var == "ARGS_GET" or rule_var == "ARGS_POST" or rule_var == "ARGS_HEADERS" or rule_var == "ARGS_COOKIES" ) then
		for k,v in pairs(process_transform) do
			if type(v) == "table" then
        --[[
        if #v > 10 then
          local rule_log = request.request['HTTP_FULL_INFO']()
          rule_log['log_type'] = "protection_log"
          rule_log['protection_type'] = "error_request"
          rule_log['protection_info'] = "error_request"
          ngx.ctx.rule_log = rule_log
          exit_code.return_exit()
        end
        --]]
				for _,_v in ipairs(v) do
					local result,value
					result,value = operator.request[rule_operator](_v,rule_pattern)	
					if result  then
						return result,value,k
					end
				end
			else
				local result,value
				result,value = operator.request[rule_operator](v,rule_pattern) 
        if result  then
          return result,value,k
        end
			end
		end	
	else
		for _,v in ipairs(process_transform) do
			local result,value
			result,value = operator.request[rule_operator](v,rule_pattern)
			if result  then
				return result,value,rule_var
			end
		end
	end
	return false
end

local function _update_at(auto_update_period,global_update_rule)
    if _auto_update == "true" then
      local global_ok, global_err = ngx.timer.at(tonumber(auto_update_period),global_update_rule)
      if not global_ok then
        if global_err ~= "process exiting" then
          ngx.log(ngx.ERR, "failed to create the cycle timer: ", global_err)
        end
      end
    end
end

local function _momitor_update()
    local _update_website  =  _config_info.waf_monitor_website or "https://update2.jxwaf.com/waf_monitor"
    local httpc = http.new()
    httpc:set_timeouts(5000, 5000, 30000)
    local api_key = _config_info.waf_api_key or ""
    local api_password = _config_info.waf_api_password or ""
    local server_info = _config_info.server_info or ""
    local waf_node_uuid = _config_info.waf_node_uuid or ""
    local res, err = httpc:request_uri( _update_website , {
        method = "POST",
        body = "api_key="..api_key.."&api_password="..api_password.."&waf_node_uuid="..waf_node_uuid.."&server_info="..server_info,
        headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        }
    })
    if not res then
      ngx.log(ngx.ERR,"failed to request: ", err)
      return _update_at(tonumber(_auto_update_period),_momitor_update)
    end
		local res_body = cjson.decode(res.body)
		if not res_body then
      ngx.log(ngx.ERR,"init fail,failed to decode resp body " )
      return _update_at(tonumber(_auto_update_period),_momitor_update)
		end
    if  res_body['result'] == false then
      ngx.log(ngx.ERR,"init fail,failed to request, ",res_body['message'])
      return _update_at(tonumber(_auto_update_period),_momitor_update)
    end
    _waf_node_monitor = res_body['waf_node_monitor'] or _waf_node_monitor
    if _waf_node_monitor == "true" then
      local global_ok, global_err = ngx.timer.at(tonumber(_waf_node_monitor_period),_momitor_update)
      if not global_ok then
        if global_err ~= "process exiting" then
          ngx.log(ngx.ERR, "failed to create the cycle timer: ", global_err)
        end
      end
    end
    ngx.log(ngx.ALERT,"monitor report success")
end



local function _global_update_rule()
    local _update_website  =  _config_info.waf_update_website or "https://update2.jxwaf.com/yun/waf_update"
    local httpc = http.new()
    httpc:set_timeouts(5000, 5000, 30000)
    local api_key = _config_info.waf_api_key or ""
    local api_password = _config_info.waf_api_password or ""
    local res, err = httpc:request_uri( _update_website , {
        method = "POST",
        body = "api_key="..api_key.."&api_password="..api_password.."&md5=".._md5,
        headers = {
        ["Content-Type"] = "application/x-www-form-urlencoded",
        }
    })
    if not res then
      ngx.log(ngx.ERR,"failed to request: ", err)
      return _update_at(tonumber(_auto_update_period),_global_update_rule)
    end
		local res_body = cjson.decode(res.body)
		if not res_body then
      ngx.log(ngx.ERR,"init fail,failed to decode resp body " )
      return _update_at(tonumber(_auto_update_period),_global_update_rule)
		end
    if  res_body['result'] == false then
      ngx.log(ngx.ERR,"init fail,failed to request, ",res_body['message'])
      return _update_at(tonumber(_auto_update_period),_global_update_rule)
    end
    if not res_body['no_update'] then
      local tmp_waf_rule = res_body['waf_rule']
      if tmp_waf_rule == nil  then
        ngx.log(ngx.ERR,"init fail,can not decode waf rule")
        return _update_at(tonumber(_auto_update_period),_global_update_rule)
      else
        _update_waf_rule = tmp_waf_rule
      end
      
      if _update_waf_rule == nil  then
        ngx.log(ngx.ERR,"init fail,can not decode waf rule")
        return _update_at(tonumber(_auto_update_period),_global_update_rule)
      end
      for k,v in pairs(_update_waf_rule) do
        if type(v['custom_rule_set']) == "table" then
        table_sort(v['custom_rule_set'],_sort_rules)
        _update_waf_rule[k] = v 
        end
      end
      if res_body['jxcheck']  then
        local load_jxcheck = loadstring(ngx.decode_base64(res_body['jxcheck']))()
        if load_jxcheck then
          _jxcheck =  load_jxcheck
        end
      end
      if res_body['keycheck']  then
        local load_keycheck = loadstring(ngx.decode_base64(res_body['keycheck']))()
        if load_keycheck then
          _keycheck =  load_keycheck
        end
      end
      if res_body['botcheck']  then
        local load_botcheck = loadstring(ngx.decode_base64(res_body['botcheck']))()
        if load_botcheck then
          _bot_check =  load_botcheck
        end
      end
      if res_body['bot_auth_key'] then
        local bot_check_info = res_body['bot_auth_key']
        bot_check_standard_info = bot_check_info['standard']
        bot_check_image_info = bot_check_info['image']
        bot_check_slipper_info = bot_check_info['slipper']
        local standard_key = {}
        local slipper_key = {}
        local image_key = {}
        for k,_ in pairs(bot_check_standard_info) do
          table.insert(standard_key,k)
        end
        bot_check_standard_key = standard_key
        for k,_ in pairs(bot_check_slipper_info) do
          table.insert(slipper_key,k)
        end
        bot_check_slipper_key = slipper_key 
        for k,_ in pairs(bot_check_image_info) do
          table.insert(image_key,k)
        end
        bot_check_image_key = image_key
        ngx.log(ngx.ALERT, "bot check standard key count is ",#bot_check_standard_key)
        ngx.log(ngx.ALERT, "bot check key image count is ",#bot_check_slipper_key)
        ngx.log(ngx.ALERT, "bot check key slipper count is ",#bot_check_image_key)
      end
      if res_body['log_conf']  then
        _log_conf = res_body['log_conf']
      end
      local waf_common_conf = ngx.shared.waf_common_conf
      local md5_succ, md5_err = waf_common_conf:set("md5",res_body['md5'])
      if md5_err then
        ngx.log(ngx.ERR,"init fail,can not set waf_common_conf md5")
        return _update_at(tonumber(_auto_update_period),_global_update_rule)
      end
      local res_body_succ, res_body_err = waf_common_conf:set("res_body",res.body)
      if res_body_err then
        ngx.log(ngx.ERR,"init fail,can not set waf_common_conf res_body")
        return _update_at(tonumber(_auto_update_period),_global_update_rule)
      end
      _md5 = res_body['md5']
      ngx.log(ngx.ALERT,"global config info md5 is ".._md5..",update config info success")
    end
    _auto_update = res_body['auto_update'] or _auto_update
    _auto_update_period = res_body['auto_update_period'] or _auto_update_period
    if _auto_update == "true" then
      local global_ok, global_err = ngx.timer.at(tonumber(_auto_update_period),_global_update_rule)
      if not global_ok then
        if global_err ~= "process exiting" then
          ngx.log(ngx.ERR, "failed to create the cycle timer: ", global_err)
        end
      end
    end
end



local function _worker_update_rule()
  local waf_common_conf = ngx.shared.waf_common_conf
  local md5 = waf_common_conf:get("md5")
  if md5 and md5 ~= _md5 then
    local tmp_res_body = waf_common_conf:get("res_body")
    local res_body = cjson.decode(tmp_res_body)
		if not res_body then
      ngx.log(ngx.ERR,"worker error,init fail,failed to decode resp body " )
		end
    local tmp_waf_rule = res_body['waf_rule']
    if tmp_waf_rule == nil  then
      ngx.log(ngx.ERR,"init fail,can not decode waf rule")
    else
      _update_waf_rule = tmp_waf_rule
    end

    for k,v in pairs(_update_waf_rule) do
      if type(v['custom_rule_set']) == "table" then
      table_sort(v['custom_rule_set'],_sort_rules)
      _update_waf_rule[k] = v 
      end
    end
    
    if res_body['jxcheck']  then
      local load_jxcheck = loadstring(ngx.decode_base64(res_body['jxcheck']))()
      if load_jxcheck then
        _jxcheck =  load_jxcheck
      end
    end
    
    if res_body['keycheck']  then
      local load_keycheck = loadstring(ngx.decode_base64(res_body['keycheck']))()
      if load_keycheck then
        _keycheck =  load_keycheck
      end
    end
      
    if res_body['botcheck']  then
      local load_botcheck = loadstring(ngx.decode_base64(res_body['botcheck']))()
      if load_botcheck then
        _bot_check =  load_botcheck
      end
    end

    if res_body['bot_auth_key'] then
      local bot_check_info = res_body['bot_auth_key']
      bot_check_standard_info = bot_check_info['standard']
      bot_check_image_info = bot_check_info['image']
      bot_check_slipper_info = bot_check_info['slipper']
      local standard_key = {}
      local slipper_key = {}
      local image_key = {}
      for k,_ in pairs(bot_check_standard_info) do
        table.insert(standard_key,k)
      end
      bot_check_standard_key = standard_key
      for k,_ in pairs(bot_check_slipper_info) do
        table.insert(slipper_key,k)
      end
      bot_check_slipper_key = slipper_key 
      for k,_ in pairs(bot_check_image_info) do
        table.insert(image_key,k)
      end
      bot_check_image_key = image_key
      ngx.log(ngx.ALERT, "bot check standard key count is ",#bot_check_standard_key)
      ngx.log(ngx.ALERT, "bot check key image count is ",#bot_check_slipper_key)
      ngx.log(ngx.ALERT, "bot check key slipper count is ",#bot_check_image_key)
    end
    
    if res_body['log_conf']  then
      _log_conf = res_body['log_conf']
    end
    
    _process_rule()
    _md5 = res_body['md5']
    ngx.log(ngx.ALERT,"worker config info md5 is ".._md5..",update config info success")
  end

end


function _M.init_worker()
	if _config_info.waf_local == "false" then
    if process.type() == "privileged agent" then
      if _config_info.waf_node_monitor == "true" then
        local monitor_ok,monitor_err = ngx.timer.at(0,_momitor_update)
        if not monitor_ok then
          if monitor_err ~= "process exiting" then
            ngx.log(ngx.ERR, "failed to create the init timer: ", init_err)
          end
        end
      end
      local init_ok,init_err = ngx.timer.at(0,_global_update_rule)
      if not init_ok then
        if init_err ~= "process exiting" then
          ngx.log(ngx.ERR, "failed to create the init timer: ", init_err)
        end
      end
    else
      local worker_init_ok,worker_init_err = ngx.timer.at(0,_worker_update_rule)
      if not worker_init_ok then
        if worker_init_err ~= "process exiting" then
          ngx.log(ngx.ERR, "failed to create the init timer: ", worker_init_err)
        end
      end
      local hdl, err = ngx.timer.every(5,_worker_update_rule)
      if err then
          ngx.log(ngx.ERR, "failed to create the worker update timer: ", err)
      end
    end
  end
end

function _M.init(config_path)
	local init_config_path = config_path or _config_path
	local read_config = assert(io.open(init_config_path,'r+'))
	local raw_config_info = read_config:read('*all')
  read_config:close()
	local config_info = cjson.decode(raw_config_info)
	if config_info == nil then
		ngx.log(ngx.ERR,"init fail,can not decode config file")
	end
  if not config_info['waf_node_uuid'] then
    local waf_node_uuid = uuid.generate_random()
    config_info['waf_node_uuid'] = waf_node_uuid
    local new_config_info = cjson.encode(config_info)
    local write_config = assert(io.open(init_config_path,'w+'))
    write_config:write(new_config_info)
    write_config:close()
  end
	_config_info = config_info
  iputils.enable_lrucache()
  local ok, err = process.enable_privileged_agent()
  if not ok then
    ngx.log(ngx.ERR, "enables privileged agent failed error:", err)
  end
  ngx.log(ngx.ALERT,"jxwaf init success,waf node uuid is ".._config_info['waf_node_uuid'])
end


function _M.get_waf_rule()
	
	local update_waf_rule = _update_waf_rule

	return update_waf_rule

end

local function _custom_rule_match(rules)
	local result
	for _,rule in ipairs(rules) do
    local matchs_result = true
    local ctx_rule_log = {}
    for _,match in ipairs(rule.rule_matchs) do
      local operator_result = false
      for _,var in ipairs(match.rule_vars) do
        local process_request = _process_request(var)
        local process_transform = _process_transform(process_request,match.rule_transform,var)
        local _operator_result,_operator_value,_operator_key = _process_operator(process_transform,match,var,rule)
        if _operator_result and rule.rule_log == "true" then
          ctx_rule_log.rule_var = var.rule_var
          ctx_rule_log.rule_operator = match.rule_operator
          ctx_rule_log.rule_transform = match.rule_transform
					ctx_rule_log.rule_match_var = _operator_value
          ctx_rule_log.rule_match_key = _operator_key
          ctx_rule_log.rule_pattern = match.rule_pattern
        end
        if  _operator_result then
          operator_result = _operator_result
          break
        end
      end	
      if (not operator_result) then
        matchs_result = false
        break
      end
    end
    if matchs_result and rule.rule_log == "true" then                       
      local waf_log = {}
      waf_log['log_type'] = "owasp_attack"
      waf_log['protection_type'] = "custom_protection"
      waf_log['protection_info'] = rule.rule_action
      ngx.ctx.waf_log = waf_log
    end
    if rule.rule_action == "pass" and matchs_result then
      matchs_result = false
    end
    if matchs_result then
      return matchs_result,rule
    end
	end
	return result
end

function _M.custom_rule_check()
	local host = ngx.var.host
  local scheme = ngx.var.scheme
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
	if req_host then
		if req_host["protection_set"]["custom_protection"] == "true"  and #req_host["custom_rule_set"]  ~= 0 then
      local result,match_rule = _custom_rule_match(req_host["custom_rule_set"])
      if result then
        if match_rule.rule_action == 'deny' then
          if req_host['protection_set']['page_custom'] == "true" then
            exit_code.return_exit(req_host['page_custom_set']['owasp_code'],req_host['page_custom_set']['owasp_html'])
          end
          return exit_code.return_exit()
        elseif match_rule.rule_action == 'allow' then
          local scheme = ngx.var.scheme
          if req_host['domain_set'] and req_host['domain_set']['redirect_https'] == "true" and scheme == "http"  then
            local force_https = {}
            force_https[1] = 'https://'
            force_https[2] = host
            force_https[3] = ngx.var.request_uri
            return ngx.redirect(table_concat(force_https), 301)
          end
          return ngx.exit(0)
        elseif match_rule.rule_action == 'redirect' then
          return ngx.redirect('/')
        end
      end
		end
	end
  
end


function _M.redirect_https()
  local scheme = ngx.var.scheme
  if scheme == "https" then
    return
  end
  local host = ngx.var.host
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
	if req_host and  req_host['domain_set']['redirect_https'] == "true"  then
    local force_https = {}
    force_https[1] = 'https://'
    force_https[2] = host
    force_https[3] = ngx.var.request_uri
    return ngx.redirect(table_concat(force_https), 301)
  end
end


function _M.bot_auth_check()
  local host = ngx.var.host
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  if _bot_check and req_host and req_host["protection_set"]["cc_protection"] == "true" then
    local bot_check_uri = "/".._config_info.waf_api_key 
    if ngx.var.uri == bot_check_uri or ngx.var.uri == '/a20be899-96a6-40b2-88ba-32f1f75f1552-jxwaf' then
      _cc_black_ip_stat(req_host,'bot_auth')
    end
    local bot_check_mode = req_host["cc_protection_set"]["bot_check_mode"]
    if bot_check_mode == 'standard' then 
      _bot_check.bot_commit_auth(_config_info.waf_api_key,bot_check_standard_info)
    elseif bot_check_mode == 'image' then 
      _bot_check.bot_commit_auth(_config_info.waf_api_key,bot_check_image_info)
    elseif bot_check_mode == 'slipper' then 
      _bot_check.bot_commit_auth(_config_info.waf_api_key,bot_check_slipper_info)
    end
  end
end

function _M.limitreq_check()
  local host = ngx.var.host
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  if req_host["protection_set"]["cc_protection"] == "true" then
    local ip_addr = request.request['REMOTE_ADDR']()
    if req_host["cc_protection_set"]["emergency_mode_check"] == "true" then
      local waf_log = {}
      waf_log['log_type'] = "cc_attack"
      waf_log['protection_type'] = "emergency_mode_check"
      waf_log['protection_info'] =  req_host["cc_protection_set"]["emergency_handle_mode"] 
      ngx.ctx.waf_log = waf_log
      _cc_black_ip_stat(req_host,'emergency_handle_mode')
      if req_host["cc_protection_set"]["emergency_handle_mode"] == "block"  then
        --_cc_black_ip_stat(req_host,'emergency_handle_mode')
        return ngx.exit(444)
      elseif req_host["cc_protection_set"]["emergency_handle_mode"] == "bot_check" then
        if _bot_check  and #bot_check_standard_key > 0 and #bot_check_image_key > 0 and #bot_check_slipper_key > 0 then
          --_cc_black_ip_stat(req_host,'emergency_handle_mode')
          local bot_check_mode = req_host["cc_protection_set"]["bot_check_mode"]
          if bot_check_mode == 'standard' then
            _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_standard_info,bot_check_standard_key,bot_check_mode)
          elseif bot_check_mode == 'image' then
            _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_image_info,bot_check_image_key,bot_check_mode)
          elseif bot_check_mode == 'slipper' then
            _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_slipper_info,bot_check_slipper_key,bot_check_mode)
          end
        end
      elseif req_host["cc_protection_set"]["emergency_handle_mode"] == "network_layer_block" then
        local ip_addr = request.request['REMOTE_ADDR']()
        local shell_cmd = {}
        shell_cmd[1] = "/usr/sbin/ipset add jxwaf "
        shell_cmd[2] = ip_addr
        shell_cmd[3] = " timeout "
        shell_cmd[4] = "3600"
        local ok, stdout, stderr, reason, status =  shell.run(table_concat(shell_cmd), nil, 2000, 4069)
        if not ok then
          ngx.log(ngx.ERR,stdout, stderr, reason, status)
        end
        return ngx.exit(444)
      end
    end
    if req_host["cc_protection_set"]["count_check"] == "true" then
      local count = req_host["cc_protection_set"]["count"]
      local black_ip_time = req_host["cc_protection_set"]["black_ip_time"]
      local req_count_handle_mode = req_host["cc_protection_set"]["req_count_handle_mode"]
      local limit_req_count_result = limitreq.limit_req_count(count,black_ip_time,ngx_md5(ip_addr))
      if limit_req_count_result  then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "count_check"
        waf_log['protection_info'] =  req_count_handle_mode
        ngx.ctx.waf_log = waf_log
        if req_count_handle_mode == "block" then
          _cc_black_ip_stat(req_host,'count_check')
          return ngx.exit(444)
        elseif req_count_handle_mode == "bot_check" then
          if _bot_check  and #bot_check_standard_key > 0 and #bot_check_image_key > 0 and #bot_check_slipper_key > 0 then
            _cc_black_ip_stat(req_host,'count_check')
            local bot_check_mode = req_host["cc_protection_set"]["bot_check_mode"]
            if bot_check_mode == 'standard' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_standard_info,bot_check_standard_key,bot_check_mode)
            elseif bot_check_mode == 'image' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_image_info,bot_check_image_key,bot_check_mode)
            elseif bot_check_mode == 'slipper' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_slipper_info,bot_check_slipper_key,bot_check_mode)
            end
          end
        elseif req_count_handle_mode == "stat" then
          _cc_black_ip_stat(req_host,'count_check')
        end
      end
    end
    if req_host["protection_set"]["cc_protection"] == "true" and  req_host["cc_protection_set"]["qps_check"] == "true" then
      local ip_qps = req_host["cc_protection_set"]["ip_qps"]
      local ip_expire_qps = req_host["cc_protection_set"]["ip_expire_qps"]
      local req_freq_handle_mode = req_host["cc_protection_set"]["req_freq_handle_mode"]
      local limit_req_rate_result = limitreq.limit_req_rate(ip_qps,ip_expire_qps,ngx_md5(ip_addr))
      if limit_req_rate_result  then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "qps_check"
        waf_log['protection_info'] =  req_freq_handle_mode
        ngx.ctx.waf_log = waf_log
        if req_freq_handle_mode == "block" then
          _cc_black_ip_stat(req_host,'qps_check')
          return ngx.exit(444)
        elseif req_freq_handle_mode == "bot_check" then
          if _bot_check  and #bot_check_standard_key > 0 and #bot_check_image_key > 0 and #bot_check_slipper_key > 0 then
            _cc_black_ip_stat(req_host,'qps_check')
            local bot_check_mode = req_host["cc_protection_set"]["bot_check_mode"]
            if bot_check_mode == 'standard' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_standard_info,bot_check_standard_key,bot_check_mode)
            elseif bot_check_mode == 'image' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_image_info,bot_check_image_key,bot_check_mode)
            elseif bot_check_mode == 'slipper' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_slipper_info,bot_check_slipper_key,bot_check_mode)
            end
          end
        elseif req_freq_handle_mode == "stat" then
          _cc_black_ip_stat(req_host,'qps_check')
        end
      end
    end
    if req_host["cc_protection_set"]["domain_qps_check"] == "true" then
      local domain_qps = req_host["cc_protection_set"]["domain_qps"]
      local domin_qps_handle_mode = req_host["cc_protection_set"]["domin_qps_handle_mode"]
      local limit_req_domain_rate_result = limitreq.limit_req_domain_rate(domain_qps,ngx_md5(host))
      if limit_req_domain_rate_result  then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "domain_qps_check"
        waf_log['protection_info'] =  domin_qps_handle_mode
        ngx.ctx.waf_log = waf_log
        if domin_qps_handle_mode == "block" then
          _cc_black_ip_stat(req_host,'domain_qps_check')
          return ngx.exit(444)
        elseif domin_qps_handle_mode == "bot_check" then
          if _bot_check  and #bot_check_standard_key > 0 and #bot_check_image_key > 0 and #bot_check_slipper_key > 0 then
            _cc_black_ip_stat(req_host,'domain_qps_check')
            local bot_check_mode = req_host["cc_protection_set"]["bot_check_mode"]
            if bot_check_mode == 'standard' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_standard_info,bot_check_standard_key,bot_check_mode)
            elseif bot_check_mode == 'image' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_image_info,bot_check_image_key,bot_check_mode)
            elseif bot_check_mode == 'slipper' then
              _bot_check.bot_check_ip(_config_info.waf_api_key,bot_check_slipper_info,bot_check_slipper_key,bot_check_mode)
            end
          end
        elseif domin_qps_handle_mode == "stat" then
          _cc_black_ip_stat(req_host,'domain_qps_check')
        end
      end
    end
  end
end


function _M.jxcheck_protection()
  local host = ngx.var.host
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  if req_host and  req_host['protection_set']['owasp_protection'] == "true" and _jxcheck then
    -- owasp_check
    local sql_check = req_host['owasp_check_set']['sql_check']
    local xss_check = req_host['owasp_check_set']['xss_check']
    local command_inject_check = req_host['owasp_check_set']['command_inject_check']
    local directory_traversal_check = req_host['owasp_check_set']['directory_traversal_check']
    local sensitive_file_check = req_host['owasp_check_set']['sensitive_file_check']
    local code_exec_check = req_host['owasp_check_set']['code_exec_check']
    local owasp_result,owasp_type,owasp_action = _jxcheck.owasp_check(sql_check,xss_check,command_inject_check,directory_traversal_check,sensitive_file_check,code_exec_check)
    if owasp_result then
      local waf_log = {}
      waf_log['log_type'] = "owasp_attack"
      waf_log['protection_type'] = "jxwaf-"..owasp_type
      waf_log['protection_info'] = owasp_action
      ngx.ctx.waf_log = waf_log
      if owasp_action == "block" then
        _owasp_black_ip_stat(req_host,owasp_type)
        if req_host['protection_set']['page_custom'] == "true"  then
          exit_code.return_exit(req_host['page_custom_set']['owasp_code'],req_host['page_custom_set']['owasp_html'])
        end
        exit_code.return_exit()
      elseif owasp_action == "stat" then
        _owasp_black_ip_stat(req_host,owasp_type)
      end
    end
  end  
 
end


function _M.cc_black_ip_check()
  local host = ngx.var.host 
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
	if req_host and req_host['protection_set']['cc_attack_ip_protection'] == "true" then
    local ip_addr = request.request['REMOTE_ADDR']()
    local attack_ip_check = ngx.shared.black_cc_attack_ip
    local result,err = attack_ip_check:get(ip_addr)
    if err then
      ngx.log(ngx.ERR, "black cc ip check shared get err ", err)
    end
    if result then
      local black_ip_info = cjson.decode(result)
      local waf_log = {}
      waf_log['log_type'] = "cc_attack"
      waf_log['protection_type'] = "black_ip"
      waf_log['protection_info'] = black_ip_info['protection_info']
      ngx.ctx.waf_log = waf_log
      if black_ip_info['protection_info'] == "block"  then
        return ngx.exit(444)
      elseif black_ip_info['protection_info'] == "network_layer_block"  then
        local shell_cmd = {}
        if tonumber(black_ip_info['protecion_handle']) > 0 then
          shell_cmd[1] = "/usr/sbin/ipset add jxwaf "
          shell_cmd[2] = ip_addr
          shell_cmd[3] = " timeout "
          shell_cmd[4] = black_ip_info['protecion_handle']
        elseif tonumber(black_ip_info['protecion_handle']) == 0 then
          shell_cmd[1] = "/usr/sbin/ipset add jxwaf "
          shell_cmd[2] = ip_addr
        end
        local ok, stdout, stderr, reason, status =  shell.run(table_concat(shell_cmd), nil, 2000, 4069)
        if not ok then
          ngx.log(ngx.ERR,stdout, stderr, reason, status)
        end
        return ngx.exit(444)
      end
    end
	end
end


function _M.owasp_black_ip_check()
  local host = ngx.var.host 
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
	if req_host and req_host['protection_set']['evil_ip_handle'] == "true" then
    local ip_addr = request.request['REMOTE_ADDR']()
    local attack_ip_check = ngx.shared.black_owasp_attack_ip
    local result,err = attack_ip_check:get(ip_addr)
    if err then
      ngx.log(ngx.ERR, "black owasp ip check shared get err ", err)
    end
    if result then
      local black_ip_info = cjson.decode(result)
      local waf_log = {}
      waf_log['log_type'] = "owasp_attack"
      waf_log['protection_type'] = "black_ip"
      waf_log['protection_info'] = black_ip_info['protection_info']
      ngx.ctx.waf_log = waf_log
      if black_ip_info['protection_info'] == "block"  then
        if req_host['protection_set']['page_custom'] == "true"  then
          exit_code.return_exit(req_host['page_custom_set']['owasp_code'],req_host['page_custom_set']['owasp_html'])
        end 
        exit_code.return_exit()
      end
    end
	end
end


function _M.file_upload_check()
  local host = ngx.var.host 
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  local content_type = ngx.req.get_headers()["Content-type"]
  local content_length = ngx.req.get_headers()["Content-Length"]
  if content_type and  ngx.re.find(content_type, [=[^multipart/form-data]=],"oij") and content_length and tonumber(content_length) ~= 0 then
    ngx.ctx.upload_request = true
    if req_host and req_host['protection_set']['owasp_protection'] == "true" and req_host['owasp_check_set']['upload_check'] ~= "close" then
      local form, err = upload:new()
      local _file_name = {}
      local _form_name = {}
      local _file_type = {}
      local t ={}
      local _type_flag = "false"
      if not form then
        local waf_log = {}
        waf_log['log_type'] = "error"
        waf_log['protection_type'] = "upload_error"
        waf_log['protection_info'] = "failed to new upload: "..err
        ngx.ctx.waf_log = waf_log
        exit_code.return_error()
      end
      ngx.req.init_body()
      ngx.req.append_body("--" .. form.boundary)
      local lasttype, chunk
      local count = 0
      while true do
        count = count + 1
        local typ, res, err = form:read()
        if not typ then
          local waf_log = {}
          waf_log['log_type'] = "error"
          waf_log['protection_type'] = "upload_error"
          waf_log['protection_info'] = "failed to read: "..err
          ngx.ctx.waf_log = waf_log
          exit_code.return_error()
        end
        if typ == "header" then
          if res[1] == "Content-Disposition" then
            local _tmp_form_name = ngx.re.match(res[2],[=[(.+)\bname=[" ']*?([^"]+)[" ']*?]=],"oij")
            local _tmp_file_name =  ngx.re.match(res[2],[=[(.+)filename=[" ']*?([^"]+)[" ']*?]=],"oij")
            if _tmp_form_name  then
              table.insert(_form_name,_tmp_form_name[2]..count)
            end
            if _tmp_file_name  then
              table.insert(_file_name,_tmp_file_name[2])
            end
            if _tmp_form_name and _tmp_file_name then
              chunk = string.format([=[Content-Disposition: form-data; name="%s"; filename="%s"]=],_tmp_form_name[2],_tmp_file_name[2])
              ngx.req.append_body("\r\n" .. chunk)
            elseif _tmp_form_name then
              chunk = string.format([=[Content-Disposition: form-data; name="%s"]=],_tmp_form_name[2])
              ngx.req.append_body("\r\n" .. chunk)
            else
              local waf_log = {}
              waf_log['log_type'] = "error"
              waf_log['protection_type'] = "upload_error"
              waf_log['protection_info'] = "Content-Disposition ERR!"
              ngx.ctx.waf_log = waf_log
              exit_code.return_error()	
            end
          end
          if res[1] == "Content-Type" then
            table.insert(_file_type,res[2])
            _type_flag = "true"
            chunk = string.format([=[Content-Type: %s]=],res[2])
            ngx.req.append_body("\r\n" .. chunk)
          end
        end
        if typ == "body" then
          chunk = res
          if lasttype == "header" then
            ngx.req.append_body("\r\n\r\n")
          end
          ngx.req.append_body(chunk)
          if _type_flag == "true" then
            _type_flag = "false"
            t[_form_name[#_form_name]] = ""
          else
            if lasttype == "header" then
              t[_form_name[#_form_name]] = res
            else
              t[_form_name[#_form_name]] = ""
            end
          end
        end
        if typ == "part_end" then 
          ngx.req.append_body("\r\n--" .. form.boundary)
        end
        if typ == "eof" then
          ngx.req.append_body("--\r\n")
          break
        end
        lasttype = typ
      end
      form:read()
      ngx.req.finish_body()
      for _,v in ipairs(_file_name) do
        if not ngx.re.find(v,req_host['owasp_check_set']['upload_check_rule'],"oij") then
          local waf_log = {}
          waf_log['log_type'] = "owasp_attack"
          waf_log['protection_type'] = "upload_check"
          waf_log['protection_info'] = req_host['owasp_check_set']['upload_check']
          ngx.ctx.waf_log = waf_log
          if req_host['owasp_check_set']['upload_check'] ==  'block' then
            _owasp_black_ip_stat(req_host,'upload_check')
            if req_host['protection_set']['page_custom'] == "true"  then
              exit_code.return_exit(req_host['page_custom_set']['owasp_code'],req_host['page_custom_set']['owasp_html'])
            end 
            exit_code.return_exit()
          elseif req_host['owasp_check_set']['upload_check'] ==  'stat' then
            _owasp_black_ip_stat(req_host,'upload_check')
          end
        end
      end
    end
  else
    ngx.req.read_body()
  end
end

function _M.ip_config_check()
  local host = ngx.var.host 
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  if req_host['protection_set'] and req_host['protection_set']['ip_config'] == "true" then
    local ip_config = req_host['ip_config_set'] 
    local ip_addr = request.request['REMOTE_ADDR']()
    if ip_config[ip_addr] then
      if ip_config[ip_addr] == "block" then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "ip_config"
        waf_log['protection_info'] = "block"
        ngx.ctx.waf_log = waf_log
        return ngx.exit(444)
      elseif ip_config[ip_addr] == "network_layer_block" then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "ip_config"
        waf_log['protection_info'] = "network_layer_block"
        ngx.ctx.waf_log = waf_log
        local shell_cmd = {}
        shell_cmd[1] = "/usr/sbin/ipset add jxwaf "
        shell_cmd[2] = ip_addr
        shell_cmd[3] = " timeout 3600"
        local ok, stdout, stderr, reason, status =  shell.run(table_concat(shell_cmd), nil, 2000, 4069)
        if not ok then
          ngx.log(ngx.ERR,stdout, stderr, reason, status)
        end
        return ngx.exit(444)
      elseif ip_config[ip_addr] == "allow" then
        local waf_log = {}
        waf_log['log_type'] = "cc_attack"
        waf_log['protection_type'] = "ip_config"
        waf_log['protection_info'] = "white_ip"
        ngx.ctx.waf_log = waf_log
        return ngx.exit(0)
      end
    end
  end
  
end


function _M.rule_engine()
  local host = ngx.var.host
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  if req_host and  req_host['protection_set']['rule_engine'] == "true" and #req_host["rule_engine_set"]  ~= 0 and _keycheck then
      local rule_sets = req_host["rule_engine_set"]
      local check_keys = req_host["check_key_set"]
      local http_body = ngx.unescape_uri(request.request['HTTP_BODY']())
      local query_string = ngx.unescape_uri(request.request['HTTP_QUERY_STRING']())
      local args_header = request.request['ARGS_HEADERS']()
      args_header['referer'] = nil
      local header = ngx.unescape_uri(cjson.encode(args_header))
      local query_string_result = _keycheck.keyword_check(query_string,check_keys)
      local http_body_result = _keycheck.keyword_check(http_body_result,check_keys)
      local header_result = _keycheck.keyword_check(header,check_keys)
      for _,rule_set in ipairs(rule_sets) do 
        local flow_filter_count = rule_set['flow_filter_count']
        local check_content = rule_set['check_content']
        local rule_name = rule_set['rule_name']
        local check_uri = rule_set["check_uri"]
        local content_handle = rule_set["content_handle"]
        local white_url = rule_set["white_url"]
        local content_match = rule_set["content_match"]
        local match_action = rule_set["match_action"]
        local uri = ngx.var.uri
        if ((not check_uri) or (check_uri == uri)) and (white_url and white_url ~= uri) then  
          if check_content['get'] then
            if query_string_result[rule_name] == tonumber(flow_filter_count) then
              local get_value = query_string
              for _,v in ipairs(content_handle) do
                get_value = transform.request[v](get_value)	
              end
              local match_result = true
              for k,v in pairs(content_match) do
                local result = operator.request[k](get_value,v)
                if not result then
                  match_result = nil
                  break
                end
              end
              if match_result then
                local waf_log = {}
                waf_log['log_type'] = "owasp_attack"
                waf_log['protection_type'] = "rule_engine"
                waf_log['protection_info'] = rule_name.."-"..match_action
                ngx.ctx.waf_log = waf_log
                if match_action == 'deny' then
                  return exit_code.return_exit()
                end
              end
            end
          end
          if check_content['post'] then
            if http_body_result[rule_name] == tonumber(flow_filter_count) then
              local post_value = http_body
              for _,v in ipairs(content_handle) do
                post_value = transform.request[v](post_value)	
              end
              for k,v in pairs(content_match) do
                local result = operator.request[k](post_value,v)
                if result then
                  local waf_log = {}
                  waf_log['log_type'] = "owasp_attack"
                  waf_log['protection_type'] = "rule_engine"
                  waf_log['protection_info'] = rule_name.."-"..match_action
                  ngx.ctx.waf_log = waf_log
                  if match_action == 'deny' then
                    return exit_code.return_exit()
                  end
                end
              end
            end
          end
          if check_content['header'] then
            if header_result[rule_name] == tonumber(flow_filter_count) then
              local header_value = header
              for _,v in ipairs(content_handle) do
                header_value = transform.request[v](header_value)	
              end
              for k,v in pairs(content_match) do
                local result = operator.request[k](header_value,v)
                if result then
                  local waf_log = {}
                  waf_log['log_type'] = "owasp_attack"
                  waf_log['protection_type'] = "rule_engine"
                  waf_log['protection_info'] = rule_name.."-"..match_action
                  ngx.ctx.waf_log = waf_log
                  if match_action == 'deny' then
                    return exit_code.return_exit()
                  end
                end
              end
            end
          end
        end
      end
  end
end

function _M.access_init()
  local host = ngx.var.host 
  local req_host = _update_waf_rule[host] or ngx.ctx.req_host
  local xff = ngx.req.get_headers()['X-Forwarded-For'] or ngx.req.get_headers()['X-REAL-IP']
  if xff and req_host['domain_set']['proxy'] == "true" then
    local xff_result
    local iplist = iputils.parse_cidrs(req_host['domain_set']['proxy_ip'])
    if iputils.ip_in_cidrs(ngx.var.remote_addr, iplist) then
      local ip = ngx.re.match(xff,[=[^\d{1,3}+\.\d{1,3}+\.\d{1,3}+\.\d{1,3}+]=],'oj')[0] or ngx.req.get_headers()['X-REAL-IP']
      if ip and #ip > 6 then
        xff_result = ip 
      else
        xff_result = ngx.var.remote_addr
      end
    else
      xff_result = ngx.var.remote_addr
    end
    ngx.ctx.remote_addr = xff_result
  end
end


return _M
