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
    local ok_req, code, headers = http.request(request)
    socketutil:reset_timeout()
    
    if not ok_req then
        logger.err("MTAApi: Network request failed", code)
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

-- Flexible ISO 8601 date parsing
function MTAApi:_parseIsoToUtcSeconds(iso)
    if not iso then return nil end
    local y, m, d, h, min, s, tz = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)(.*)")
    if not y then return nil end
    
    local t = os.time({
        year = tonumber(y), month = tonumber(m), day = tonumber(d),
        hour = tonumber(h), min = tonumber(min), sec = tonumber(s),
        isdst = false
    })

    local now = os.time()
    local utc_now = os.time(os.date("!*t", now))
    local local_to_utc_offset = os.difftime(now, utc_now)

    local string_offset = 0
    if tz:match("Z") then
        string_offset = 0
    else
        local sign, off_h, off_min = tz:match("([%+%-])(%d%d):?(%d%d)")
        if sign then
            string_offset = tonumber(off_h) * 3600 + (tonumber(off_min) or 0) * 60
            if sign == "+" then
                string_offset = -string_offset
            else
                string_offset = string_offset
            end
        end
    end
    
    return t + string_offset - local_to_utc_offset
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
    
    local siri = data.Siri
    if not siri then return nil end
    
    local server_time_str = siri.ServiceDelivery and siri.ServiceDelivery.ResponseTimestamp
    local server_now_utc = self:_parseIsoToUtcSeconds(server_time_str)
    
    if not server_now_utc then
        server_now_utc = os.time(os.date("!*t"))
    end

    local arrivals = {}
    local deliveries = siri.ServiceDelivery and siri.ServiceDelivery.StopMonitoringDelivery
    if not deliveries or #deliveries == 0 then return arrivals end
    
    local visits = deliveries[1].MonitoredStopVisit
    if not visits then return arrivals end
    
    for _, visit in ipairs(visits) do
        local journey = visit.MonitoredVehicleJourney
        if journey then
            local call = journey.MonitoredCall
            if call then
                local expected_str = call.ExpectedArrivalTime or call.AimedArrivalTime
                local arrival_utc = self:_parseIsoToUtcSeconds(expected_str)
                
                if arrival_utc then
                    local wait_time = math.max(0, math.floor(os.difftime(arrival_utc, server_now_utc) / 60))
                    local stop_dist = ""
                    local stops_away = nil
                    
                    if call.Extensions and call.Extensions.Distances then
                       stop_dist = call.Extensions.Distances.PresentableDistance or ""
                       stops_away = call.Extensions.Distances.StopsFromCall
                    end

                    table.insert(arrivals, {
                        line_name = journey.PublishedLineName or "Unknown",
                        destination = journey.DestinationName or "Unknown",
                        wait_time = wait_time,
                        distance = stop_dist,
                        stops_away = stops_away,
                        arrival_time = arrival_utc
                    })
                end
            end
        end
    end
    
    table.sort(arrivals, function(a, b) return a.wait_time < b.wait_time end)
    return arrivals
end

-- NEW: Current Weather via Open-Meteo (No key required)
function MTAApi:getCurrentWeather(lat, lon)
    lat = lat or 40.7128 -- Default NYC
    lon = lon or -74.0060
    local url = string.format("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current_weather=true", lat, lon)
    
    local data = self:_makeRequest(url)
    if data and data.current_weather then
        return data.current_weather.temperature
    end
    return nil
end

return MTAApi
