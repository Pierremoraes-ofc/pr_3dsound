# pr_3dsound — v4.0.0 custom

Resource de áudio 3D para FiveM com arquivos locais, URLs diretas, YouTube, SoundCloud, attach em entities, oclusão e streaming dinâmico por proximidade.

## O que foi corrigido nesta build

- **URL direta com HRTF real**: `PlayUrlPos` e `PlayUrlAttached` usam `HTMLAudioElement -> MediaElementSource -> PannerNode(HRTF) -> low-pass -> Gain` quando o host permite CORS.
- **Fallback seguro**: se a URL direta não puder ser roteada pelo Web Audio, a resource tenta reproduzir via HTML5/Howler. Nesse fallback há distância/oclusão, mas não HRTF verdadeiro.
- **Emitters persistentes**: o servidor mantém o estado dos sons posicionais e decide dinamicamente quem deve ouvi-los.
- **Late join / reentrada no raio**: quem entra depois recebe o som automaticamente com o timestamp correspondente.
- **Attach persistente**: o servidor acompanha o `Network ID`; o client tenta resolver novamente a entity quando ela entra no scope do OneSync.
- **Histerese de proximidade**: reduz play/stop repetitivo quando o player fica na borda do raio.
- **Índices server-side separados**: sons criados pelo servidor usam IDs internos acima de `100000`, evitando colisão com sons locais criados no client.
- **Estado autoritativo**: pause, resume, volume, distância, loop e timestamp são mantidos no servidor para novos listeners.
- **Oclusão melhorada**: URLs diretas 3D recebem low-pass real além da redução de volume.
- **Eventos protegidos**: clients não podem assumir ou controlar sons de outros scripts; broadcast vindo do client exige ACE.
- **Comandos de teste desabilitados por padrão**.

## Instalação

1. Coloque a pasta `pr_3dsound` em `resources`.
2. Adicione ao `server.cfg`:

```cfg
ensure pr_3dsound
```

3. Para produção, deixe `client/test_commands.lua` comentado no `fxmanifest.lua`.

## Uso recomendado: server-side

### Som 3D fixo

```lua
exports['pr_3dsound']:PlayUrlPos(
    -1,
    'radio_praca',
    'https://seu-cdn.com/audio/radio.mp3',
    0.8,
    vector3(215.0, -810.0, 30.0),
    45.0,
    true
)
```

### Som 3D preso a veículo

```lua
local netId = NetworkGetNetworkIdFromEntity(vehicle)

exports['pr_3dsound']:PlayUrlAttached(
    -1,
    'som_carro_' .. netId,
    'https://seu-cdn.com/audio/musica.mp3',
    0.8,
    netId,
    35.0,
    true
)
```

O `-1` significa emitter compartilhado. Qualquer jogador elegível que entrar no raio recebe o som. Se você passar um `source` específico, somente esse player será elegível.

### Arquivo local em `html/sounds/`

```lua
exports['pr_3dsound']:Play(
    vector3(100.0, 200.0, 30.0),
    'pr-wep/pistola.ogg',
    1.0,
    50.0,
    'tiro_01',
    nil,
    false
)
```

### Controles

```lua
exports['pr_3dsound']:Pause('radio_praca')
exports['pr_3dsound']:Resume('radio_praca')
exports['pr_3dsound']:SetVolume('radio_praca', 0.5)
exports['pr_3dsound']:SetDistance('radio_praca', 60.0)
exports['pr_3dsound']:SetTimestamp('radio_praca', 25.0)
exports['pr_3dsound']:SetLoop('radio_praca', true)
exports['pr_3dsound']:Stop('radio_praca')
```

## CORS: necessário para URL 3D real

Para HRTF verdadeiro em uma URL direta, o servidor/CDN que hospeda o áudio precisa aceitar CORS. O ideal é servir algo como:

```http
Access-Control-Allow-Origin: *
```

ou permitir explicitamente a origem usada pela NUI.

Sem CORS, a resource tenta fallback para reprodução compatível. O áudio ainda pode tocar com distância/oclusão, mas sem panning HRTF real.

## YouTube e SoundCloud

YouTube e SoundCloud continuam usando iframe/widget. O browser não permite capturar o áudio cross-origin desses players e conectá-lo ao `PannerNode`.

Portanto:

- URL direta: **HRTF real quando CORS permite**.
- YouTube/SoundCloud: **distância + volume + oclusão simulada**, sem HRTF real.

Para caixas de som, carros, rádios e ambientes onde o posicionamento importa, prefira uma URL direta para `.mp3`, `.ogg`, `.weba` ou um stream compatível.

## Streams ao vivo

Streams live normalmente não são seekable. Quando um player entra novamente no raio, ele abre o ponto atual disponibilizado pelo stream. Arquivos normais seekable tentam sincronizar usando o timestamp mantido pelo servidor.

## Segurança

A forma recomendada de controlar áudio compartilhado é por **exports server-side**.

Eventos client -> server que criam som continuam existindo para compatibilidade, mas:

- sem permissão especial, o som fica restrito ao próprio player;
- um client só pode controlar sons que ele próprio criou;
- um client não pode sobrescrever um ID pertencente a outro som;
- broadcast vindo do client exige ACE `pr_3dsound.broadcast`.

Para habilitar broadcast client-side somente para um administrador/testador:

```cfg
add_ace identifier.license:SUA_LICENSE pr_3dsound.broadcast allow
```

Não conceda essa ACE para jogadores comuns.

## Comandos de teste

`client/test_commands.lua` continua incluído no pacote, mas está comentado no `fxmanifest.lua`.

Para testar temporariamente:

1. descomente `client/test_commands.lua`;
2. conceda `pr_3dsound.broadcast` ao seu player se quiser que os testes transmitam para outros players;
3. reinicie a resource;
4. desabilite novamente em produção.

## Observações

- Attach em veículos/objects/peds usa `Network ID`.
- O client atualiza a posição do `PannerNode` conforme a entity se move.
- Emitters attachados respeitam o routing bucket da entity quando essa informação está disponível no servidor.
- A atenuação de distância continua calculada no Lua; o `PannerNode` é usado principalmente para espacialização HRTF, evitando dupla atenuação.
