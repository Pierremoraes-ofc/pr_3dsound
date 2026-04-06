# pr_3dsound

> Sistema de som 3D para FiveM com oclusão por raycast, paredes, portas de veículo e portais MLO.
> 3D sound system for FiveM with raycast occlusion, walls, vehicle doors and MLO portals.

---

## 🇺🇸 English


<div align="center">

[![GitBook](https://img.shields.io/badge/📖_Documentação_Completa-GitBook-blue?style=for-the-badge)](https://pierremoraes.gitbook.io/home/fivem/pr-3d-sound)


</div>

### What it is

`pr_3dsound` is a 3D audio resource for FiveM servers. It plays positional sounds in the game world with distance attenuation and realistic acoustic occlusion, supporting local files, direct streams, YouTube and SoundCloud.

### Key features

- **Audio sources**: local `.ogg/.mp3/.weba` files, HTTP/HTTPS streams, YouTube (IFrame API) and SoundCloud (Widget API)
- **3D positioning**: volume attenuated by distance with per-sound configurable radius
- **Entity attach**: sound follows any entity (vehicle, ped, object) automatically
- **Raycast occlusion**: detects walls between player and sound source using two-frame `StartShapeTestLosProbe` to eliminate flickering
- **Vehicle occlusion (source)**: sound attached to a car leaks less when doors/windows are closed; player inside the same car always hears 100%
- **Vehicle occlusion (player)**: player inside their own car hears external sounds more muffled as windows/doors are closed
- **MLO portal occlusion**: detects if player and source are in different rooms of an interior and applies proportional muffling
- **Full control**: pause, resume, stop, volume, radius, loop, timestamp, fade in/out
- **YouTube no-delay**: starts muted to bypass CEF autoplay policy; unmutes automatically once playback is confirmed

### Installation

1. Copy the `pr_3dsound` folder to your server's `resources` directory
2. Add `ensure pr_3dsound` to `server.cfg`
3. Remove `client/test_commands.lua` from `fxmanifest.lua` in production

### Quick usage (server-side)

```lua
-- Vehicle music (automatic door/window occlusion)
exports['pr_3dsound']:PlayUrlAttached(source, 'car_music', url, 0.8, VehToNet(vehicle), 30.0, true)

-- Fixed 3D sound in the world
exports['pr_3dsound']:PlayUrlPos(-1, 'bar_sound', url, 0.7, coords, 40.0, true)

-- Global 2D sound (everyone hears)
exports['pr_3dsound']:PlayUrl(-1, 'announcement', url, 0.9, false)

-- Stop
exports['pr_3dsound']:Stop('car_music')
```

---

## Licença / License

MIT — use livre, atribuição apreciada.  
MIT — free to use, attribution appreciated.



## 🇧🇷 Português


<div align="center">

[![GitBook](https://img.shields.io/badge/📖_Documentação_Completa-GitBook-blue?style=for-the-badge)](https://pierremoraes.gitbook.io/home/fivem/pr-3d-sound)


</div>
### O que é

`pr_3dsound` é um recurso de áudio 3D para servidores FiveM. Ele reproduz sons posicionais no mundo do jogo com atenuação por distância e oclusão acústica realista, suportando arquivos locais, streams diretos, YouTube e SoundCloud.

### Recursos principais

- **Fontes de áudio**: arquivos `.ogg/.mp3/.weba` locais, streams HTTP/HTTPS, YouTube (IFrame API) e SoundCloud (Widget API)
- **Posicionamento 3D**: volume atenuado por distância com raio configurável por som
- **Attach em entity**: som segue qualquer entity (veículo, ped, objeto) automaticamente
- **Oclusão por raycast**: detecta paredes entre o player e a fonte de som usando `StartShapeTestLosProbe` em dois frames para eliminar oscilação
- **Oclusão de veículo (fonte)**: som attachado a um carro vaza menos quando as portas/janelas estão fechadas; o player dentro do mesmo carro sempre ouve 100%
- **Oclusão de veículo (player)**: player dentro do próprio carro ouve sons externos mais abafados conforme as janelas/portas estão fechadas
- **Oclusão por portais MLO**: detecta se player e fonte estão em rooms diferentes de um interior e aplica abafamento proporcional
- **Controle completo**: pause, resume, stop, volume, raio, loop, timestamp, fade in/out
- **YouTube sem delay**: inicia mutado para bypassar a política de autoplay do CEF; desmuta automaticamente ao confirmar reprodução

### Instalação

1. Copie a pasta `pr_3dsound` para o diretório `resources` do seu servidor
2. Adicione `ensure pr_3dsound` no `server.cfg`
3. Remova `client/test_commands.lua` do `fxmanifest.lua` em produção

### Uso rápido (server-side)

```lua
-- Música num veículo (oclusão automática por porta/janela)
exports['pr_3dsound']:PlayUrlAttached(source, 'musica_carro', url, 0.8, VehToNet(vehicle), 30.0, true)

-- Som 3D fixo no mundo
exports['pr_3dsound']:PlayUrlPos(-1, 'som_bar', url, 0.7, coords, 40.0, true)

-- Som 2D global (todos ouvem)
exports['pr_3dsound']:PlayUrl(-1, 'anuncio', url, 0.9, false)

-- Parar
exports['pr_3dsound']:Stop('musica_carro')
```

---
