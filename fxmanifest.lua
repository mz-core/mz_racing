fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mz_racing'
author 'Mazus'
description 'Server-authoritative racing sessions with lobby, organizer, HUD and local checkpoints'
version '0.3.0'

ui_page 'web/index.html'

shared_scripts {
    'config.lua',
    'shared/schema.lua'
}

server_scripts {
    'server/clock.lua',
    'server/adapters/navigation.lua',
    'server/adapters/identity.lua',
    'server/adapters/authorization.lua',
    'server/adapters/position.lua',
    'server/adapters/audit.lua',
    'server/session_service.lua',
    'server/main.lua'
}

client_scripts {
    'client/main.lua'
}

files {
    'web/index.html',
    'web/css/racing.css',
    'web/js/strings.js',
    'web/js/app.js'
}

dependencies {
    'mz_core'
}
