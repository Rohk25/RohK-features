--[[
    Copyright 2017 wrxck <matthew@matthewhesketh.com>
    This code is licensed under the MIT. See LICENSE for details.
]]--

local rss = {}

local mattata = require('mattata')
local https = require('ssl.https')
local http = require('socket.http')
local url = require('socket.url')
local ltn12 = require('ltn12')
local json = require('dkjson')
local redis = require('mattata-redis')
local feedparser = require('feedparser')
local configuration = require('configuration')

function rss:init(configuration)
    rss.arguments = 'rss <sub | del> <url>'
    rss.commands = mattata.commands(
        self.info.username,
        configuration.command_prefix
    ):command('rss').table
    rss.help = '/rss <sub | del> <url> - Subscribe or unsubscribe from the given RSS feed.'
end

function rss.tail(n, k)
    local u, r = ''
    for i = 1, k do
        n, r = math.floor(n / 0x40), n % 0x40
        u = string.char(r + 0x80) .. u
    end
    return u, n
end
 
function rss.to_utf8(a)
    local n, r, u = tonumber(a)
    if n < 0x80 then
        return string.char(n)
    elseif n < 0x800 then
        u, n = rss.tail(n, 1)
        return string.char(n + 0xc0) .. u
    elseif n < 0x10000 then
        u, n = rss.tail(n, 2)
        return string.char(n + 0xe0) .. u
    elseif n < 0x200000 then
        u, n = rss.tail(n, 3)
        return string.char(n + 0xf0) .. u
    elseif n < 0x4000000 then
        u, n = rss.tail(n, 4)
        return string.char(n + 0xf8) .. u
    else
        u, n = rss.tail(n, 5)
        return string.char(n + 0xfc) .. u
    end
end

function rss.unescape_html(str)
    return str:gsub('&lt;', '<'):gsub('&gt;', '>'):gsub('&quot;', '"'):gsub('&apos;', '\''):gsub('&#(%d+);', rss.to_utf8):gsub(
        '&#x(%d+);',
        function(n)
            return string.char(tonumber(n, 16))
        end
    ):gsub('&amp;', '&')
end

function rss.get_redis_hash(id, option, extra)
    local ex = ''
    if option ~= nil then
        ex = ex .. ':' .. option
        if extra ~= nil then
            ex = ex .. ':' .. extra
        end
    end
    return 'rss:' .. id .. ex
end

function rss.get_url_protocol(url)
    local feed_url, is_http = url:gsub('http://', '')
    local url, is_https = url:gsub('https://', '')
    local protocol = 'http'
    if is_https == 1 then
        protocol = protocol .. 's'
    end
    return url, protocol
end

function rss.get_parsed_feed(url, protocol)
    local feed, res = nil, 0
    if protocol == 'http' then
        feed, res = http.request(url)
    elseif protocol == 'https' then
        feed, res = https.request(url)
    end
    if res ~= 200 then
        return nil, 'There was an error whilst connecting to ' .. url
    end
    local parse = feedparser.parse(feed)
    if parse == nil then
        return nil, 'There was an error retrieving a valid RSS feed from that url. Please, make sure you typed it correctly, and try again.'
    end
    return parse, nil
end

function rss.get_new_entries(last_entry, parsed)
    local entries = {}
    for k, v in pairs(parsed) do
        if v.id == last_entry then
            return entries
        else
            table.insert(
                entries,
                v
            )
        end
    end
    return entries
end

function rss.subscribe(id, url)
    local base_url, protocol = rss.get_url_protocol(url)
    local protocol_hash = rss.get_redis_hash(
        base_url,
        'protocol'
    )
    local last_entry_hash = rss.get_redis_hash(
        base_url,
        'last_entry'
    )
    local subscription_hash = rss.get_redis_hash(
        base_url,
        'subscriptions'
    )
    local id_hash = rss.get_redis_hash(id)
    if redis:sismember(
        id_hash,
        base_url
    ) then
        return 'You are already subscribed to ' .. url
    end
    local parsed, res = rss.get_parsed_feed(
        url,
        protocol
    )
    if res ~= nil then
        return res
    end
    local last_entry = ''
    if #parsed.entries > 0 then
        last_entry = parsed.entries[1].id
    end
    local name = parsed.feed.title
    redis:set(
        protocol_hash,
        protocol
    )
    redis:set(
        last_entry_hash,
        last_entry
    )
    redis:sadd(
        subscription_hash,
        id
    )
    redis:sadd(
        id_hash,
        base_url
    )
    return 'You are now subscribed to <a href="' .. url .. '">' .. mattata.escape_html(name) .. '</a> - you will receive updates for this feed right here in this chat!'
end

function rss.unsubscribe(id, n)
    if #n > 5 then
        return 'You cannot subscribe to more than 5 RSS feeds!'
    end
    n = tonumber(n)
    local id_hash = rss.get_redis_hash(id)
    local subscriptions = redis:smembers(id_hash)
    if n < 1 or n > #subscriptions then
        return 'Please enter a valid subscription ID.'
    end
    local subscription = subscriptions[n]
    local subscription_hash = rss.get_redis_hash(
        subscription,
        'subscriptions'
    )
    redis:srem(
        id_hash,
        subscription
    )
    redis:srem(
        subscription_hash,
        id
    )
    local unsubscribed = redis:smembers(subscription_hash)
    if #unsubscribed < 1 then
        redis:del(
            rss.get_redis_hash(
                subscription,
                'protocol'
            )
        )
        redis:del(
            rss.get_redis_hash(
                subscription,
                'last_entry'
            )
        )
    end
    return 'You will no longer receive updates from this feed.'
