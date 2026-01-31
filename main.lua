local _ = require("gettext")
local Blitbuffer = require("ffi/blitbuffer")
local C_ = _.pgettext
local CenterContainer = require("ui/widget/container/centercontainer")
local DataStorage = require("datastorage")
local datetime = require("frontend/datetime")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local logger = require("logger")
local LuaSettings = require("luasettings")
local Screen = Device.screen
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local HorizontalSpan = require("ui/widget/horizontalspan")
local InputContainer = require("ui/widget/container/inputcontainer")
local NetworkMgr = require("ui/network/manager")
local ffiutil = require("ffi/util")
local T = ffiutil.template

-- Robust require for API
local MTAApi
local ok, res = pcall(require, "api")
if ok then
    MTAApi = res
else
    logger.warn("MTAStop: Local require failed, trying full path", res)
    ok, res = pcall(require, "plugins/mtastop.koplugin/api")
    if ok then
        MTAApi = res
    else
        error("MTAStop: Could not load api.lua: " .. tostring(res))
    end
end

local MTAStop = InputContainer:new{
    name = "MTAStop",
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/mtastop.lua",
    settings = nil,
    stops = { "504228", "505277" },
    temperature = nil,
}

function MTAStop:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
    self:setupGestures()
end

function MTAStop:setupGestures()
    local w = Screen:getWidth()
    local h = Screen:getHeight()
    -- Only need TapClose now (Center 0.6x0.6)
    self.ges_events = {
        TapClose = {
            GestureRange:new{
                ges = "tap",
                range = Geom:new{
                    x = w * 0.2, y = h * 0.2,
                    w = w * 0.6, h = h * 0.6,
                }
            }
        }
    }
end

function MTAStop:onTapClose()
    logger.info("MTAStop: onTapClose")
    UIManager:close(self)
    return true
end

function MTAStop:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
    self.api_key = self.settings:readSetting("api_key") or ""
    self.lat = self.settings:readSetting("latitude") or 40.7128
    self.lon = self.settings:readSetting("longitude") or -74.0060
end

function MTAStop:addToMainMenu(menu_items)
    menu_items.mta_stop = {
        text = _("MTA Bus Stops"),
        sorting_hint = "tools",
        callback = function()
            self:showArrivals()
        end
    }
end

function MTAStop:showArrivals()
    logger.info("MTAStop: Showing arrivals")
    
    self:loadSettings()
    self.dimen = Screen:getSize()
    self:setupGestures()

    if self.api_key == "" then
       logger.warn("MTAStop: API Key Missing")
       self.status_widget = TextWidget:new{
           text = _("API Key Missing!\nCreate koreader/settings/mtastop.lua\n\nTap center to exit."),
           face = Font:getFace("cfont", 30),
           alignment = "center",
           maxWidth = self.dimen.w * 0.8
       }
       self.container = CenterContainer:new{ self.status_widget, dimen = self.dimen }
       self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, self.container }
       UIManager:show(self, "full")
       return
    end

    if not self.api then
        self.api = MTAApi:new({api_key = self.api_key})
    end
    
    self.status_widget = TextWidget:new{
        text = _("Connecting..."),
        face = Font:getFace("cfont", 40)
    }
    
    self.container = CenterContainer:new{
        self.status_widget,
        dimen = self.dimen
    }
    
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        self.container
    }
    
    UIManager:show(self, "full")
    
    NetworkMgr:turnOnWifiAndWaitForConnection(function()
        if self.status_widget then
            self.status_widget:setText(_("Updating SIRI..."))
            UIManager:setDirty(self, "ui")
        end
        self:refreshData()
    end)
    
    self:setupAutoRefresh()
end

function MTAStop:refreshData()
    logger.info("MTAStop: Refreshing data")
    
    -- Fetch arrivals and weather in parallel-ish pcall
    local ok_arr, all_arrivals = pcall(function()
        local results = {}
        for _, stop_id in ipairs(self.stops) do
            local arrivals = self.api:getStopMonitoring(stop_id)
            if arrivals then
                for _, arr in ipairs(arrivals) do
                    table.insert(results, arr)
                end
            end
        end
        return results
    end)

    local ok_wea, temp = pcall(function()
        return self.api:getCurrentWeather(self.lat, self.lon)
    end)
    
    if ok_wea and temp then
        self.temperature = temp
    end

    if ok_arr and all_arrivals then
        table.sort(all_arrivals, function(a, b) return a.wait_time < b.wait_time end)
        self:renderArrivals(all_arrivals)
    else
        logger.err("MTAStop: Error refreshing data", all_arrivals)
        if self.status_widget then
            self.status_widget:setText(_("API Error."))
            UIManager:setDirty(self, "ui")
        end
    end
