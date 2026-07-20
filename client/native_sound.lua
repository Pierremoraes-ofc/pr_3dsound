--[[
    pr_3dsound native_sound.lua

    Native GTA/FiveM sound bridge inspired by mana_audio.
    This does not route native GTA audio through Howler/NUI, so it cannot apply
    WebAudio filters. It centralizes the native calls and adds validation,
    range checks, optional occlusion skipping, and entity netId support.
]]

local DEFAULT_TIMEOUT = 500
local DEFAULT_RANGE = 25.0

local function copyPayload(data)
    if type(data) ~= 'table' then return end

    local payload = {}
    local lastKey = nil
    while true do
        local ok, key, value = pcall(next, data, lastKey)
        if not ok or key == nil then break end
        if key ~= 'entity' then
            payload[key] = value
        end
        lastKey = key
    end

    return payload
end

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

local function normalizeAudioNames(audioName)
    if type(audioName) == 'string' and audioName ~= '' then
        return { audioName }
    end

    if type(audioName) ~= 'table' then return end

    local names = {}
    for i = 1, #audioName do
        local name = audioName[i]
        if type(name) == 'string' and name ~= '' then
            names[#names + 1] = name
        end
    end

    return #names > 0 and names or nil
end

local function getAudioRef(data)
    if data.audioRef ~= nil then return data.audioRef end
    if data.soundSet ~= nil then return data.soundSet end
    return 0
end

local function loadAudioBank(audioBank, timeout)
    if type(audioBank) ~= 'string' or audioBank == '' then
        return true
    end

    local remaining = tonumber(timeout) or DEFAULT_TIMEOUT
    while remaining > 0 do
        if RequestScriptAudioBank(audioBank, false) then
            return true
        end

        remaining = remaining - 1
        Wait(0)
    end

    return false
end

local function releaseAudioBank(audioBank)
    if type(audioBank) == 'string' and audioBank ~= '' then
        ReleaseNamedScriptAudioBank(audioBank)
    end
end

local function playerInRange(coords, range)
    if not coords or not range then return true end

    local playerCoords = GetEntityCoords(PlayerPedId())
    return #(playerCoords - coords) <= range
end

local function getEntityFromData(data)
    if type(data.entity) == 'number' and data.entity ~= 0 and DoesEntityExist(data.entity) then
        return data.entity
    end

    if type(data.netId) == 'number' and NetworkDoesEntityExistWithNetworkId(data.netId) then
        local entity = NetworkGetEntityFromNetworkId(data.netId)
        if entity ~= 0 and DoesEntityExist(entity) then
            return entity
        end
    end
end

local function getHeadCoords()
    local ped = PlayerPedId()
    local coords = GetEntityCoords(ped)
    return vector3(coords.x, coords.y, coords.z + 0.7)
end

local function isOccluded(soundCoords, ignoreEntity)
    if not soundCoords then return false end

    local ped = PlayerPedId()
    local ignore = ignoreEntity
    if not ignore or ignore == 0 then
        local vehicle = GetVehiclePedIsIn(ped, false)
        ignore = vehicle ~= 0 and vehicle or ped
    end

    local from = getHeadCoords()
    local handle = StartShapeTestLosProbe(
        from.x, from.y, from.z,
        soundCoords.x, soundCoords.y, soundCoords.z,
        1 + 2 + 8,
        ignore,
        4
    )

    local deadline = GetGameTimer() + 80
    while GetGameTimer() < deadline do
        local retval, hit = GetShapeTestResult(handle)
        if retval ~= 0 then
            return hit == 1
        end

        Wait(0)
    end

    return false
end

local function applyOcclusion(data, names, audioRef, soundCoords, ignoreEntity)
    if not data.occlusion then
        return names, audioRef
    end

    if not isOccluded(soundCoords, ignoreEntity) then
        return names, audioRef
    end

    if data.skipOnOcclusion or data.occlusionMode == 'mute' then
        return nil, audioRef
    end

    local occludedNames = normalizeAudioNames(data.occludedAudioName)
    if occludedNames then
        return occludedNames, data.occludedAudioRef or audioRef
    end

    return names, audioRef
end

local function playNative(data, playCallback)
    if type(data) ~= 'table' then return false end

    local names = normalizeAudioNames(data.audioName)
    if not names then return false end

    local audioRef = getAudioRef(data)
    if not loadAudioBank(data.audioBank, data.timeout) then
        return false
    end

    local retainSoundIds = data.retainSoundIds == true
    local soundIds = {}
    local interval = tonumber(data.interval or data.delayBetweenSounds) or 0

    for i = 1, #names do
        local soundId = GetSoundId()
        playCallback(soundId, names[i], audioRef)

        if retainSoundIds then
            soundIds[#soundIds + 1] = soundId
        else
            ReleaseSoundId(soundId)
        end

        if interval > 0 and i < #names then
            Wait(interval)
        end
    end

    releaseAudioBank(data.audioBank)

    if retainSoundIds then
        return soundIds
    end

    return true
end

---@param data table
local function playSound(data)
    return playNative(data, function(soundId, audioName, audioRef)
        PlaySoundFrontend(soundId, audioName, audioRef, false)
    end)
end

---@param data table
local function playSoundFromEntity(data)
    if type(data) ~= 'table' then return false end

    local entity = getEntityFromData(data)
    if not entity then return false end

    local coords = GetEntityCoords(entity)
    local range = tonumber(data.range or data.radius)
    if range and data.clientRangeCheck ~= false and not playerInRange(coords, range) then
        return false
    end

    local names = normalizeAudioNames(data.audioName)
    if not names then return false end

    local audioRef = getAudioRef(data)
    names, audioRef = applyOcclusion(data, names, audioRef, coords, entity)
    if not names then return false end

    local payload = copyPayload(data) or {}
    payload.audioName = names
    payload.audioRef = audioRef

    return playNative(payload, function(soundId, audioName, ref)
        PlaySoundFromEntity(soundId, audioName, entity, ref, false, false)
    end)
end

---@param data table
local function playSoundFromCoords(data)
    if type(data) ~= 'table' then return false end

    local coords = toVector3(data.coords)
    if not coords then return false end

    local range = tonumber(data.range or data.radius) or DEFAULT_RANGE
    if data.clientRangeCheck ~= false and not playerInRange(coords, range) then
        return false
    end

    local names = normalizeAudioNames(data.audioName)
    if not names then return false end

    local audioRef = getAudioRef(data)
    names, audioRef = applyOcclusion(data, names, audioRef, coords, nil)
    if not names then return false end

    local payload = copyPayload(data) or {}
    payload.audioName = names
    payload.audioRef = audioRef

    return playNative(payload, function(soundId, audioName, ref)
        PlaySoundFromCoord(soundId, audioName, coords.x, coords.y, coords.z, ref, false, range, false)
    end)
end

local function requestSharedSoundFromEntity(data)
    local payload = copyPayload(data)
    if not payload then return false end

    local entity = getEntityFromData(data)
    if not entity then return false end

    payload.netId = NetworkGetNetworkIdFromEntity(entity)
    payload.coords = packCoords(GetEntityCoords(entity))
    TriggerServerEvent('pr_3dsound:server:requestNativeSoundFromEntity', payload)
    return true
end

local function requestSharedSoundFromCoords(data)
    local payload = copyPayload(data)
    if not payload then return false end

    local coords = toVector3(payload.coords)
    if not coords then return false end

    payload.coords = packCoords(coords)
    TriggerServerEvent('pr_3dsound:server:requestNativeSoundFromCoords', payload)
    return true
end

exports('PlaySound', playSound)
exports('PlaySoundFromEntity', playSoundFromEntity)
exports('PlaySoundFromCoords', playSoundFromCoords)

exports('PlayNativeSound', playSound)
exports('PlayNativeSoundFromEntity', playSoundFromEntity)
exports('PlayNativeSoundFromCoords', playSoundFromCoords)

exports('PlayLocalNativeSound', playSound)
exports('PlayLocalNativeSoundFromEntity', playSoundFromEntity)
exports('PlayLocalNativeSoundFromCoords', playSoundFromCoords)

exports('PlaySharedNativeSoundFromEntity', requestSharedSoundFromEntity)
exports('PlaySharedNativeSoundFromCoords', requestSharedSoundFromCoords)

RegisterNetEvent('pr_3dsound:client:playNativeSound', playSound)
RegisterNetEvent('pr_3dsound:client:playNativeSoundFromEntity', playSoundFromEntity)
RegisterNetEvent('pr_3dsound:client:playNativeSoundFromCoords', playSoundFromCoords)
