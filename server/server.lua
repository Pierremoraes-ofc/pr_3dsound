--[[
    pr_3dsound — server.lua  v3.8
    ─────────────────────────────────────────────────────────────────────────────
    EXPORTS (use em outros scripts server-side):
      exports['pr_3dsound']:Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
      exports['pr_3dsound']:PlayUrl(source, name, url, volume, loop)
      exports['pr_3dsound']:PlayUrlPos(source, name, url, volume, coords, radius, loop)
      exports['pr_3dsound']:PlayUrlAttached(source, name, url, volume, entityNetId, radius, loop)
      exports['pr_3dsound']:AttachToEntity(uniqueId, entityNetId, offset)
      exports['pr_3dsound']:DetachEntity(uniqueId)
      exports['pr_3dsound']:Pause(uniqueId)
      exports['pr_3dsound']:Resume(uniqueId)
      exports['pr_3dsound']:Stop(uniqueId)
      exports['pr_3dsound']:StopAll()
      exports['pr_3dsound']:UpdateCoords(uniqueId, coords)
      exports['pr_3dsound']:SetVolume(uniqueId, volume)
      exports['pr_3dsound']:SetVolumeMax(uniqueId, volume)
      exports['pr_3dsound']:SetDistance(uniqueId, dist)
      exports['pr_3dsound']:SetLoop(uniqueId, loopVal)
      exports['pr_3dsound']:SetTimestamp(uniqueId, time)
      exports['pr_3dsound']:FadeIn(uniqueId, duration, targetVolume)
      exports['pr_3dsound']:FadeOut(uniqueId, duration)
      exports['pr_3dsound']:SoundExists(uniqueId)
      exports['pr_3dsound']:GetAllSounds()
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
            if #(pCoords - vector3(coords.x, coords.y, coords.z)) <= (radius or 50.0) then
                result[#result + 1] = tonumber(player)
            end
        end
    end
    return result
end

-- =============================================
--  PLAY — arquivo local (html/sounds/)
-- =============================================
--[[
    coords       : vector3 — posição do som no mundo
    soundName    : string  — nome do arquivo em html/sounds/ (ex: "pr-wep/pistola.ogg")
    volume       : number  — 0.0 a 1.0 (padrão 1.0)
    radius       : number  — raio de audição em metros (padrão 30.0)
    uniqueId     : string  — ID único para controlar o som depois (auto-gerado se nil)
    resourceName : string  — prefixo de subpasta (opcional, ex: "meu_script")
    loop         : bool    — repetir em loop (padrão false)
    retorna      : string  — uniqueId do som
]]
local function Play(coords, soundName, volume, radius, uniqueId, resourceName, loop)
    local index = GetNextIndex(uniqueId)
    if not uniqueId then uniqueId = tostring(index) end
    radius = radius or 30.0
    volume = volume or 1.0
    loop   = loop   or false

    local finalName = soundName
    if resourceName and resourceName ~= '' then
        finalName = resourceName .. '/' .. soundName
    end

    Sounds[index] = { uniqueId = uniqueId, coords = coords, radius = radius, isUrl = false, is2D = false }

    for _, player in ipairs(GetPlayersInRadius(coords, radius)) do
        TriggerClientEvent('pr_3dsound:client:play', player, index, coords, finalName, volume, radius, uniqueId, loop, nil)
    end
    return uniqueId
end

-- =============================================
--  PLAY URL — stream / YouTube / SoundCloud (2D global)
-- =============================================
--[[
    source  : number  — player source id, ou -1 para todos
    name    : string  — ID único do som
    url     : string  — URL do YouTube, SoundCloud ou stream direto
    volume  : number  — 0.0 a 1.0
    loop    : bool    — repetir em loop
    retorna : string  — name (uniqueId)
]]
local function PlayUrl(source, name, url, volume, loop)
    local index = GetNextIndex(name)
    Sounds[index] = { uniqueId = name, isUrl = true, is2D = true }

    local target = (source and source ~= -1) and source or -1
    TriggerClientEvent('pr_3dsound:client:playUrl', target, index, name, url, volume or 1.0, loop or false, {})
    return name
end

-- =============================================
--  PLAY URL POS — stream / YouTube / SoundCloud (3D posicional)
-- =============================================
--[[
    source  : number  — player source id, ou -1 para todos no raio
    name    : string  — ID único do som
    url     : string  — URL do YouTube, SoundCloud ou stream direto
    volume  : number  — 0.0 a 1.0
    coords  : vector3 — posição do som
    radius  : number  — raio de audição (padrão 50.0)
    loop    : bool    — repetir em loop
    retorna : string  — name (uniqueId)
]]
local function PlayUrlPos(source, name, url, volume, coords, radius, loop)
    local index = GetNextIndex(name)
    radius = radius or 50.0
    Sounds[index] = { uniqueId = name, coords = coords, radius = radius, isUrl = true, is2D = false }

    local targets = (source and source ~= -1) and { source } or GetPlayersInRadius(coords, radius)
    for _, player in ipairs(targets) do
        TriggerClientEvent('pr_3dsound:client:playUrlPos', player, index, name, url, volume or 1.0, coords, radius, loop or false, {}, nil)
    end
    return name
end

-- =============================================
--  PLAY URL ATTACHED — 3D attachado em entity (ex: música do carro)
-- =============================================
--[[
    Versão atômica de PlayUrlPos + AttachToEntity.
    Ideal para música de veículo: não tem delay de attach, o entity é
    passado junto com o play para o client processar tudo de uma vez.

    source      : number  — player source id, ou -1 para todos no raio
    name        : string  — ID único do som
    url         : string  — URL do YouTube, SoundCloud ou stream direto
    volume      : number  — 0.0 a 1.0
    entityNetId : number  — NetworkId do entity (VehToNet, ObjToNet, etc.)
    radius      : number  — raio de audição em metros (padrão 30.0)
    loop        : bool    — repetir em loop (padrão true para músicas)
    retorna     : string  — name (uniqueId)

    Comportamento de oclusão (automático no client):
      Player DENTRO do veículo                  → 100% do volume
      Player FORA, todas portas/janelas fechadas → 15%
      Player FORA, janela quebrada/aberta        → 35%
      Player FORA, 1 porta aberta               → 60%
      Player FORA, 2 portas abertas             → 70%
      Player FORA, 3+ portas abertas            → 100%
]]
local function PlayUrlAttached(source, name, url, volume, entityNetId, radius, loop)
    local index = GetNextIndex(name)
    radius = radius or 30.0
    loop   = (loop == nil) and true or loop  -- padrão true para músicas de veículo

    -- Pega as coords atuais do entity para distribuir para jogadores no raio
    local entity = NetworkGetEntityFromNetworkId(entityNetId)
    local coords = DoesEntityExist(entity) and GetEntityCoords(entity) or vector3(0, 0, 0)

    Sounds[index] = {
        uniqueId    = name,
        coords      = coords,
        radius      = radius,
        isUrl       = true,
        is2D        = false,
        attachNetId = entityNetId,
    }

    -- attachData é passado junto com o play — sem delay, sem race condition
    local attachData = { entityNetId = entityNetId, offset = { x = 0, y = 0, z = 0 } }

    local targets = (source and source ~= -1) and { source } or GetPlayersInRadius(coords, radius)
    for _, player in ipairs(targets) do
        TriggerClientEvent('pr_3dsound:client:playUrlPos', player, index, name, url, volume or 1.0, coords, radius, loop, {}, attachData)
    end
    return name
end

-- =============================================
--  ATTACH / DETACH
-- =============================================

--[[
    AttachToEntity — faz o som seguir um entity após já estar tocando.
    entityNetId : number       — NetworkId do entity
    offset      : {x, y, z}   — deslocamento relativo (opcional)
    retorna     : bool         — true se o som foi encontrado
]]
local function AttachToEntity(uniqueId, entityNetId, offset)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    Sounds[index].attachNetId = entityNetId
    TriggerClientEvent('pr_3dsound:client:attachToEntity', -1, index, entityNetId, offset or { x = 0, y = 0, z = 0 })
    return true
end

--[[
    DetachEntity — remove o attach; o som fica parado na última posição.
    retorna : bool — true se o som foi encontrado
]]
local function DetachEntity(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    Sounds[index].attachNetId = nil
    TriggerClientEvent('pr_3dsound:client:detachEntity', -1, index)
    return true
end

-- =============================================
--  CONTROLES
-- =============================================

local function Pause(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:pause', -1, index)
    return true
end

local function Resume(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:resume', -1, index)
    return true
end

local function Stop(uniqueId)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    Sounds[index] = nil
    TriggerClientEvent('pr_3dsound:client:stop', -1, index)
    return true
end

local function StopAll()
    for k, _ in pairs(Sounds) do
        TriggerClientEvent('pr_3dsound:client:stop', -1, k)
    end
    Sounds = {}
end

local function UpdateCoords(uniqueId, coords)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    Sounds[index].coords = coords
    TriggerClientEvent('pr_3dsound:client:updateCoords', -1, index, coords)
    return true
end

local function SetVolume(uniqueId, volume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:setVolume', -1, index, volume)
    return true
end

local function SetVolumeMax(uniqueId, volume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:setVolumeMax', -1, index, volume)
    return true
end

local function SetDistance(uniqueId, dist)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    Sounds[index].radius = dist
    TriggerClientEvent('pr_3dsound:client:setDistance', -1, index, dist)
    return true
end

local function SetLoop(uniqueId, loopVal)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:setLoop', -1, index, loopVal)
    return true
end

local function SetTimestamp(uniqueId, time)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:setTimestamp', -1, index, time)
    return true
end

local function FadeIn(uniqueId, duration, targetVolume)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:fadeIn', -1, index, duration or 1000, targetVolume or 1.0)
    return true
end

local function FadeOut(uniqueId, duration)
    local index = GetIndexByUniqueId(uniqueId)
    if not index then return false end
    TriggerClientEvent('pr_3dsound:client:fadeOut', -1, index, duration or 1000)
    return true
end

local function SoundExists(uniqueId)
    return GetIndexByUniqueId(uniqueId) ~= nil
end

--[[
    GetAllSounds — retorna tabela com todos os sons ativos e seus metadados.
    Útil para painel admin ou sincronização de estado.
    retorna : table — { [uniqueId] = { coords, radius, isUrl, is2D, attachNetId } }
]]
local function GetAllSounds()
    local result = {}
    for _, v in pairs(Sounds) do
        result[v.uniqueId] = {
            coords      = v.coords,
            radius      = v.radius,
            isUrl       = v.isUrl,
            is2D        = v.is2D,
            attachNetId = v.attachNetId,
        }
    end
    return result
end

-- =============================================
--  EXPORTS
-- =============================================

exports('Play',              Play)
exports('PlayUrl',           PlayUrl)
exports('PlayUrlPos',        PlayUrlPos)
exports('PlayUrlAttached',   PlayUrlAttached)
exports('AttachToEntity',    AttachToEntity)
exports('DetachEntity',      DetachEntity)
exports('Pause',             Pause)
exports('Resume',            Resume)
exports('Stop',              Stop)
exports('StopAll',           StopAll)
exports('UpdateCoords',      UpdateCoords)
exports('SetVolume',         SetVolume)
exports('SetVolumeMax',      SetVolumeMax)
exports('SetDistance',       SetDistance)
exports('SetLoop',           SetLoop)
exports('SetTimestamp',      SetTimestamp)
exports('FadeIn',            FadeIn)
exports('FadeOut',           FadeOut)
exports('SoundExists',       SoundExists)
exports('GetAllSounds',      GetAllSounds)

-- =============================================
--  NET EVENTS (TriggerServerEvent de qualquer client)
-- =============================================

RegisterNetEvent('pr_3dsound:server:play',              function(coords, soundName, volume, radius, uniqueId, resourceName, loop) Play(coords, soundName, volume, radius, uniqueId, resourceName, loop) end)
RegisterNetEvent('pr_3dsound:server:playUrl',           function(name, url, volume, loop)                       PlayUrl(source, name, url, volume, loop) end)
RegisterNetEvent('pr_3dsound:server:playUrlPos',        function(name, url, volume, coords, radius, loop)       PlayUrlPos(source, name, url, volume, coords, radius, loop) end)
RegisterNetEvent('pr_3dsound:server:playUrlAttached',   function(name, url, volume, entityNetId, radius, loop)  PlayUrlAttached(source, name, url, volume, entityNetId, radius, loop) end)
RegisterNetEvent('pr_3dsound:server:attachSoundToEntity', function(name, url, volume, entityNetId, radius, loop)
    local entity = NetworkGetEntityFromNetworkId(entityNetId)
    local coords = DoesEntityExist(entity) and GetEntityCoords(entity) or vector3(0, 0, 0)
    PlayUrlAttached(source, name, url, volume, entityNetId, radius, loop)
end)
RegisterNetEvent('pr_3dsound:server:attachToEntity',    function(uniqueId, entityNetId, offset)                 AttachToEntity(uniqueId, entityNetId, offset) end)
RegisterNetEvent('pr_3dsound:server:detachEntity',      function(uniqueId)                                      DetachEntity(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:pause',             function(uniqueId)                                      Pause(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:resume',            function(uniqueId)                                      Resume(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:stop',              function(uniqueId)                                      Stop(uniqueId) end)
RegisterNetEvent('pr_3dsound:server:stopAll',           function()                                              StopAll() end)
RegisterNetEvent('pr_3dsound:server:updateCoords',      function(uniqueId, coords)                              UpdateCoords(uniqueId, coords) end)
RegisterNetEvent('pr_3dsound:server:setVolume',         function(uniqueId, volume)                              SetVolume(uniqueId, volume) end)
RegisterNetEvent('pr_3dsound:server:setVolumeMax',      function(uniqueId, volume)                              SetVolumeMax(uniqueId, volume) end)
RegisterNetEvent('pr_3dsound:server:setDistance',       function(uniqueId, dist)                                SetDistance(uniqueId, dist) end)
RegisterNetEvent('pr_3dsound:server:setLoop',           function(uniqueId, loopVal)                             SetLoop(uniqueId, loopVal) end)
RegisterNetEvent('pr_3dsound:server:setTimestamp',      function(uniqueId, time)                                SetTimestamp(uniqueId, time) end)
RegisterNetEvent('pr_3dsound:server:fadeIn',            function(uniqueId, dur, vol)                            FadeIn(uniqueId, dur, vol) end)
RegisterNetEvent('pr_3dsound:server:fadeOut',           function(uniqueId, dur)                                 FadeOut(uniqueId, dur) end)
