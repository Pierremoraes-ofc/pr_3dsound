fx_version 'bodacious'
game 'gta5'

author 'PierreMoraes'
name 'pr_3dsound'
description '3D sound system — HRTF local/direct URL audio, persistent proximity streaming and entity attachment'
version '4.0.0'

client_scripts {
    'client/client.lua',
    'client/native_sound.lua',
}

server_scripts {
    'server/server.lua',
    'server/native_sound.lua',
    'server/version.lua'
}

ui_page 'html/index.html'

files {
    'html/index.html',
    'html/scripts/*.js',
    'html/**/*.js',
    --'html/**/*.css',
    -- sons proprios do pr_3dsound
    'html/sounds/*.ogg',
    'html/sounds/*.mp3',
    'html/sounds/*.weba',
    -- sons de outros scripts em subpastas (ex: html/sounds/meu_script/pistola.ogg)
    'html/sounds/**/*.ogg',
    'html/sounds/**/*.mp3',
    --'html/sounds/**/*.weba',
}
