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

-- Flexible ISO 8601 date parsing
-- Just extracts numbers, ignores everything else (.000, offsets, etc)
-- Since we compare server-time strings against arrival-time strings,
-- the relative difference is correct as long as they refer to the same timezone.
function MTAApi:_parseIsoDateToSeconds(iso)
    if not iso then return nil end
    local y, m, d, h, min, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if not y then return nil end
    
    return os.time({
        year = tonumber(y),
        month = tonumber(m),
        day = tonumber(d),
        hour = tonumber(h),
        min = tonumber(min),
        sec = tonumber(s)
    })
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
    
    -- Reference "NOW" from the server's own response timestamp
    local server_time_str = siri.ServiceDelivery and siri.ServiceDelivery.ResponseTimestamp
    local server_now = self:_parseIsoDateToSeconds(server_time_str)
    
    if not server_now then
        logger.warn("MTAApi: Could not parse server ResponseTimestamp", server_time_str)
        -- Fallback to device time if server time is missing
        server_now = os.time()
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
                local expected_arrival_str = call.ExpectedArrivalTime or call.AimedArrivalTime
                local arrival_seconds = self:_parseIsoDateToSeconds(expected_arrival_str)
                
                if arrival_seconds then
                    local wait_time = math.max(0, math.floor(os.difftime(arrival_seconds, server_now) / 60))
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
                        arrival_time = arrival_seconds
                    })
                else
                    logger.warn("MTAApi: Could not parse arrival time", expected_arrival_str)
                end
            end
        end
    end
    
    table.sort(arrivals, function(a, b) return a.wait_time < b.wait_time end)
    logger.info("MTAApi: Found", #arrivals, "arrivals for stop", stop_id)
    return arrivals
end

return MTAApi