end

function MTAStop:renderArrivals(arrivals)
    self.dimen = Screen:getSize()
    logger.info("MTAStop: Rendering", #arrivals, "arrivals")
    
    local rows = {}
    
    -- Header Row: Left = Time, Right = Temperature
    local temp_str = self.temperature and string.format("%.1f°C", self.temperature) or ""
    local header_row = HorizontalGroup:new{
        TextWidget:new{
            text = "↻ " .. os.date("%X"),
            face = Font:getFace("cfont", 34),
            padding = 10,
        },
        HorizontalSpan:new{width = math.max(10, self.dimen.w * 0.4)},
        TextWidget:new{
            text = temp_str,
            face = Font:getFace("cfont", 34),
            padding = 10,
        }
    }
    table.insert(rows, header_row)
    table.insert(rows, VerticalSpan:new{height = 20})

    if #arrivals == 0 then
        table.insert(rows, TextWidget:new{
            text = _("No arrivals found."),
            face = Font:getFace("cfont", 32),
        })
    else
        local is_portrait = self.dimen.h > self.dimen.w
        local limit = math.min(#arrivals, is_portrait and 6 or 4)
        
        local line_font_size = is_portrait and 50 or 70
        local dest_font_size = is_portrait and 20 or 26
        local wait_font_size = is_portrait and 40 or 60
        local sub_font_size = is_portrait and 16 or 22

        for i = 1, limit do
            local arr = arrivals[i]
            
            local line_txt = TextWidget:new{
                text = arr.line_name,
                face = Font:getFace("cfont", line_font_size),
                padding = 5,
            }
            
            local info_group = VerticalGroup:new{
                TextWidget:new{
                    text = arr.destination:upper(),
                    face = Font:getFace("cfont", dest_font_size),
                    maxWidth = self.dimen.w * 0.45,
                    padding = 2,
                }
            }
            
            if arr.stops_away then
                table.insert(info_group, TextWidget:new{
                    text = T(_("%1 stops away"), arr.stops_away),
                    face = Font:getFace("cfont", sub_font_size),
                    padding = 2,
                })
            end
            
            local wait_txt = TextWidget:new{
                text = string.format("%d min", arr.wait_time),
                face = Font:getFace("cfont", wait_font_size),
                padding = 5,
            }
            
            local row = HorizontalGroup:new{
                line_txt,
                HorizontalSpan:new{width = 15},
                info_group,
                HorizontalSpan:new{width = 15},
                wait_txt
            }
            
            table.insert(rows, row)
            table.insert(rows, VerticalSpan:new{height = 15})
        end
    end
    
    -- Removed exit instruction in footer as requested

    if self[1] then
        self[1]:free()
    end

    self.vertical_group = VerticalGroup:new(rows)
    self.container = CenterContainer:new{
        self.vertical_group,
        dimen = self.dimen
    }
    
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        self.container
    }
    
    UIManager:setDirty(self, "ui")
end

-- KOreader detects orientation changes automatically and calls this
function MTAStop:onOrientationUpdate()
    logger.info("MTAStop: Orientation update detected")
    self.dimen = Screen:getSize()
    self:setupGestures()
    if self.api_key ~= "" then
        self:refreshData()
    else
        self:showArrivals()
    end
end

function MTAStop:setupAutoRefresh()
    if self.autoRefresh then return end
    
    self.autoRefresh = function()
        logger.info("MTAStop: Auto refresh cycle")
        self:refreshData()
        UIManager:scheduleIn(60, self.autoRefresh)
    end
    
    UIManager:scheduleIn(60, self.autoRefresh)
    
    self.onCloseWidget = function()
        UIManager:unschedule(self.autoRefresh)
        self.autoRefresh = nil
    end
end

return MTAStop