end

function rss.get_subs(id)
    local subscriptions = redis:smembers(rss.get_redis_hash(id))
    if not subscriptions[1] then
        return 'You are not subscribed to any RSS feeds!'
    end
    local keyboard = {
        ['one_time_keyboard'] = true,
        ['selective'] = true,
        ['resize_keyboard'] = true
    }
    local buttons = {}
    local text = 'This chat is currently receiving updates for the following RSS feeds:'
    for k, v in pairs(subscriptions) do
        text = text .. '\n' .. k .. ': ' .. v .. '\n'
        table.insert(
            buttons,
            {
                ['text'] = configuration.command_prefix .. 'rss del ' .. k
            }
        )
    end
    keyboard.keyboard = {
        buttons,
        {
            {
                ['text'] = 'Cancel'
            }
        }
    }
    return text, json.encode(keyboard)
end

function rss:on_message(message, configuration)
    if message.chat.type == 'private' or not mattata.is_group_admin(message.chat.id, message.from.id) and not mattata.is_global_admin(message.from.id) then
        return
    elseif message.text_lower:match('^' .. configuration.command_prefix .. 'rss sub') and not message.text_lower:match('^' .. configuration.command_prefix .. 'rss sub$') then
        return mattata.send_message(
            message.chat.id,
            rss.subscribe(message.chat.id, message.text_lower:gsub('^' .. configuration.command_prefix .. 'rss sub ', '')),
            'html'
        )
    elseif message.text_lower:match('^' .. configuration.command_prefix .. 'rss sub$') then
        return mattata.send_reply(
            message,
            'Please specify the url of the RSS feed you would like to receive updates from.'
        )
    elseif message.text_lower:match('^' .. configuration.command_prefix .. 'rss del') and not message.text_lower:match('^' .. configuration.command_prefix .. 'rss del$') then
        mattata.send_message(
            message.chat.id,
            rss.unsubscribe(
                message.chat.id,
                message.text_lower:gsub('^' .. configuration.command_prefix .. 'rss del ', '')
            )
        )
    elseif message.text_lower == configuration.command_prefix .. 'rss' or message.text_lower:match('^' .. configuration.command_prefix .. 'rss del$') then
        local output, keyboard = rss.get_subs(message.chat.id)
        return mattata.send_message(
            message.chat.id,
            output,
            nil,
            true,
            false,
            nil,
            keyboard
        )
    elseif mattata.is_global_admin(message.from.id) and message.text_lower == configuration.command_prefix .. 'rss reload' then
        local success = rss:cron()
        if success then
            return mattata.send_message(
                message.chat.id,
                'Checking for RSS updates...'
            )
        end
        return
    else
        return mattata.send_message(
            message.chat.id,
            configuration.command_prefix .. rss.arguments
        )
    end
end

function rss:cron()
    local keys = redis:keys(
        rss.get_redis_hash(
            '*',
            'subscriptions'
        )
    )
    for k, v in pairs(keys) do
        local base_url = v:match('rss:(.+):subs')
        local protocol = redis:get(
            rss.get_redis_hash(
                base_url,
                'protocol'
            )
        )
        local last_entry = redis:get(
            rss.get_redis_hash(
                base_url,
                'last_entry'
            )
        )
        base_url = protocol .. '://' .. base_url
        local parsed, res = rss.get_parsed_feed(base_url, protocol)
        if res ~= nil then
            return
        end
        local new = rss.get_new_entries(
            last_entry,
            parsed.entries
        )
        local text = ''
        for n, entry in pairs(new) do
            local title = entry.title or 'No title'
            local link = entry.link or entry.id or 'No link'
            local content = ''
            if entry.content then
                content = entry.content:gsub('<br>', '\n'):gsub('%b<>', '')
                if entry.content:len() > 500 then
                    content = rss.unescape_html(content):sub(1, 500) .. '...'
                else
                    content = rss.unescape_html(content)
                end
            elseif entry.summary then
                content = entry.summary:gsub('<br>', '\n'):gsub('%b<>', '')
                if entry.summary:len() > 500 then
                    content = rss.unescape_html(content):sub(1, 500) .. '...'
                else
                    content = rss.unescape_html(content)
                end
            else
                content = ''
            end
            text = text .. '#' .. n .. ': <b>' .. mattata.escape_html(title) .. '</b>\n<i>' .. mattata.escape_html(mattata.trim(content)) .. '</i>\n<a href="' .. link .. '">Read more.</a>\n\n'
            if n == 5 then
                break
            end
        end
        if text ~= '' then
            local last_entry = new[1].id
            redis:set(
                rss.get_redis_hash(
                    base_url,
                    'last_entry'
                ),
                last_entry
            )
            for _, recipient in pairs(redis:smembers(v)) do
                mattata.send_chat_action(
                    recipient,
                    'typing'
                )
                mattata.send_message(
                    recipient,
                    text,
                    'html'
                )
            end
        end
    end
end

return rss