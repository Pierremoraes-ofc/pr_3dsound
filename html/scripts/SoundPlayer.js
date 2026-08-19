/**
 * pr_3dsound — SoundPlayer.js v4.0
 *
 * Direct HTTP(S) positional audio now uses an HTMLMediaElement routed through
 * the Web Audio API: MediaElementSource -> PannerNode(HRTF) -> BiquadFilter -> Gain.
 * This gives true left/right/front/back spatialization for direct URLs while
 * still allowing progressive/live media. The remote host MUST allow CORS.
 * If CORS/media loading fails, it falls back to Howler HTML5 audio so playback
 * still works, but that fallback cannot provide true HRTF.
 *
 * YouTube and SoundCloud remain iframe/widget based. Browser isolation prevents
 * routing their decoded audio into our WebAudio graph, so they use distance and
 * occlusion volume only.
 */

'use strict';

var players = {};
var ytReady = false;
var ytQueue = [];
var directCtx = null;

function clamp(v, lo, hi) {
    return Math.max(lo, Math.min(hi, Number(v) || 0));
}

function getDirectAudioContext() {
    if (typeof Howler !== 'undefined' && Howler.ctx) return Howler.ctx;
    if (directCtx) return directCtx;
    var Ctx = window.AudioContext || window.webkitAudioContext;
    if (!Ctx) return null;
    directCtx = new Ctx();
    return directCtx;
}

function setContextListener(ctx, playerPos, camDir) {
    if (!ctx || !ctx.listener) return;
    var l = ctx.listener;
    if (playerPos) {
        if (l.positionX) {
            setAudioParam(l.positionX, Number(playerPos.x) || 0, ctx);
            setAudioParam(l.positionY, Number(playerPos.y) || 0, ctx);
            setAudioParam(l.positionZ, Number(playerPos.z) || 0, ctx);
        } else if (l.setPosition) {
            l.setPosition(Number(playerPos.x) || 0, Number(playerPos.y) || 0, Number(playerPos.z) || 0);
        }
    }
    if (camDir) {
        if (l.forwardX) {
            setAudioParam(l.forwardX, Number(camDir.x) || 0, ctx);
            setAudioParam(l.forwardY, Number(camDir.y) || 1, ctx);
            setAudioParam(l.forwardZ, Number(camDir.z) || 0, ctx);
            setAudioParam(l.upX, 0, ctx);
            setAudioParam(l.upY, 0, ctx);
            setAudioParam(l.upZ, 1, ctx);
        } else if (l.setOrientation) {
            l.setOrientation(Number(camDir.x) || 0, Number(camDir.y) || 1, Number(camDir.z) || 0, 0, 0, 1);
        }
    }
}

function sanitize(value) {
    if (typeof DOMPurify !== 'undefined' && DOMPurify.sanitize) return DOMPurify.sanitize(value);
    return String(value || '');
}

function tryUnlockCtx() {
    var ctx = (typeof Howler !== 'undefined') ? Howler.ctx : null;
    if (ctx && ctx.state !== 'running' && ctx.resume) ctx.resume().catch(function () {});
    if (directCtx && directCtx.state !== 'running' && directCtx.resume) directCtx.resume().catch(function () {});
    if (!ctx && !directCtx) setTimeout(tryUnlockCtx, 200);
}

document.addEventListener('DOMContentLoaded', tryUnlockCtx);
['click', 'keydown', 'touchstart', 'mousedown'].forEach(function (ev) {
    document.addEventListener(ev, tryUnlockCtx, { once: true });
});
var _unlockInterval = setInterval(function () {
    var ctx = (typeof Howler !== 'undefined') ? Howler.ctx : null;
    if (!ctx) return;
    if (ctx.state === 'running') { clearInterval(_unlockInterval); return; }
    if (ctx.resume) ctx.resume().catch(function () {});
}, 500);

