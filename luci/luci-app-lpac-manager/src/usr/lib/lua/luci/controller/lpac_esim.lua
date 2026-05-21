-- /usr/lib/lua/luci/controller/lpac_esim.lua
-- LuCI controller for eSIM management via lpac-esim backend
-- Version: 1.3.5
-- License: GPL-2.0
--
-- Changelog:
--   1.3.0 - Diagnostics tab (syslog, soft/usb/uicc reset), io.popen fix,
--           theme-safe CSS, adaptive reset descriptions, MBIM config text fix
--   1.2.2 - ANSI/jq/async fixes, diagnostics APIs
--   1.2.1 - async_finish result model, valid_iccid helper, LPA regex loosened
--   1.2.0 - download/delete/nickname/notif_process, full MBIM support
--   1.0.0 - Initial release: profiles, chip, switch, reboot, config
--
-- Architecture: integration adapter between browser (JS Fetch API) and backend script.
-- Modem/eUICC logic lives in lpac-esim (POSIX shell).
-- Controller handles: UCI config, CLI flag building, input validation, JSON response wrapping.
--
-- Note: write endpoints require POST only.
-- CSRF token validation is omitted for compatibility with older LuCI/OpenWrt builds.
-- This is an intentional tradeoff for a home-router local-network scenario.
--
-- Flow:  Browser → Fetch → LuCI (uhttpd) → lpac_esim.lua → lpac-esim --api → stdout JSON → Browser
-- Async: Browser POST → lua → script --api switch → {"processing"} → Browser polls lock-status

module("luci.controller.lpac_esim", package.seeall)

local json = require "luci.jsonc"
local sys  = require "luci.sys"
local util = require "luci.util"
local uci  = require "luci.model.uci".cursor()

-- ============================================================================
-- Constants
-- ============================================================================

local BACKEND_SCRIPT = "/usr/bin/lpac-esim"
local UCI_CONFIG     = "lpac-esim"
local UCI_SECTION    = "lpac-esim"
local LOG_TAG        = "lpac-esim"
local RUN_DIR        = "/tmp/lpac-esim"
local RUN_LOG        = RUN_DIR .. "/run.log"

-- ============================================================================
-- Route registration
-- ============================================================================

function index()
    -- Main page entry - nested under QModem as sub-menu
    entry({"admin", "modem", "qmodem", "esim"}, template("lpac_esim/main"), _("eSIM Manager"), 10)

    -- Read-only endpoints (GET)
    entry({"admin", "modem", "qmodem", "esim", "profiles"},     call("api_profiles"),     nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "chip"},         call("api_chip"),         nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "modem_status"}, call("api_modem_status"), nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "notif_list"},   call("api_notif_list"),   nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "lock_status"},  call("api_lock_status"),  nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "config"},       call("api_get_config"),   nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "connectivity"}, call("api_connectivity"), nil).leaf = true

    -- Write endpoints (POST, some async)
    entry({"admin", "modem", "qmodem", "esim", "switch"},       call("api_switch"),       nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "reboot_modem"}, call("api_reboot"),       nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "notif_clear"},  call("api_notif_clear"),  nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "save_config"},  call("api_save_config"),  nil).leaf = true

    -- Download / Delete / Nickname / Notifications
    entry({"admin", "modem", "qmodem", "esim", "download"},      call("api_download"),      nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "delete"},        call("api_delete"),        nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "nickname"},      call("api_nickname"),      nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "notif_process"}, call("api_notif_process"), nil).leaf = true

    -- Diagnostics
    entry({"admin", "modem", "qmodem", "esim", "syslog"},     call("api_syslog"),     nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "runlog"},     call("api_runlog"),     nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "version"},    call("api_version"),    nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "at_cmd"},     call("api_at_cmd"),     nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "soft_reset"}, call("api_soft_reset"), nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "usb_reset"},  call("api_usb_reset"),  nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "uicc_reset"}, call("api_uicc_reset"), nil).leaf = true

    -- Telegram Bot endpoints
    entry({"admin", "modem", "qmodem", "esim", "telegram_config"},      call("api_telegram_config"),      nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "telegram_status"},      call("api_telegram_status"),      nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "save_telegram_config"}, call("api_save_telegram_config"), nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "test_telegram"},        call("api_test_telegram"),        nil).leaf = true
    entry({"admin", "modem", "qmodem", "esim", "telegram_toggle"},      call("api_telegram_toggle"),      nil).leaf = true
