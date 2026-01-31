local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local ltn12 = require("ltn12")
local logger = require("logger")
local json = require("json")

local MTAApi = {
    api_key = nil -- Should be set via new() or setter
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

-- Helper to parse ISO 8601 date string to epoch time
function MTAApi:_parseIsoDate(iso)
    if not iso then return nil end
    local y, m, d, h, min, s = iso:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
    if y then
        return os.time({year=tonumber(y), month=tonumber(m), day=tonumber(d), hour=tonumber(h), min=tonumber(min), sec=tonumber(s)})
    end
    return nil
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
    if not deliveries or #deliveries == 0 then 
        logger.info("MTAApi: No deliveries found in SIRI response")
        return arrivals 
    end
    
    local visits = deliveries[1].MonitoredStopVisit
    if not visits then 
        logger.info("MTAApi: No monitored visits found for stop", stop_id)
        return arrivals 
    end
    
    local now = os.time()
    
    for _, visit in ipairs(visits) do
        local journey = visit.MonitoredVehicleJourney
        if journey then
            local call = journey.MonitoredCall
            local expected_arrival = call and (call.ExpectedArrivalTime or call.AimedArrivalTime)
            local arrival_time = self:_parseIsoDate(expected_arrival)
            
            if arrival_time then
                local wait_time = math.max(0, math.floor((arrival_time - now) / 60))
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
    logger.info("MTAApi: Parsed", #arrivals, "arrivals for stop", stop_id)
    
    return arrivals
end

return MTAApi
