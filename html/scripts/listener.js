/**
 * pr_3dsound — listener.js  v2.0
 * Recebe todas as mensagens NUI vindas do client.lua e delega ao SoundPlayer.
 */

'use strict';

window.addEventListener('message', function (event) {
    var d = event.data;
    if (!d || !d.type) return;

    var sp = window.SoundPlayer;
    var i  = d.soundIndex;

    switch (d.type) {

        // ── Arquivo local ──────────────────────────────────────────────────────
        case 'play':
            sp.play(i, d.file, d.volume, d.pos || null, d.loop || false);
            break;

        // ── URL 2D (stream / YouTube / SoundCloud) ────────────────────────────
        case 'playUrl':
            sp.playUrl(i, d.url, d.volume, d.loop || false, d.options || {});
            break;

        // ── URL 3D posicional ─────────────────────────────────────────────────
        case 'playUrlPos':
            sp.playUrlPos(i, d.url, d.volume, d.pos, d.loop || false, d.options || {});
            break;

        // ── Atualização de posição / volume do listener (loop 3D) ─────────────
        case 'updateVolume':
            sp.updateVolume(i, d.volume, d.playerPos, d.camDir);
            break;

        // ── Controles básicos ─────────────────────────────────────────────────
        case 'pause':           sp.pause(i);                              break;
        case 'resume':          sp.resume(i);                             break;
        case 'stop':            sp.stop(i);                               break;
        case 'updateCoords':    sp.updateCoords(i, d.pos);                break;

        // ── Volume ────────────────────────────────────────────────────────────
        case 'setVolume':       sp.setVolume(i, d.volume);                break;
        case 'setVolumeMax':    sp.setVolumeMax(i, d.volume);             break;

        // ── Parâmetros ────────────────────────────────────────────────────────
        case 'setDistance':     sp.setDistance(i, d.distance);            break;
        case 'setLoop':         sp.setLoop(i, d.loop);                    break;
        case 'setTimestamp':    sp.setTimestamp(i, d.time);               break;

        // ── Fade ──────────────────────────────────────────────────────────────
        case 'fadeIn':          sp.fadeIn(i, d.duration, d.volume);       break;
        case 'fadeOut':         sp.fadeOut(i, d.duration);                break;

        // ── Stop geral ────────────────────────────────────────────────────────
        case 'stopAll':         sp.stopAll();                              break;

        default:
            console.warn('[pr_3dsound] Mensagem desconhecida:', d.type);
    }
});