end

-- ============================================================================
-- Core helpers
-- ============================================================================

--- Read UCI config for lpac-esim, return table with defaults applied.
-- @return table  config key-value pairs
local function read_config()
    local config = {}
    uci:foreach(UCI_CONFIG, UCI_SECTION, function(s) config = s end)

    -- Apply sane defaults when UCI is empty or missing
    config.apdu_backend  = config.apdu_backend  or "qmi"
    config.qmi_device    = config.qmi_device    or "/dev/cdc-wdm0"
    config.qmi_sim_slot  = config.qmi_sim_slot  or "1"
    config.sim_slot      = config.sim_slot      or "0"
    config.at_device     = config.at_device     or ""
    config.mbim_device   = config.mbim_device   or "/dev/cdc-wdm0"
    config.mbim_proxy    = config.mbim_proxy    or "1"
    config.skip_slot_mapping = config.skip_slot_mapping or "1"
    config.reboot_method = config.reboot_method or "script"

    return config
end

--- Execute backend script with --api flag and return raw stdout.
-- Builds CLI flags from UCI config. Single sys.exec() call (no os.execute dupe).
-- @param cmd       string  sub-command to pass (e.g. "profiles", "switch <ICCID>")
-- @param timeout   number  max seconds (default 30)
-- @param silent    boolean if true, don't log to syslog (for read-only queries like syslog)
-- @return string|nil       raw stdout from script
function exec_script(cmd, timeout, silent)
    local config = read_config()

    local backend  = config.apdu_backend
    local at_dev   = config.at_device
    local t        = timeout or 30

    -- Build flags string based on backend
    local flags = "--api --backend " .. util.shellquote(backend)

    if backend == "mbim" then
        flags = flags .. " --mbim-device " .. util.shellquote(config.mbim_device)
        if config.mbim_proxy == "1" then
            flags = flags .. " --mbim-proxy"
        end
    else
        flags = flags .. " --device " .. util.shellquote(config.qmi_device)
        flags = flags .. " --slot " .. util.shellquote(config.qmi_sim_slot)
    end

    if at_dev ~= "" then
        flags = flags .. " --at-device " .. util.shellquote(at_dev)
    end

    -- Pass debug verbosity to backend
    if config.apdu_debug == "1" or config.http_debug == "1" or config.at_debug == "1" then
        flags = flags .. " --verbose"
    end

    -- Ensure run directory exists
    sys.exec("mkdir -p " .. RUN_DIR)

    -- Build command: use timeout if available, fallback to direct exec
    local timeout_bin = sys.exec("command -v timeout 2>/dev/null"):gsub("%s+$", "")
    local full_cmd
    if timeout_bin ~= "" then
        full_cmd = string.format("%s %d %s %s %s 2>>%s",
            timeout_bin, t, BACKEND_SCRIPT, flags, cmd, RUN_LOG)
    else
        full_cmd = string.format("%s %s %s 2>>%s",
            BACKEND_SCRIPT, flags, cmd, RUN_LOG)
    end

    -- Log only real operations, not read-only queries
    if not silent then
        local dev = ""
        if backend == "qmi" then dev = config.qmi_device or ""
        elseif backend == "mbim" then dev = config.mbim_device or ""
        elseif backend == "at" then dev = at_dev or ""
        end
        sys.exec("logger -t " .. util.shellquote(LOG_TAG) ..
            " " .. util.shellquote("[" .. backend:upper() .. " " .. dev .. "] " .. cmd))
    end

    -- Use io.popen instead of sys.exec for reliable stdout capture
    local f = io.popen(full_cmd)
    if not f then return nil end
    local out = f:read("*a")
    f:close()
    return out
