--[[
    pr_3dsound — server.lua  v2.0
    Exports: Play, PlayUrl, PlayUrlPos, Pause, Resume, Stop, UpdateCoords,
             SetVolume, SetVolumeMax, SetDistance, SetLoop, SetTimestamp,
             FadeIn, FadeOut, SoundExists
]]

local Sounds = {}

-- =============================================
--  UTILIDADES INTERNAS
-- =============================================

local function GetNextIndex(uniqueId)
    local i = 1
    while Sounds[i] ~= nil do
        if Sounds[i].uniqueId == uniqueId then return i end
        i = i + 1
    end
    return i
end

local function GetIndexByUniqueId(uniqueId)
    for k, v in pairs(Sounds) do
        if v.uniqueId == uniqueId then return k end
    end
    return nil
end

local function GetPlayersInRadius(coords, radius)
    local result = {}
    for _, player in ipairs(GetPlayers()) do
        local ped = GetPlayerPed(tonumber(player))
        if ped and ped ~= 0 then
            local pCoords = GetEntityCoords(ped)
            local dist = #(pCoords - vector3(coords.x, coords.y, coords.z))
            if dist <= (radius or 50.0) then
                result[#result + 1] = tonumber(player)
            end
        end
    end
    return result
end

-- =============================================
--  PLAY — arquivo local (html/sounds/)
-- =============================================

local function Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
    local index = GetNextIndex(uniqueId)
    if uniqueId == nil then uniqueId = tostring(index) end
    radius  = radius  or 30.0
    volume  = volume  or 1.0
    loop    = loop    or false

    local finalName = soundName
    if resourceName and resourceName ~= '' then
        finalName = resourceName .. '/' .. soundName
    end

    Sounds[index] = { uniqueId = uniqueId, coords = coords, radius = radius, isUrl = false }

    for _, player in ipairs(GetPlayersInRadius(coords, radius)) do
        TriggerClientEvent('pr_3dsound:client:play', player, index, coords, finalName, volume, radius, uniqueId, loop)
    end
    return uniqueId
end

-- =============================================
--  PLAY URL — stream / YouTube / SoundCloud
-- =============================================

local function PlayUrl(source, name, url, volume, loop, options)
    -- source = player id ou -1 para todos
    local index = GetNextIndex(name)
    Sounds[index] = { uniqueId = name, isUrl = true, is2D = true }

    local target = (source and source ~= -1) and source or -1
    TriggerClientEvent('pr_3dsound:client:playUrl', target, index, name, url, volume or 1.0, loop or false, options or {})
    return name
end

local function PlayUrlPos(source, name, url, volume, coords, loop, options)
    local index  = GetNextIndex(name)
    local radius = 50.0
    Sounds[index] = { uniqueId = name, coords = coords, radius = radius, isUrl = true, is2D = false }

    local targets = (source and source ~= -1) and { source } or GetPlayersInRadius(coords, radius)
    for _, player in ipairs(targets) do
        TriggerClientEvent('pr_3dsound:client:playUrlPos', player, index, name, url, volume or 1.0, coords, radius, loop or false, options or {})
    end
    return name
end

-- =============================================
--  CONTROLES
-- =============================================

local function Pause(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:pause', -1, index)
end

local function Resume(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:resume', -1, index)
end

local function Stop(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    Sounds[index] = nil
    TriggerClientEvent('pr_3dsound:client:stop', -1, index)
end

local function UpdateCoords(uniqueId, coords)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    Sounds[index].coords = coords
    TriggerClientEvent('pr_3dsound:client:updateCoords', -1, index, coords)
end

local function SetVolume(uniqueId, volume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:setVolume', -1, index, volume)
end

local function SetVolumeMax(uniqueId, volume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:setVolumeMax', -1, index, volume)
end

local function SetDistance(uniqueId, dist)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    if Sounds[index] then Sounds[index].radius = dist end
    TriggerClientEvent('pr_3dsound:client:setDistance', -1, index, dist)
end

local function SetLoop(uniqueId, loopVal)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:setLoop', -1, index, loopVal)
end

local function SetTimestamp(uniqueId, time)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:setTimestamp', -1, index, time)
end

local function FadeIn(uniqueId, duration, targetVolume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:fadeIn', -1, index, duration or 1000, targetVolume or 1.0)
end

local function FadeOut(uniqueId, duration)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return end
    TriggerClientEvent('pr_3dsound:client:fadeOut', -1, index, duration or 1000)
end

local function SoundExists(uniqueId)
    return GetIndexByUniqueId(uniqueId) ~= nil
end

-- =============================================
--  EXPORTS
-- =============================================

exports('Play',          Play)
exports('PlayUrl',       PlayUrl)
exports('PlayUrlPos',    PlayUrlPos)
exports('Pause',         Pause)
exports('Resume',        Resume)
exports('Stop',          Stop)
exports('UpdateCoords',  UpdateCoords)
exports('SetVolume',     SetVolume)
exports('SetVolumeMax',  SetVolumeMax)
exports('SetDistance',   SetDistance)
exports('SetLoop',       SetLoop)
exports('SetTimestamp',  SetTimestamp)
exports('FadeIn',        FadeIn)
exports('FadeOut',       FadeOut)
exports('SoundExists',   SoundExists)

-- =============================================
--  NET EVENTS (outros scripts podem triggar via server event)
-- =============================================

RegisterNetEvent('pr_3dsound:server:play',         function(coords, soundName, volume, radius, uniqueId, resourceName, loop) Play(coords, soundName, volume, radius, uniqueId, resourceName, loop) end)
RegisterNetEvent('pr_3dsound:server:playUrl',      function(name, url, volume, loop)           PlayUrl(source, name, url, volume, loop) end)
RegisterNetEvent('pr_3dsound:server:playUrlPos',   function(name, url, volume, coords, loop)   PlayUrlPos(source, name, url, volume, coords, loop) end)
RegisterNetEvent('pr_3dsound:server:pause',        function(uniqueId)                          Pause(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:resume',       function(uniqueId)                          Resume(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:stop',         function(uniqueId)                          Stop(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:updateCoords', function(uniqueId, coords)                  UpdateCoords(uniqueId, coords) end)
RegisterNetEvent('pr_3dsound:server:setVolume',    function(uniqueId, volume)                  SetVolume(uniqueId, volume) end)
RegisterNetEvent('pr_3dsound:server:setDistance',  function(uniqueId, dist)                    SetDistance(uniqueId, dist) end)
RegisterNetEvent('pr_3dsound:server:setLoop',      function(uniqueId, loopVal)                 SetLoop(uniqueId, loopVal) end)
RegisterNetEvent('pr_3dsound:server:fadeIn',       function(uniqueId, dur, vol)                FadeIn(uniqueId, dur, vol) end)
RegisterNetEvent('pr_3dsound:server:fadeOut',      function(uniqueId, dur)                     FadeOut(uniqueId, dur) end)
