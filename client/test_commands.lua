--[[
    pr_3dsound — test_commands.lua  v3.8
    Comandos de teste via chat. REMOVA EM PRODUÇÃO!

    ╔══════════════════════════════════════════════════════════════════════╗
    ║  /play      <url> [vol] [raio]   → URL 3D na sua posição             ║
    ║  /play2d    <url> [vol]          → URL 2D global                     ║
    ║  /playfile  <arq> [vol] [raio]   → arquivo local 3D                  ║
    ║  /playcar   <url> [vol] [raio]   → URL 3D no veículo (auto-attach)   ║
    ║  /spause    <id>                 → pausar                            ║
    ║  /sresume   <id>                 → retomar                           ║
    ║  /sstop     <id>                 → parar                             ║
    ║  /svol      <id> <0-1>          → volume                             ║
    ║  /sdist     <id> <metros>       → raio                               ║
    ║  /sloop     <id> <on|off>       → loop                               ║
    ║  /sfade     <id> <in|out> [ms]  → fade                               ║
    ║  /smove     <id>                 → mover p/ sua posição              ║
    ║  /sattach   <url> <netId> [vol] [raio] → play + attach em entity      ║
    ║  /sdetach   <id>                 → remover attach                    ║
    ║  /sinfo     <id>                 → estado do som                     ║
    ║  /sstopall                       → parar tudo                        ║
    ║  /sound                          → lista de comandos                 ║
    ╚══════════════════════════════════════════════════════════════════════╝
]]

local pr = exports['pr_3dsound']

local function genId()
    return ('snd_%d_%d'):format(GetGameTimer() % 99999, math.random(100, 999))
end

local function msg(text, r, g, b)
    TriggerEvent('chat:addMessage', {
        color = { r or 0, g or 200, b or 255 }, multiline = true, args = { '[3DSnd]', text }
    })
end
local function ok(t)  msg(t,  60, 220, 100) end
local function err(t) msg(t, 255,  80,  80) end
local function inf(t) msg(t,  80, 180, 255) end

local function checkId(id)
    if not id then err('Informe o ID do som.'); return false end
    if not pr:SoundExists(id) then err(('ID nao encontrado: ^3%s'):format(id)); return false end
    return true
end

-- ─── /play ───────────────────────────────────────────────────────────────────

RegisterCommand('play', function(source, args)
    local url    = args[1]
    local volume = tonumber(args[2]) or 0.8
    local radius = tonumber(args[3]) or 50.0
    if not url then err('Uso: /play <url> [vol] [raio]'); return end

    local id = genId()
    TriggerServerEvent('pr_3dsound:server:playUrlPos', id, url, volume, GetEntityCoords(PlayerPedId()), radius, false)

    ok('|>> Som 3D iniciado!')
    ok(('    ID  : ^3%s'):format(id))
    inf(('    URL : %s'):format(url))
    inf(('    Vol : %.2f  |  Raio: %.0f m'):format(volume, radius))
end, false)

-- ─── /play2d ─────────────────────────────────────────────────────────────────

RegisterCommand('play2d', function(source, args)
    local url    = args[1]
    local volume = tonumber(args[2]) or 0.8
    if not url then err('Uso: /play2d <url> [vol]'); return end

    local id = genId()
    TriggerServerEvent('pr_3dsound:server:playUrl', id, url, volume, false)

    ok('|>> Som 2D global iniciado!')
    ok(('    ID  : ^3%s'):format(id))
    inf(('    URL : %s'):format(url))
end, false)

-- ─── /playfile ───────────────────────────────────────────────────────────────

RegisterCommand('playfile', function(source, args)
    local file   = args[1]
    local volume = tonumber(args[2]) or 1.0
    local radius = tonumber(args[3]) or 30.0
    if not file then err('Uso: /playfile <arquivo> [vol] [raio]'); return end

    local id = genId()
    TriggerServerEvent('pr_3dsound:server:play', GetEntityCoords(PlayerPedId()), file, volume, radius, id, nil, false)

    ok('|>> Arquivo local iniciado!')
    ok(('    ID : ^3%s'):format(id))
    inf(('    Arquivo: %s  |  Vol: %.2f  |  Raio: %.0f m'):format(file, volume, radius))
end, false)

-- ─── /playcar ────────────────────────────────────────────────────────────────
-- Usa PlayUrlAttached: atomicamente inicia o som já attachado ao veículo,
-- sem delay e sem race condition. O server calcula as coords do veículo.