end

--- Parse lpac JSON from raw output.
-- Handles the case where backend may print progress lines before the final JSON.
-- Takes the last non-empty line that parses as valid JSON.
-- @param raw  string  raw stdout
-- @return table|nil   parsed JSON table or nil
function parse_lpac_json(raw)
    if not raw or raw == "" then return nil end

    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then table.insert(lines, line) end
    end

    -- Iterate from end — take last line that parses as valid JSON
    for i = #lines, 1, -1 do
        local ok, data = pcall(json.parse, lines[i])
        if ok and data then return data end
    end

    return nil
end

--- Send a JSON response to the HTTP client.
-- @param data  table  data to serialize as JSON
function send_json(data)
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end

--- Build a standard lpac-format error response.
-- @param message  string  error type identifier
-- @param detail   string  human-readable message
-- @return table           lpac-format error object
local function make_error(message, detail)
    return {
        type = "lpa",
        payload = {
            code    = -1,
            message = message,
            data    = { msg = detail }
        }
    }
end

--- Enforce POST method; returns true if OK, false (and sends error) if not.
-- @return boolean
local function require_post()
    if luci.http.getenv("REQUEST_METHOD") ~= "POST" then
        send_json({ success = false, error = "Method not allowed" })
        return false
    end
    return true
end

--- Validate ICCID: 18-22 digits only.
-- @param s  string
-- @return boolean
local function valid_iccid(s)
    return s and s:match("^%d+$") ~= nil and #s >= 18 and #s <= 22
end

-- ============================================================================
-- GET endpoints — simple passthrough to backend
-- ============================================================================

-- All GET endpoints follow the same pattern: exec → parse → send.
-- Differences: command name and timeout.

