local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local logger = require("logger")
local json = require("json")

local MTAApi = {
    api_key = nil
}

function MTAApi:new(o)
    o = o or {}
    self.__index = self
    setmetatable(o, self)
    return o
end

function MTAApi:_makeRequest(url)
    local sink = {}
    socketutil:set_timeout()
    local request = {
        url = url,
        method = "GET",
        sink = ltn12.sink.table(sink),
    }
    logger.info("MTAApi: Requesting URL", url)
    local headers = socket.skip(2, http.request(request))
    socketutil:reset_timeout()
    
    if headers == nil then
        logger.err("MTAApi: Network request failed (headers nil)")
        return nil
    end
    
    local result_response = table.concat(sink)
    if result_response ~= "" then
        local status, result = pcall(json.decode, result_response)
        if status then
            return result
        else
            logger.err("MTAApi: JSON decode failed", result)
            return nil
        end
    else
        logger.err("MTAApi: Empty response received")
        return nil
    end
end

-- Robust ISO 8601 date parsing with timezone support
-- Returns epoch time in UTC
function MTAApi:_parseIsoDate(iso)
    if not iso then return nil end
    
    -- Match "2026-01-31T15:13:56-05:00" or "2026-01-31T20:13:56Z"
    local y, m, d, h, min, s, off_sign, off_h, off_min = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)([Z%+%-])?(%d?%d?):?(%d?%d?)")
    
    if not y then return nil end
    
    -- Get base epoch (assumed UTC for calculation)
    local time = os.time({
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(min),
        sec = tonumber(s),
        isdst = false -- Use false to treat as UTC potentially
    })

    -- Adjust for timezone offset
    if off_sign == "+" then
        local offset_secs = (tonumber(off_h) or 0) * 3600 + (tonumber(off_min) or 0) * 60
        time = time - offset_secs
    elseif off_sign == "-" then
        local offset_secs = (tonumber(off_h) or 0) * 3600 + (tonumber(off_min) or 0) * 60
        time = time + offset_secs
    end
    
    -- Note: os.time returns local epoch. To get UTC epoch correctly in Lua:
    -- If we pass a table to os.time, it treats it as local time.
    -- But if we want to treat the table as UTC, we need to adjust.
    local utc_now = os.time(os.date("!*t"))
    local local_now = os.time(os.date("*t"))
    local diff = os.difftime(local_now, utc_now)
    
    return time - diff
end

function MTAApi:getStopMonitoring(stop_id)
    if not self.api_key or self.api_key == "" then
        logger.err("MTAApi: No API key set")
        return nil
    end

    local url = string.format(
        "http://bustime.mta.info/api/siri/stop-monitoring.json?key=%s&OperatorRef=MTA&MonitoringRef=%s",
        self.api_key,
        stop_id
    )
    
    local data = self:_makeRequest(url)
    if not data then return nil end
    
    local arrivals = {}
    local deliveries = data.Siri and data.Siri.ServiceDelivery and data.Siri.ServiceDelivery.StopMonitoringDelivery
    if not deliveries or #deliveries == 0 then return arrivals end
    
    local visits = deliveries[1].MonitoredStopVisit
    if not visits then return arrivals end
    
    -- Current time in UTC epoch
    local now = os.time(os.date("!*t"))
    
    for _, visit in ipairs(visits) do
        local journey = visit.MonitoredVehicleJourney
        if journey then
            local call = journey.MonitoredCall
            local expected_arrival = call and (call.ExpectedArrivalTime or call.AimedArrivalTime)
            local arrival_time = self:_parseIsoDate(expected_arrival)
            
            if arrival_time then
                local wait_time = math.max(0, math.floor(os.difftime(arrival_time, now) / 60))
                local stop_dist = ""
                local stops_away = nil
                
                if call.Extensions and call.Extensions.Distances then
                   stop_dist = call.Extensions.Distances.PresentableDistance or ""
                   stops_away = call.Extensions.Distances.StopsFromStop
                end

                table.insert(arrivals, {
                    line_name = journey.PublishedLineName or "Unknown",
                    destination = journey.DestinationName or "Unknown",
                    wait_time = wait_time,
                    distance = stop_dist,
                    stops_away = stops_away,
                    arrival_time = arrival_time
                })
            end
        end
    end
    
    table.sort(arrivals, function(a, b) return a.wait_time < b.wait_time end)
    return arrivals
end

return MTAApi