RegisterCommand('playcar', function(source, args)
    local url    = args[1]
    local volume = tonumber(args[2]) or 0.8
    local radius = tonumber(args[3]) or 30.0
    if not url then err('Uso: /playcar <url> [vol] [raio]'); return end

    local ped     = PlayerPedId()
    local vehicle = GetVehiclePedIsIn(ped, false)
    if vehicle == 0 then err('Voce nao esta em um veiculo!'); return end

    local netId = VehToNet(vehicle)
    local id    = genId()

    -- PlayUrlAttached: play + attach atômico, loop=true por padrão para música
    TriggerServerEvent('pr_3dsound:server:playUrlAttached', id, url, volume, netId, radius, true)

    ok('|>> Musica do veiculo iniciada!')
    ok(('    ID    : ^3%s'):format(id))
    inf(('    URL   : %s'):format(url))
    inf(('    NetId : %d  |  Vol: %.2f  |  Raio: %.0f m'):format(netId, volume, radius))
    inf('    Oclusao automatica por porta/janela ativa.')
end, false)

-- ─── /spause ─────────────────────────────────────────────────────────────────

RegisterCommand('spause', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:pause', id)
    ok(('Pausado: ^3%s'):format(id))
end, false)

-- ─── /sresume ────────────────────────────────────────────────────────────────

RegisterCommand('sresume', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:resume', id)
    ok(('Retomado: ^3%s'):format(id))
end, false)

-- ─── /sstop ──────────────────────────────────────────────────────────────────

RegisterCommand('sstop', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:stop', id)
    ok(('Parado: ^3%s'):format(id))
end, false)

-- ─── /svol ───────────────────────────────────────────────────────────────────

RegisterCommand('svol', function(source, args)
    local id  = args[1]
    local vol = tonumber(args[2])
    if not checkId(id) then return end
    if not vol then err('Uso: /svol <id> <0.0 - 1.0>'); return end
    vol = math.max(0.0, math.min(1.0, vol))
    TriggerServerEvent('pr_3dsound:server:setVolume', id, vol)
    ok(('Volume de ^3%s^7 → %.2f'):format(id, vol))
end, false)

-- ─── /sdist ──────────────────────────────────────────────────────────────────

RegisterCommand('sdist', function(source, args)
    local id   = args[1]
    local dist = tonumber(args[2])
    if not checkId(id) then return end
    if not dist then err('Uso: /sdist <id> <metros>'); return end
    TriggerServerEvent('pr_3dsound:server:setDistance', id, dist)
    ok(('Raio de ^3%s^7 → %.0f m'):format(id, dist))
end, false)

-- ─── /sloop ──────────────────────────────────────────────────────────────────

RegisterCommand('sloop', function(source, args)
    local id  = args[1]
    local val = args[2]
    if not checkId(id) then return end
    if not val then err('Uso: /sloop <id> <on|off>'); return end
    local loopVal = (val == 'on' or val == '1' or val == 'true')
    TriggerServerEvent('pr_3dsound:server:setLoop', id, loopVal)
    ok(('Loop de ^3%s^7 → %s'):format(id, loopVal and 'ON' or 'OFF'))
end, false)

-- ─── /sfade ──────────────────────────────────────────────────────────────────

RegisterCommand('sfade', function(source, args)
    local id       = args[1]
    local dir      = args[2]
    local duration = tonumber(args[3]) or 2000
    if not checkId(id) then return end
    if not dir then err('Uso: /sfade <id> <in|out> [ms]'); return end
    if dir == 'in' then
        TriggerServerEvent('pr_3dsound:server:fadeIn', id, duration, 1.0)
        ok(('FadeIn ^3%s^7 em %d ms'):format(id, duration))
    elseif dir == 'out' then
        TriggerServerEvent('pr_3dsound:server:fadeOut', id, duration)
        ok(('FadeOut ^3%s^7 em %d ms'):format(id, duration))
    else
        err('use: in  ou  out')
    end
end, false)

-- ─── /smove ──────────────────────────────────────────────────────────────────

RegisterCommand('smove', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    local c = GetEntityCoords(PlayerPedId())
    TriggerServerEvent('pr_3dsound:server:updateCoords', id, c)
    ok(('Som ^3%s^7 movido para (%.1f, %.1f, %.1f)'):format(id, c.x, c.y, c.z))
end, false)