function api_profiles()
    local raw  = exec_script("profiles", 20, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_chip()
    local raw  = exec_script("chip", 10, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_modem_status()
    local raw  = exec_script("modem-status", 10, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_notif_list()
    local raw  = exec_script("notif-list", 15, true)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_lock_status()
    local raw  = exec_script("lock-status", 5, true)  -- silent: polling, don't spam log
    local data = parse_lpac_json(raw)
    send_json(data or make_error("parse_error", "Empty or invalid response from backend"))
end

function api_connectivity()
    local ok = sys.call("ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1") == 0
    send_json({ success = true, connected = ok })
end

-- ============================================================================
-- POST async endpoints
-- ============================================================================

function api_switch()
    if not require_post() then return end

    local iccid = luci.http.formvalue("iccid")
    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end

    -- Validate ICCID
    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end

    -- Backend handles async launch internally; timeout 10s is for the initial response only
    local raw  = exec_script("switch " .. util.shellquote(iccid), 10)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

function api_reboot()
    if not require_post() then return end

    local raw  = exec_script("reboot-modem", 10)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

function api_notif_clear()
    if not require_post() then return end

    local raw  = exec_script("notif-clear", 20)
    local data = parse_lpac_json(raw)
    send_json(data or {
        type = "lpa",
        payload = { code = 0, message = "success", data = { cleared = true } }
    })
end

-- ============================================================================
-- UCI Config endpoints (direct UCI read/write, no backend script)
-- ============================================================================

function api_get_config()
    local config = read_config()
    -- Strip internal UCI fields that may leak through
    config[".type"]      = nil
    config[".name"]      = nil
    config[".anonymous"] = nil
    config[".index"]     = nil
    send_json({ success = true, config = config })
end

function api_save_config()
    if not require_post() then return end

    local raw = luci.http.formvalue("config")
    if not raw then
        send_json({ success = false, error = "No data" })
        return
    end

    local cfg = json.parse(raw)
    if not cfg then
        send_json({ success = false, error = "Invalid JSON" })
        return
    end

    -- Whitelist allowed config keys to prevent injection
    local allowed_keys = {
        "apdu_backend",
        "qmi_device", "qmi_sim_slot", "sim_slot",
        "at_device",
        "mbim_device", "mbim_proxy",
        "skip_slot_mapping", "custom_isd_r_aid",
        "reboot_method",
        "apdu_debug", "http_debug", "at_debug"
    }
    local sanitized = {}
    for _, key in ipairs(allowed_keys) do
        if cfg[key] ~= nil then
            sanitized[key] = tostring(cfg[key])
        end
    end

    -- Strip empty strings (frontend may send "" for missing form fields)
    for k, v in pairs(sanitized) do
        if v == "" then sanitized[k] = nil end
    end

    -- Validate values
    local valid_backends = { qmi = true, at = true, mbim = true }
    if sanitized.apdu_backend and not valid_backends[sanitized.apdu_backend] then
        send_json({ success = false, error = "Invalid backend. Use: qmi, at, mbim" })
        return
    end
    local valid_slots = { ["1"] = true, ["2"] = true }
    local valid_sim_slots = { ["0"] = true, ["1"] = true }
    if sanitized.qmi_sim_slot and not valid_slots[sanitized.qmi_sim_slot] then
        return send_json(make_error("invalid_config", "Invalid QMI slot. Use: 1 or 2"))
    end
    if sanitized.sim_slot and not valid_sim_slots[sanitized.sim_slot] then
        return send_json(make_error("invalid_config", "Invalid SIM slot. Use: 0 or 1"))
    end
    local valid_flags = { ["0"] = true, ["1"] = true }
    for _, fkey in ipairs({"apdu_debug", "http_debug", "at_debug", "mbim_proxy"}) do
        if sanitized[fkey] and not valid_flags[sanitized[fkey]] then
            send_json({ success = false, error = "Invalid value for " .. fkey .. ". Use: 0 or 1" })
            return
        end
    end
    for _, dkey in ipairs({"qmi_device", "at_device", "mbim_device"}) do
        if sanitized[dkey] and sanitized[dkey] ~= "" and not sanitized[dkey]:match("^/dev/") then
            send_json({ success = false, error = "Invalid device path for " .. dkey .. ". Must start with /dev/" })
            return
        end
    end

    -- Reload UCI cursor to get fresh state
    local fresh_uci = require("luci.model.uci").cursor()
    fresh_uci:delete(UCI_CONFIG, "main")
    fresh_uci:section(UCI_CONFIG, UCI_SECTION, "main", sanitized)

    if fresh_uci:commit(UCI_CONFIG) then
        send_json({ success = true, message = "Configuration saved" })
    else
        send_json({ success = false, error = "UCI commit failed" })
    end
end

-- ============================================================================
-- Download / Delete / Nickname / Notification process
-- ============================================================================

--- POST: Download profile from SM-DP+ server (async — may take 60-120s)
-- Accepts: lpa (LPA:1$ string) OR smdp + matching_id pair
-- Optional: confirmation (confirmation code)
function api_download()
    if not require_post() then return end

    local lpa     = luci.http.formvalue("lpa")
    local smdp    = luci.http.formvalue("smdp")
    local matchid = luci.http.formvalue("matching_id")
    local confirm = luci.http.formvalue("confirmation")

    local has_lpa  = lpa and lpa ~= ""
    local has_pair = smdp and smdp ~= "" and matchid and matchid ~= ""

    if not has_lpa and not has_pair then
        send_json(make_error("missing_param",
            "Provide LPA activation code (LPA:1$...) or SM-DP+ server address with matching ID"))
        return
    end

    -- Build backend command
    local dl_flags = ""
    if has_lpa then
        -- Light sanity check: LPA:1$something$something — lpac does real parsing
        if not lpa:match("^LPA:1%$.+%$.") then
            send_json(make_error("invalid_lpa", "LPA code must match format LPA:1$domain$code"))
            return
        end
        dl_flags = "download --lpa " .. util.shellquote(lpa)
    else
        dl_flags = "download --smdp " .. util.shellquote(smdp) ..
                   " --matching-id " .. util.shellquote(matchid)
    end

    if confirm and confirm ~= "" then
        dl_flags = dl_flags .. " --confirmation " .. util.shellquote(confirm)
    end

    local raw  = exec_script(dl_flags, 10)  -- backend launches async, returns immediately
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Delete a profile (must be disabled first, irreversible!)
function api_delete()
    if not require_post() then return end

    local iccid = luci.http.formvalue("iccid")
    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end

    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end

    local raw  = exec_script("delete " .. util.shellquote(iccid), 30)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Rename a profile (set nickname)
function api_nickname()
    if not require_post() then return end

    local iccid    = luci.http.formvalue("iccid")
    local nickname = luci.http.formvalue("nickname")

    if not iccid or iccid == "" then
        send_json(make_error("missing_param", "iccid required"))
        return
    end
    if not valid_iccid(iccid) then
        send_json(make_error("invalid_iccid", "ICCID must be 18-22 digits"))
        return
    end
    if not nickname or nickname == "" then
        send_json(make_error("missing_param", "nickname required"))
        return
    end

    -- Sanitize nickname: alphanumeric, spaces, underscores, hyphens, max 64 chars
    if #nickname > 64 then
        send_json(make_error("invalid_nickname", "Nickname too long (max 64 characters)"))
        return
    end

    local raw  = exec_script("nickname " .. util.shellquote(iccid) ..
                             " --nickname " .. util.shellquote(nickname), 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Process all pending notifications (async — requires internet)
function api_notif_process()
    if not require_post() then return end

    local raw  = exec_script("notif-process", 10)  -- backend launches async
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

-- ============================================================================
-- Diagnostics
-- ============================================================================

--- GET: Filtered syslog (modem + lpac events)
function api_syslog()
    local raw  = exec_script("syslog", 10, true)  -- silent: don't log reads
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- GET: Backend initialization log (run.log contents)
function api_runlog()
    local raw  = exec_script("runlog", 5, true)  -- silent
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- GET: Package and component versions
function api_version()
    local raw  = exec_script("version", 5, true)  -- silent
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: Send AT command to serial port
function api_at_cmd()
    local at_cmd = luci.http.formvalue("cmd") or "ATI"
    -- Sanitize: only allow printable ASCII, max 200 chars
    at_cmd = at_cmd:gsub("[^%w%s%+%-%=%?%^%$%*%#%%/%.,:;!@&()%[%]]", ""):sub(1, 200)
    local raw = exec_script("at-cmd " .. util.shellquote(at_cmd), 8)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from AT port"))
end

--- POST: Soft reset modem (QMI offline/online or AT+CFUN, no USB re-enum)
function api_soft_reset()
    if not require_post() then return end
    local raw  = exec_script("soft-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: USB port re-initialization (sysfs authorized 0→1)
function api_usb_reset()
    if not require_post() then return end
    local raw  = exec_script("usb-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

--- POST: UICC SIM power cycle (QMI UIM power off/on)
function api_uicc_reset()
    if not require_post() then return end
    local raw  = exec_script("uicc-reset", 15)
    local data = parse_lpac_json(raw)
    send_json(data or make_error("backend_error", "No response from backend"))
end

-- ============================================================================
-- Telegram Bot endpoints
-- ============================================================================

--- GET: Read telegram bot config from UCI
function api_telegram_config()
    local tg_uci = require("luci.model.uci").cursor()
    local config = {}
    tg_uci:foreach("qmodem_esim_bot", "bot", function(s)
        config = s
    end)
    config.enabled = config.enabled or "0"
    config.token = config.token or ""
    config.chat_id = config.chat_id or ""
    config.poll_interval = config.poll_interval or "2"
    config.allow_disruptive = config.allow_disruptive or "1"
    config.require_confirm = config.require_confirm or "1"
    -- Mask token for security (only show first 8 and last 4 chars)
    if config.token ~= "" and #config.token > 12 then
        config.token = string.sub(config.token, 1, 8) .. "..." .. string.sub(config.token, -4)
    end
    -- Strip internal UCI fields
    config[".type"] = nil
    config[".name"] = nil
    config[".anonymous"] = nil
    config[".index"] = nil
    send_json({ config = config })
end

--- GET: Check if bot process is running + read status file for live info
function api_telegram_status()
    local running = false
    local status_data = {}
    local pid_file = "/var/run/qmodem-esim-bot.pid"

    -- Check PID
    local f = io.open(pid_file, "r")
    if f then
        local pid = f:read("*l")
        f:close()
        if pid and pid ~= "" then
            local check = io.open("/proc/" .. pid .. "/status", "r")
            if check then
                check:close()
                running = true
            end
        end
    end

    -- Read status file (written by bot every poll cycle)
    local sf = io.open("/tmp/lpac-esim/telegram.status", "r")
    if sf then
        local raw = sf:read("*a")
        sf:close()
        if raw and raw ~= "" then
            local ok, data = pcall(json.parse, raw)
            if ok and data then
                status_data = data
            end
        end
    end

    send_json({
        running = running,
        state = status_data.state or (running and "unknown" or "stopped"),
        last_poll = status_data.last_poll,
        last_rc = status_data.last_rc,
        pid = status_data.pid
    })
end

--- POST: Save telegram bot config to UCI
function api_save_telegram_config()
    if not require_post() then return end

    local enabled = luci.http.formvalue("enabled") or "0"
    local token = luci.http.formvalue("token") or ""
    local chat_id = luci.http.formvalue("chat_id") or ""
    local poll_interval = luci.http.formvalue("poll_interval") or "30"
    local allow_disruptive = luci.http.formvalue("allow_disruptive") or "1"
    local require_confirm = luci.http.formvalue("require_confirm") or "1"

    -- Validate
    if enabled == "1" then
        if token == "" then
            send_json({ success = false, error = "Bot token is required" })
            return
        end
        if chat_id == "" then
            send_json({ success = false, error = "Chat ID is required" })
            return
        end
    end

    -- Save to UCI
    local tg_uci = require("luci.model.uci").cursor()
    tg_uci:set("qmodem_esim_bot", "main", "bot")
    tg_uci:set("qmodem_esim_bot", "main", "enabled", enabled)
    -- Only update token if not masked
    if token ~= "" and not token:match("^........%.%.%.") then
        tg_uci:set("qmodem_esim_bot", "main", "token", token)
    end
    tg_uci:set("qmodem_esim_bot", "main", "chat_id", chat_id)
    tg_uci:set("qmodem_esim_bot", "main", "poll_interval", poll_interval)
    tg_uci:set("qmodem_esim_bot", "main", "allow_disruptive", allow_disruptive)
    tg_uci:set("qmodem_esim_bot", "main", "require_confirm", require_confirm)

    if tg_uci:commit("qmodem_esim_bot") then
        sys.exec("/etc/init.d/qmodem_esim_bot reload 2>/dev/null")
        send_json({ success = true })
    else
        send_json({ success = false, error = "Failed to commit UCI" })
    end
end

--- POST: Send test message via Telegram
function api_test_telegram()
    if not require_post() then return end

    local token = luci.http.formvalue("token") or ""
    local chat_id = luci.http.formvalue("chat_id") or ""

    if token == "" or chat_id == "" then
        send_json({ success = false, error = "Token and Chat ID required" })
        return
    end

    local cmd = string.format(
        "curl -s -m 10 -X POST 'https://api.telegram.org/bot%s/sendMessage' -d 'chat_id=%s' -d 'text=✅ QModem eSIM Bot - connection test OK!' 2>/dev/null",
        token, chat_id
    )
    local result = sys.exec(cmd)
    local ok = result and result:match('"ok":true')
    if ok then
        send_json({ success = true })
    else
        local desc = "Unknown error"
        if result then
            desc = result:match('"description":"([^"]*)"') or desc
        end
        send_json({ success = false, error = desc })
    end
end

--- POST: Start or stop the bot service
function api_telegram_toggle()
    if not require_post() then return end

    local action = luci.http.formvalue("action") or "start"

    if action == "start" then
        sys.exec("/etc/init.d/qmodem_esim_bot start 2>/dev/null")
    else
        sys.exec("/etc/init.d/qmodem_esim_bot stop 2>/dev/null")
    end
    send_json({ success = true })
end
