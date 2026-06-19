--[[
    pr_3dsound native_sound.lua

    Server bridge for native GTA/FiveM sounds. Exports are compatible with the
    mana_audio style while also exposing explicit PlayNative* aliases.
]]

local DEFAULT_RANGE = 25.0
local MAX_CLIENT_RADIUS = 80.0
local MAX_CLIENT_SOURCE_DISTANCE = 80.0
local CLIENT_REQUEST_COOLDOWN = 250
local clientRequestCooldown = {}

local function toVector3(value)
    if type(value) == 'vector3' then
        return value
    end

    if type(value) == 'table' and value.x and value.y and value.z then
        return vector3(value.x + 0.0, value.y + 0.0, value.z + 0.0)
    end
end

local function packCoords(coords)
    if not coords then return end
    return { x = coords.x, y = coords.y, z = coords.z }
end

local function copyPayload(data)
    if type(data) ~= 'table' then return end

    local payload = {}
    for key, value in pairs(data) do
        if key ~= 'entity' then
            payload[key] = value
        end
    end

    if payload.range == nil and payload.radius ~= nil then
        payload.range = payload.radius
    end

    return payload
end

local function clampClientRange(value)
    local range = tonumber(value) or DEFAULT_RANGE
    if range < 1.0 then return 1.0 end
    if range > MAX_CLIENT_RADIUS then return MAX_CLIENT_RADIUS end
    return range
end

local function allowClientRequest(src)
    local now = GetGameTimer()
    local last = clientRequestCooldown[src] or 0
    if now - last < CLIENT_REQUEST_COOLDOWN then
        return false
    end

    clientRequestCooldown[src] = now
    return true
end

local function isNearRequestSource(src, coords)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then return false end

    local pedCoords = GetEntityCoords(ped)
    return #(pedCoords - coords) <= MAX_CLIENT_SOURCE_DISTANCE
end

local function getPlayersInRadius(coords, radius)
    local targets = {}
    local center = toVector3(coords)
    if not center then return targets end

    radius = tonumber(radius) or DEFAULT_RANGE

    for _, player in ipairs(GetPlayers()) do
        local src = tonumber(player)
        local ped = src and GetPlayerPed(src)
        if ped and ped ~= 0 then
            local playerCoords = GetEntityCoords(ped)
            if #(playerCoords - center) <= radius then
                targets[#targets + 1] = src
            end
        end
    end

    return targets
end

local function normalizeTarget(target)
    if target == nil then return -1 end
    if type(target) == 'table' then return target end
    return tonumber(target) or -1
end

local function triggerTargets(eventName, target, payload)
    target = normalizeTarget(target)

    if type(target) == 'table' then
        for _, src in pairs(target) do
            src = tonumber(src)
            if src then
                TriggerClientEvent(eventName, src, payload)
            end
        end
        return true
    end

    TriggerClientEvent(eventName, target, payload)
    return true
end

local function resolveEntityPayload(data)
    local payload = copyPayload(data)
    if not payload then return end

    local entity = data.entity
    if (not entity or entity == 0) and type(data.netId) == 'number' then
        entity = NetworkGetEntityFromNetworkId(data.netId)
    end

    if not entity or entity == 0 or not DoesEntityExist(entity) then
        return
    end

    payload.netId = payload.netId or NetworkGetNetworkIdFromEntity(entity)
    payload.coords = payload.coords or packCoords(GetEntityCoords(entity))

    return payload
end

local function unpackTargetAndData(first, second)
    if second ~= nil then
        return first, second
    end

    return -1, first
end

---@param first table|number Native payload, or target when second is provided.
---@param second? table Native payload.
local function playSound(first, second)
    local target, data = unpackTargetAndData(first, second)
    local payload = copyPayload(data)
    if not payload then return false end

    return triggerTargets('pr_3dsound:client:playNativeSound', target, payload)
end

---@param first table|number Native payload, or target when second is provided.
---@param second? table Native payload.
local function playSoundFromEntity(first, second)
    local target, data = unpackTargetAndData(first, second)
    local payload = resolveEntityPayload(data)
    if not payload or not payload.netId then return false end

    if normalizeTarget(target) == -1 and payload.coords then
        target = getPlayersInRadius(payload.coords, payload.range or payload.radius)
    end

    return triggerTargets('pr_3dsound:client:playNativeSoundFromEntity', target, payload)
end

---@param first table|number Native payload, or target when second is provided.
---@param second? table Native payload.
local function playSoundFromCoords(first, second)
    local target, data = unpackTargetAndData(first, second)
    local payload = copyPayload(data)
    if not payload then return false end

    local coords = toVector3(payload.coords)
    if not coords then return false end

    payload.coords = packCoords(coords)
    payload.range = tonumber(payload.range or payload.radius) or DEFAULT_RANGE

    if normalizeTarget(target) == -1 then
        target = getPlayersInRadius(coords, payload.range)
    end

    return triggerTargets('pr_3dsound:client:playNativeSoundFromCoords', target, payload)
end

exports('PlaySound', playSound)
exports('PlaySoundFromEntity', playSoundFromEntity)
exports('PlaySoundFromCoords', playSoundFromCoords)

exports('PlayNativeSound', playSound)
exports('PlayNativeSoundFromEntity', playSoundFromEntity)
exports('PlayNativeSoundFromCoords', playSoundFromCoords)

exports('PlaySoundForAll', function(data)
    return playSound(-1, data)
end)

exports('PlaySoundFromEntityForAll', function(data)
    return playSoundFromEntity(-1, data)
end)

exports('PlaySoundFromCoordsForAll', function(data)
    return playSoundFromCoords(-1, data)
end)

exports('PlayNativeSoundForAll', function(data)
    return playSound(-1, data)
end)

exports('PlayNativeSoundFromEntityForAll', function(data)
    return playSoundFromEntity(-1, data)
end)

exports('PlayNativeSoundFromCoordsForAll', function(data)
    return playSoundFromCoords(-1, data)
end)

RegisterNetEvent('pr_3dsound:server:requestNativeSoundFromEntity', function(data)
    local src = source
    if not allowClientRequest(src) then return end

    local payload = resolveEntityPayload(data)
    if not payload then
        payload = copyPayload(data)
        if not payload then return end

        local fallbackCoords = toVector3(payload.coords)
        if not fallbackCoords or not isNearRequestSource(src, fallbackCoords) then return end

        payload.coords = packCoords(fallbackCoords)
        payload.range = clampClientRange(payload.range or payload.radius)
        playSoundFromCoords(-1, payload)
        return
    end

    local coords = toVector3(payload.coords)
    if not coords or not isNearRequestSource(src, coords) then return end

    payload.range = clampClientRange(payload.range or payload.radius)
    playSoundFromEntity(-1, payload)
end)

RegisterNetEvent('pr_3dsound:server:requestNativeSoundFromCoords', function(data)
    local src = source
    if not allowClientRequest(src) then return end

    local payload = copyPayload(data)
    if not payload then return end

    local coords = toVector3(payload.coords)
    if not coords or not isNearRequestSource(src, coords) then return end

    payload.coords = packCoords(coords)
    payload.range = clampClientRange(payload.range or payload.radius)
    playSoundFromCoords(-1, payload)
end)
