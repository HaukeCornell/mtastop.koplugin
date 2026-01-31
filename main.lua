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
}

function MTAStop:init()
    self.ui.menu:registerToMainMenu(self)
    self:loadSettings()
end

function MTAStop:loadSettings()
    if self.settings then return end
    self.settings = LuaSettings:open(self.settings_file)
    self.api_key = self.settings:readSetting("api_key") or ""
end

function MTAStop:saveSettings()
    if not self.settings then return end
    self.settings:saveSetting("api_key", self.api_key or "")
    self.settings:flush()
end

-- Catch events for rotation and closing
function MTAStop:handleEvent(ev)
    if ev.type == "tap" then
        local w = Screen:getWidth()
        local h = Screen:getHeight()
        
        -- Top right corner (200x200 for easier hitting)
        if ev.pos.x > w - 200 and ev.pos.y < 200 then
            self:onToggleRotation()
            return true
        end

        -- Center area (0.6x0.6) for closing
        if ev.pos.x > w * 0.2 and ev.pos.x < w * 0.8 and
           ev.pos.y > h * 0.2 and ev.pos.y < h * 0.8 then
            self:onTapClose()
            return true
        end
    end
    return InputContainer.handleEvent(self, ev)
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
    if self.api_key == "" then
       -- If no key, we might need a way to set it. For now, we'll use the hardcoded one if it matches a placeholder
       -- but the user wants me to NOT leak it. So I'll tell them it's missing.
       self.status_widget = TextWidget:new{
           text = _("API Key Missing! Set it in settings/mtastop.lua"),
           face = Font:getFace("cfont", 30),
           maxWidth = Screen:getWidth() * 0.8
       }
       self.container = CenterContainer:new{ self.status_widget, dimen = Screen:getSize() }
       self[1] = FrameContainer:new{ background = Blitbuffer.COLOR_WHITE, self.container }
       UIManager:show(self, "full")
       return
    end

    self.dimen = Screen:getSize()
    if not self.api then
        self.api = MTAApi:new({api_key = self.api_key})
    end
    
    -- Loading state
    self.status_widget = TextWidget:new{
        text = _("Wait..."),
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
            self.status_widget:setText(_("Updating..."))
            UIManager:setDirty(self, "ui")
        end
        self:refreshData()
    end)
    
    self:setupAutoRefresh()
end

function MTAStop:refreshData()
    logger.info("MTAStop: Refreshing data")
    
    local ok, all_arrivals = pcall(function()
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
    
    if ok and all_arrivals then
        table.sort(all_arrivals, function(a, b) return a.wait_time < b.wait_time end)
        self:renderArrivals(all_arrivals)
    else
        logger.err("MTAStop: Error refreshing data", all_arrivals)
        if self.status_widget then
            self.status_widget:setText(_("Error."))
            UIManager:setDirty(self, "ui")
        end
    end
end

function MTAStop:renderArrivals(arrivals)
    self.dimen = Screen:getSize()
    logger.info("MTAStop: Rendering", #arrivals, "arrivals, dimen:", self.dimen.w, "x", self.dimen.h)
    
    local rows = {}
    
    -- Header: Refresh Icon + Time
    local header_row = HorizontalGroup:new{
        TextWidget:new{
            text = "↻ " .. os.date("%X"),
            face = Font:getFace("cfont", 34),
            padding = 10,
        },
        HorizontalSpan:new{width = self.dimen.w * 0.4},
        TextWidget:new{
            text = "ROT ⟳",
            face = Font:getFace("cfont", 20),
            padding = 10,
        }
    }
    table.insert(rows, header_row)
    table.insert(rows, VerticalSpan:new{height = 20})

    if #arrivals == 0 then
        table.insert(rows, TextWidget:new{
            text = _("No buses found."),
            face = Font:getFace("cfont", 32),
        })
    else
        local limit = math.min(#arrivals, self.dimen.h > self.dimen.w and 6 or 4)
        
        local line_font_size = self.dimen.w > self.dimen.h and 70 or 50
        local dest_font_size = self.dimen.w > self.dimen.h and 26 or 20
        local wait_font_size = self.dimen.w > self.dimen.h and 60 or 40
        local sub_font_size = self.dimen.w > self.dimen.h and 22 or 18

        for i = 1, limit do
            local arr = arrivals[i]
            
            local line_txt = TextWidget:new{
                text = arr.line_name,
                face = Font:getFace("cfont", line_font_size),
                padding = 5,
            }
            
            -- Info column: Destination + Stops Away
            local info_group = VerticalGroup:new{
                TextWidget:new{
                    text = arr.destination:upper(),
                    face = Font:getFace("cfont", dest_font_size),
                    maxWidth = self.dimen.w * 0.5,
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
    
    -- Footer
    table.insert(rows, TextWidget:new{
        text = _("Center Tap to Exit"),
        face = Font:getFace("cfont", 16),
        padding = 5,
    })

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

function MTAStop:onToggleRotation()
    logger.info("MTAStop: Toggling orientation")
    if Screen:isPortrait() then
        Screen:setOrientation(Device.SCREEN_ORIENTATION_LANDSCAPE)
    else
        Screen:setOrientation(Device.SCREEN_ORIENTATION_PORTRAIT)
    end
    -- Some devices need a wait
    UIManager:scheduleIn(0.5, function()
        self.dimen = Screen:getSize()
        self:refreshData()
    end)
end

function MTAStop:onOrientationUpdate()
    logger.info("MTAStop: Orientation update detected")
    self.dimen = Screen:getSize()
    self:refreshData()
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

function MTAStop:onTapClose()
    UIManager:close(self)
end

return MTAStop