-- ─── /sattach ────────────────────────────────────────────────────────────────
-- Uso: /sattach <url> <netId> [vol] [raio]
-- Inicia um som 3D já attachado em qualquer entity via netId.
-- Sem race condition: play e attach são enviados juntos ao server.

RegisterCommand('sattach', function(source, args)
    local url    = args[1]
    local netId  = tonumber(args[2])
    local volume = tonumber(args[3]) or 0.8
    local radius = tonumber(args[4]) or 30.0

    if not url   then err('Uso: /sattach <url> <netId> [vol] [raio]'); return end
    if not netId then err('Uso: /sattach <url> <netId> [vol] [raio]'); return end

    local id = genId()

    TriggerServerEvent('pr_3dsound:server:attachSoundToEntity', id, url, volume, netId, radius, true)

    ok('|>> Som attachado iniciado!')
    ok(('    ID    : ^3%s'):format(id))
    inf(('    URL   : %s'):format(url))
    inf(('    NetId : %d  |  Vol: %.2f  |  Raio: %.0f m'):format(netId, volume, radius))
    inf('    Use ^3/sstop ' .. id .. '^7 para parar.')
end, false)

-- ─── /sdetach ────────────────────────────────────────────────────────────────

RegisterCommand('sdetach', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    TriggerServerEvent('pr_3dsound:server:detachEntity', id)
    ok(('Attach removido de ^3%s'):format(id))
end, false)

-- ─── /sinfo ──────────────────────────────────────────────────────────────────

RegisterCommand('sinfo', function(source, args)
    local id = args[1]
    if not checkId(id) then return end
    local info = pr:GetInfo(id)
    if not info then inf(('ID ^3%s^7 sem estado local (carregando?).'):format(id)); return end

    inf(('=== Info: ^3%s^7 ==='):format(id))
    inf(('  Playing: %s  Paused: %s  Loop: %s'):format(tostring(info.playing), tostring(info.paused), tostring(info.loop)))
    inf(('  Vol: %.2f  VolMax: %.2f  Raio: %.0f m'):format(info.vol or 0, info.maxVol or 0, info.dist or 0))
    if info.pos then inf(('  Pos: %.1f, %.1f, %.1f'):format(info.pos.x, info.pos.y, info.pos.z)) end
    if info.url then inf(('  URL: %s'):format(info.url)) end
    if info.attachEntity then inf(('  Attach: entity handle %d'):format(info.attachEntity)) end
    inf(('  Tipo: %s  |  isUrl: %s'):format(info.is2D and '2D global' or '3D posicional', tostring(info.isUrl)))
end, false)

-- ─── /sstopall ───────────────────────────────────────────────────────────────

RegisterCommand('sstopall', function()
    SendNUIMessage({ type = 'stopAll' })
    ok('Todos os sons parados localmente.')
end, false)

-- ─── /sound ──────────────────────────────────────────────────────────────────

RegisterCommand('sound', function()
    inf('======= pr_3dsound v3.8 =======')
    inf('^3/play      ^7<url> [vol] [raio]    → URL 3D na sua posição')
    inf('^3/play2d    ^7<url> [vol]           → URL 2D global')
    inf('^3/playfile  ^7<arq> [vol] [raio]    → arquivo local 3D')
    inf('^3/playcar   ^7<url> [vol] [raio]    → URL 3D no veículo (oclusão automática)')
    inf('^3/spause    ^7<id>                  → pausar')
    inf('^3/sresume   ^7<id>                  → retomar')
    inf('^3/sstop     ^7<id>                  → parar')
    inf('^3/svol      ^7<id> <0-1>           → volume')
    inf('^3/sdist     ^7<id> <metros>        → raio')
    inf('^3/sloop     ^7<id> <on|off>        → loop')
    inf('^3/sfade     ^7<id> <in|out> [ms]   → fade')
    inf('^3/smove     ^7<id>                  → mover p/ sua posição')
    inf('^3/sattach   ^7<url> <netId> [vol] [raio] → play + attach em entity')
    inf('^3/sdetach   ^7<id>                  → remover attach')
    inf('^3/sinfo     ^7<id>                  → ver estado')
    inf('^3/sstopall                          → parar tudo')
end, false)

AddEventHandler('playerSpawned', function()
    Citizen.Wait(3000)
    inf('pr_3dsound v3.8 ativo. ^3/sound^7 para ver os comandos.')
end)