function detectUrlType(url) {
    if (!url) return 'local';
    if (/^https?:\/\//i.test(url)) {
        if (/youtube\.com\/watch|youtu\.be\//i.test(url)) return 'youtube';
        if (/soundcloud\.com\//i.test(url)) return 'soundcloud';
        return 'stream';
    }
    return 'local';
}

function extractYouTubeId(url) {
    var m = String(url).match(/(?:v=|youtu\.be\/)([A-Za-z0-9_-]{11})/);
    return m ? m[1] : null;
}

function newPlayer(extra) {
    return Object.assign({
        vol: 1,
        maxVol: 1,
        playing: false,
        paused: false,
        loop: false,
        pos: null,
        dist: 50,
        howl: null,
        spatial: null,
        ytPlayer: null,
        scWidget: null,
        _occlusionMult: 1.0,
        _lastDistVol: 1.0,
        _pendingSeek: null,
    }, extra || {});
}

function setAudioParam(param, value, ctx) {
    if (!param) return;
    if (param.setValueAtTime) param.setValueAtTime(value, ctx.currentTime);
    else param.value = value;
}

function setPannerPosition(panner, pos, ctx) {
    if (!panner || !pos) return;
    if (panner.positionX) {
        setAudioParam(panner.positionX, Number(pos.x) || 0, ctx);
        setAudioParam(panner.positionY, Number(pos.y) || 0, ctx);
        setAudioParam(panner.positionZ, Number(pos.z) || 0, ctx);
    } else if (panner.setPosition) {
        panner.setPosition(Number(pos.x) || 0, Number(pos.y) || 0, Number(pos.z) || 0);
    }
}

function applyMediaTimestamp(spatial, seconds, loop) {
    if (!spatial || !spatial.audio) return;
    var audio = spatial.audio;
    var t = Math.max(0, Number(seconds) || 0);
    try {
        if (loop && isFinite(audio.duration) && audio.duration > 0) t = t % audio.duration;
        if (audio.seekable && audio.seekable.length > 0) {
            var start = audio.seekable.start(0);
            var end = audio.seekable.end(audio.seekable.length - 1);
            if (isFinite(end) && end > start) t = Math.max(start, Math.min(t, Math.max(start, end - 0.05)));
        }
        audio.currentTime = t;
        spatial.pendingSeek = null;
    } catch (e) {
        spatial.pendingSeek = t;
    }
}

function createSpatialMedia(src, volume, loop, pos, onEnd, onError) {
    var ctx = getDirectAudioContext();
    if (!ctx) throw new Error('AudioContext unavailable');

    var audio = document.createElement('audio');
    audio.crossOrigin = 'anonymous';
    audio.preload = 'auto';
    audio.autoplay = false;
    audio.loop = !!loop;
    audio.src = sanitize(src);

    var source = ctx.createMediaElementSource(audio);
    var panner = ctx.createPanner();
    panner.panningModel = 'HRTF';
    panner.distanceModel = 'inverse';
    panner.refDistance = 1;
    panner.rolloffFactor = 0; // distance attenuation is calculated in Lua
    panner.maxDistance = 10000;
    panner.coneInnerAngle = 360;
    panner.coneOuterAngle = 360;
    panner.coneOuterGain = 1;

    var filter = ctx.createBiquadFilter();
    filter.type = 'lowpass';
    filter.frequency.value = 22050;
    filter.Q.value = 0.4;

    var gain = ctx.createGain();
    gain.gain.value = clamp(volume, 0, 1);

    source.connect(panner);
    panner.connect(filter);
    filter.connect(gain);
    if (typeof Howler !== 'undefined' && Howler.ctx === ctx && Howler.masterGain) gain.connect(Howler.masterGain);
    else gain.connect(ctx.destination);
    setPannerPosition(panner, pos, ctx);

    var spatial = {
        audio: audio,
        source: source,
        panner: panner,
        filter: filter,
        gain: gain,
        ctx: ctx,
        pendingSeek: null,
        failed: false,
        destroy: function () {
            try { audio.pause(); } catch (e) {}
            try { audio.removeAttribute('src'); audio.load(); } catch (e) {}
            [source, panner, filter, gain].forEach(function (node) {
                try { node.disconnect(); } catch (e) {}
            });
        }
    };

    audio.addEventListener('loadedmetadata', function () {
        if (spatial.pendingSeek !== null) applyMediaTimestamp(spatial, spatial.pendingSeek, audio.loop);
    });
    audio.addEventListener('canplay', function () {
        if (spatial.pendingSeek !== null) applyMediaTimestamp(spatial, spatial.pendingSeek, audio.loop);
    });
    audio.addEventListener('ended', function () {
        if (!audio.loop && onEnd) onEnd();
    });
    audio.addEventListener('error', function () {
        if (spatial.failed) return;
        spatial.failed = true;
        if (onError) onError(audio.error);
    });

    return spatial;
}

function createHowl(src, volume, loop, is3D, pos, onEnd, forceHtml5) {
    var remote = /^https?:\/\//i.test(src);
    var useHtml5 = forceHtml5 === true || (remote && !is3D);
    var h = new Howl({
        src: [src],
        volume: clamp(volume, 0, 1),
        loop: !!loop,
        html5: useHtml5,
        onend: function () { if (!loop && onEnd) onEnd(); },
        onloaderror: function (id, err) { console.error('[pr_3dsound] load error:', src, err); },
        onplayerror: function (id, err) {
            console.error('[pr_3dsound] play error:', src, err);
            tryUnlockCtx();
        }
    });

    if (is3D) {
        h.pannerAttr({
            panningModel: 'HRTF',
            distanceModel: 'inverse',
            refDistance: 1,
            rolloffFactor: 0,
            maxDistance: 10000,
        });
        if (pos) h.pos(pos.x, pos.y, pos.z);
    }
    return h;
}

function setPlayerVolume(p, value) {
    var v = clamp(value, 0, 1);
    if (!p) return;
    if (p.type === 'youtube') {
        if (p.ytPlayer && p.ytPlayer.setVolume) p.ytPlayer.setVolume(Math.round(v * 100));
    } else if (p.type === 'soundcloud') {
        if (p.scWidget) p.scWidget.setVolume(Math.round(v * 100));
    } else if (p.spatial && p.spatial.gain) {
        setAudioParam(p.spatial.gain.gain, v, p.spatial.ctx);
    } else if (p.howl) {
        p.howl.volume(v);
    }
}

function notifyEnded(index) {
    if (!players[index]) return;
    players[index].playing = false;
    $.post('https://pr_3dsound/soundEnded', JSON.stringify({ index: index }));
    cleanupPlayer(index);
}

function cleanupPlayer(index) {
    var p = players[index];
    if (!p) return;
    if (p.spatial) {
        try { p.spatial.destroy(); } catch (e) {}
    }
    if (p.howl) {
        try { p.howl.stop(); p.howl.unload(); } catch (e) {}
    }
    if (p.type === 'youtube') {
        if (p.ytPlayer) { try { p.ytPlayer.stopVideo(); p.ytPlayer.destroy(); } catch (e) {} }
        var yd = document.getElementById('yt-' + index);
        if (yd) yd.remove();
    }
    if (p.type === 'soundcloud') {
        if (p.scWidget) { try { p.scWidget.pause(); } catch (e) {} }
        var sd = document.getElementById('sc-' + index);
        if (sd) sd.remove();
    }
    delete players[index];
}

function createSCWidget(index, url, volume, loop, options, onReady) {
    var containerId = 'sc-' + index;
    var iframe = document.getElementById(containerId);
    if (!iframe) {
        iframe = document.createElement('iframe');
        iframe.id = containerId;
        iframe.width = '1';
        iframe.height = '1';
        iframe.style.cssText = 'position:absolute;left:-9999px;top:-9999px;border:0;';
        iframe.allow = 'autoplay';
        iframe.src = 'https://w.soundcloud.com/player/?url=' + encodeURIComponent(sanitize(url))
            + '&auto_play=true&hide_related=true&show_comments=false&show_user=false'
            + '&show_reposts=false&show_teaser=false&visual=false&buying=false'
            + '&liking=false&download=false&sharing=false';
        document.body.appendChild(iframe);
    }

    function bind(attempts) {
        if (typeof SC === 'undefined' || !SC.Widget) {
            if (attempts > 0) setTimeout(function () { bind(attempts - 1); }, 200);
            else console.error('[pr_3dsound] SoundCloud Widget API unavailable.');
            return;
        }
        var widget = SC.Widget(iframe);
        if (players[index]) players[index].scWidget = widget;
        widget.bind(SC.Widget.Events.READY, function () {
            widget.setVolume(Math.round(volume * 100));
            if (options.startTime > 0) widget.seekTo(options.startTime * 1000);
            if (loop) {
                widget.bind(SC.Widget.Events.FINISH, function () { widget.seekTo(0); widget.play(); });
            } else {
                widget.bind(SC.Widget.Events.FINISH, function () { notifyEnded(index); });
            }
            if (players[index] && players[index].paused) widget.pause();
            if (onReady) onReady(widget);
        });
        widget.bind(SC.Widget.Events.ERROR, function (e) {
            console.warn('[pr_3dsound] SoundCloud error index=' + index, e);
        });
    }
    bind(25);
}

window.onYouTubeIframeAPIReady = function () {
    ytReady = true;
    ytQueue.forEach(function (fn) { fn(); });
    ytQueue = [];
};

function createYTPlayer(index, videoId, volume, loop, options, onReady) {
    var containerId = 'yt-' + index;
    var div = document.getElementById(containerId);
    if (!div) {
        div = document.createElement('div');
        div.id = containerId;
        div.style.display = 'none';
        document.getElementById('trash').appendChild(div);
    }

    var unmuteOnPlay = true;
    return new YT.Player(containerId, {
        height: '0', width: '0', videoId: videoId,
        playerVars: {
            autoplay: 1, controls: 0, disablekb: 1, iv_load_policy: 3,
            modestbranding: 1, playsinline: 1, mute: 1,
            start: Math.floor(options.startTime || 0),
        },
        events: {
            onReady: function (e) {
                e.target.mute();
                e.target.setVolume(0);
                if (options.startTime > 0) e.target.seekTo(options.startTime, true);
                e.target.playVideo();
                if (onReady) onReady(e.target);
            },
            onStateChange: function (e) {
                if (e.data === YT.PlayerState.PLAYING) {
                    if (unmuteOnPlay) {
                        unmuteOnPlay = false;
                        e.target.unMute();
                        e.target.setVolume(Math.round(volume * 100));
                    }
                    var p = players[index];
                    if (p) {
                        p.playing = true;
                        if (p.paused) e.target.pauseVideo();
                    }
                } else if (e.data === YT.PlayerState.ENDED) {
                    if (players[index] && players[index].loop) {
                        e.target.seekTo(0); e.target.playVideo();
                    } else {
                        notifyEnded(index);
                    }
                }
            },
            onError: function (e) {
                console.warn('[pr_3dsound] YouTube error', e.data, 'index', index);
            }
        }
    });
}

function setupExternalPlayer(index, url, volume, pos, loop, options, positional) {
    var urlType = detectUrlType(url);
    options = options || {};
    options.startTime = Math.max(0, Number(options.startTime) || 0);

    if (urlType === 'youtube') {
        var vid = extractYouTubeId(url);
        if (!vid) { console.warn('[pr_3dsound] invalid YouTube ID:', url); return; }
        var ytP = newPlayer({
            type: 'youtube', vol: volume, maxVol: volume, pos: positional ? pos : null,
            loop: !!loop, is2D: !positional, _lastDistVol: volume,
            paused: options.paused === true,
        });
        players[index] = ytP;
        var create = function () {
            if (!players[index]) return;
            players[index].ytPlayer = createYTPlayer(index, vid, volume, loop, options, function () {
                if (players[index]) players[index].playing = !players[index].paused;
            });
        };
        ytReady ? create() : ytQueue.push(create);
        return;
    }

    if (urlType === 'soundcloud') {
        var scP = newPlayer({
            type: 'soundcloud', vol: volume, maxVol: volume, pos: positional ? pos : null,
            loop: !!loop, is2D: !positional, _lastDistVol: volume,
            paused: options.paused === true,
        });
        players[index] = scP;
        createSCWidget(index, url, volume, loop, options, function () {
            if (players[index]) players[index].playing = !players[index].paused;
        });
        return;
    }

    if (!positional) {
        var h2d = createHowl(sanitize(url), volume, loop, false, null, function () { notifyEnded(index); }, true);
        var p2d = newPlayer({
            type: 'stream', howl: h2d, vol: volume, maxVol: volume,
            loop: !!loop, is2D: true, _lastDistVol: volume,
            paused: options.paused === true,
        });
        players[index] = p2d;
        h2d.once('play', function () {
            if (options.startTime > 0) {
                try { h2d.seek(options.startTime); } catch (e) {}
            }
            if (p2d.paused) h2d.pause();
        });
        h2d.play();
        p2d.playing = !p2d.paused;
        return;
    }

    // True 3D direct URL via WebAudio MediaElementSource.
    var p3d = newPlayer({
        type: 'spatial-stream', vol: volume, maxVol: volume, pos: pos,
        loop: !!loop, is2D: false, _lastDistVol: volume,
        paused: options.paused === true,
    });
    players[index] = p3d;

    function fallbackToHtml5(error) {
        if (!players[index] || players[index] !== p3d) return;
        console.warn('[pr_3dsound] Direct URL could not use WebAudio/CORS; falling back to non-HRTF HTML5 audio:', url, error || '');
        if (p3d.spatial) { try { p3d.spatial.destroy(); } catch (e) {} }
        p3d.spatial = null;
        p3d.type = 'stream-fallback';
        var h = createHowl(sanitize(url), volume, loop, false, null, function () { notifyEnded(index); }, true);
        p3d.howl = h;
        h.once('play', function () {
            if (options.startTime > 0) {
                try { h.seek(options.startTime); } catch (e) {}
            }
            if (p3d.paused) h.pause();
        });
        h.play();
        p3d.playing = !p3d.paused;
    }

    try {
        p3d.spatial = createSpatialMedia(url, volume, loop, pos, function () { notifyEnded(index); }, fallbackToHtml5);
        if (options.startTime > 0) {
            p3d.spatial.pendingSeek = options.startTime;
            applyMediaTimestamp(p3d.spatial, options.startTime, loop);
        }
        tryUnlockCtx();
        var playPromise = p3d.spatial.audio.play();
        if (playPromise && playPromise.catch) {
            playPromise.catch(function (e) {
                // Autoplay failures can often be fixed by resuming the AudioContext; do not
                // immediately abandon spatial audio unless the media element itself errors.
                tryUnlockCtx();
                setTimeout(function () {
                    if (!players[index] || !p3d.spatial || p3d.paused) return;
                    p3d.spatial.audio.play().catch(function () {});
                }, 150);
            });
        }
        if (p3d.paused) p3d.spatial.audio.pause();
        p3d.playing = !p3d.paused;
    } catch (e) {
        fallbackToHtml5(e);
    }
}

var SoundPlayer = {
    play: function (index, file, volume, pos, loop, is2D, options) {
        cleanupPlayer(index);
        options = options || {};
        var src = './sounds/' + sanitize(file);
        var is3D = !is2D && !!pos;
        var howl = createHowl(src, volume, loop, is3D, pos, function () { notifyEnded(index); }, false);
        var p = newPlayer({
            type: 'local', howl: howl, vol: volume, maxVol: volume,
            pos: is3D ? pos : null, is2D: !!is2D, playing: true,
            loop: !!loop, _lastDistVol: volume, paused: options.paused === true,
        });
        players[index] = p;
        howl.once('play', function () {
            if (options.startTime > 0) {
                try { howl.seek(options.startTime); } catch (e) {}
            }
            if (p.paused) howl.pause();
        });
        howl.play();
    },

    playUrl: function (index, url, volume, loop, options) {
        cleanupPlayer(index);
        setupExternalPlayer(index, url, volume, null, loop, options || {}, false);
    },

    playUrlPos: function (index, url, volume, pos, loop, options) {
        cleanupPlayer(index);
        setupExternalPlayer(index, url, volume, pos, loop, options || {}, true);
    },

    updateVolume: function (index, distVolume, playerPos, camDir) {
        var p = players[index];
        if (!p) return;
        p._lastDistVol = clamp(distVolume, 0, 1);
        var v = clamp(p._lastDistVol * (p._occlusionMult !== undefined ? p._occlusionMult : 1.0), 0, p.maxVol || 1);
        setPlayerVolume(p, v);

        // Howler and our custom spatial streams share Howler.ctx, so one listener update
        // drives both the Howler PannerNodes and MediaElement PannerNodes.
        if (typeof Howler !== 'undefined') {
            if (playerPos && Howler.pos) Howler.pos(playerPos.x, playerPos.y, playerPos.z);
            if (camDir && Howler.orientation) Howler.orientation(camDir.x, camDir.y, camDir.z, 0, 0, 1);
        }
        if (p.spatial) setContextListener(p.spatial.ctx, playerPos, camDir);
    },

    setFilter: function (index, freq, occlusionMult) {
        var p = players[index];
        if (!p) return;
        p._occlusionMult = clamp(occlusionMult === undefined ? 1 : occlusionMult, 0, 1);
        var distVol = p._lastDistVol !== undefined ? p._lastDistVol : p.vol;
        setPlayerVolume(p, clamp(distVol * p._occlusionMult, 0, p.maxVol || 1));
        if (p.spatial && p.spatial.filter) {
            var cutoff = clamp(freq || 22050, 350, 22050);
            setAudioParam(p.spatial.filter.frequency, cutoff, p.spatial.ctx);
        }
    },

    pause: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = true;
        p.playing = false;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.pauseVideo(); }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.pause(); }
        else if (p.spatial) { p.spatial.audio.pause(); }
        else if (p.howl) { p.howl.pause(); }
    },

    resume: function (index) {
        var p = players[index];
        if (!p) return;
        p.paused = false;
        p.playing = true;
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.playVideo(); }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.play(); }
        else if (p.spatial) { tryUnlockCtx(); p.spatial.audio.play().catch(function () {}); }
        else if (p.howl) { p.howl.play(); }
        tryUnlockCtx();
    },

    stop: function (index) { cleanupPlayer(index); },

    updateCoords: function (index, pos) {
        var p = players[index];
        if (!p || !pos) return;
        p.pos = pos;
        if (p.spatial) setPannerPosition(p.spatial.panner, pos, p.spatial.ctx);
        if (p.howl && p.type === 'local') p.howl.pos(pos.x, pos.y, pos.z);
    },

    setVolume: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.vol = p.maxVol = clamp(volume, 0, 1);
        var v = p.is2D ? p.vol : clamp((p._lastDistVol || p.vol) * (p._occlusionMult || 1), 0, p.maxVol);
        setPlayerVolume(p, v);
    },

    setVolumeMax: function (index, volume) {
        var p = players[index];
        if (!p) return;
        p.maxVol = clamp(volume, 0, 1);
    },

    setDistance: function (index, distance) {
        var p = players[index];
        if (!p) return;
        p.dist = Math.max(1, Number(distance) || 1);
        if (p.howl && p.type === 'local') p.howl.pannerAttr({ maxDistance: p.dist * 2, rolloffFactor: 0 });
        if (p.spatial && p.spatial.panner) p.spatial.panner.maxDistance = p.dist * 2;
    },

    setLoop: function (index, loopVal) {
        var p = players[index];
        if (!p) return;
        p.loop = !!loopVal;
        if (p.type === 'youtube') { if (p.ytPlayer && p.ytPlayer.setLoop) p.ytPlayer.setLoop(!!loopVal); }
        else if (p.spatial) p.spatial.audio.loop = !!loopVal;
        else if (p.howl) p.howl.loop(!!loopVal);
    },

    setTimestamp: function (index, time) {
        var p = players[index];
        if (!p) return;
        var t = Math.max(0, Number(time) || 0);
        if (p.type === 'youtube') { if (p.ytPlayer) p.ytPlayer.seekTo(t, true); else p._pendingSeek = t; }
        else if (p.type === 'soundcloud') { if (p.scWidget) p.scWidget.seekTo(t * 1000); else p._pendingSeek = t; }
        else if (p.spatial) applyMediaTimestamp(p.spatial, t, p.loop);
        else if (p.howl) {
            try { p.howl.seek(t); } catch (e) { p._pendingSeek = t; }
        }
    },

    fadeIn: function (index, duration, targetVolume) {
        var p = players[index];
        if (!p) return;
        var target = clamp(targetVolume, 0, 1);
        duration = Math.max(1, Number(duration) || 1000);
        if (p.spatial && p.spatial.gain) {
            var g = p.spatial.gain.gain, ctx = p.spatial.ctx;
            g.cancelScheduledValues(ctx.currentTime);
            setAudioParam(g, 0, ctx);
            g.linearRampToValueAtTime(target, ctx.currentTime + duration / 1000);
            return;
        }
        if (p.howl) { p.howl.fade(0, target, duration); return; }
        this._fadeWidget(p, 0, target, duration);
    },

    fadeOut: function (index, duration) {
        var p = players[index];
        if (!p) return;
        duration = Math.max(1, Number(duration) || 1000);
        if (p.spatial && p.spatial.gain) {
            var g = p.spatial.gain.gain, ctx = p.spatial.ctx;
            g.cancelScheduledValues(ctx.currentTime);
            g.setValueAtTime(g.value, ctx.currentTime);
            g.linearRampToValueAtTime(0, ctx.currentTime + duration / 1000);
            return;
        }
        if (p.howl) { p.howl.fade(p.howl.volume(), 0, duration); return; }
        this._fadeWidget(p, p.vol || 1, 0, duration);
    },

    _fadeWidget: function (p, from, to, duration) {
        var steps = 20, step = 0;
        var iv = setInterval(function () {
            step += 1;
            var v = from + (to - from) * (step / steps);
            setPlayerVolume(p, v);
            if (step >= steps) clearInterval(iv);
        }, duration / steps);
    },

    stopAll: function () {
        Object.keys(players).forEach(function (k) { cleanupPlayer(parseInt(k, 10)); });
    },
};

window.SoundPlayer = SoundPlayer;
