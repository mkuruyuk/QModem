/* lpac-esim-telegram.js — v1.0.0 */
'use strict';

// Auto-init when apiGet is already available (qmodem-next context where
// window.apiGet is set before scripts load). In legacy LuCI, apiGet is
// defined in lpac-esim-main.js which may load after this file, so the
// showTab() lazy-load mechanism calls loadTelegramConfig() explicitly.
if (typeof apiGet === 'function') {
    loadTelegramConfig();
    checkBotStatus();
}

function loadTelegramConfig() {
    apiGet('telegram_config')
        .then(function(data) {
            if (data && data.config) {
                var c = data.config;
                document.getElementById('tg-enabled').checked = (c.enabled === '1');
                document.getElementById('tg-token').value = c.token || '';
                document.getElementById('tg-token').setAttribute('data-masked', c.token || '');
                document.getElementById('tg-chat-id').value = c.chat_id || '';
                document.getElementById('tg-poll-interval').value = c.poll_interval || '30';
                document.getElementById('tg-allow-disruptive').checked = (c.allow_disruptive !== '0');
                document.getElementById('tg-require-confirm').checked = (c.require_confirm !== '0');
            }
            document.getElementById('telegram-loading').style.display = 'none';
            document.getElementById('telegram-content').style.display = 'block';
        })
        .catch(function() {
            document.getElementById('telegram-loading').textContent = 'Failed to load config.';
        });
}

function checkBotStatus() {
    apiGet('telegram_status')
        .then(function(data) {
            var el = document.getElementById('tg-status-indicator');
            var btn = document.getElementById('tg-startstop-btn');
            var lastPoll = document.getElementById('tg-last-poll');
            if (data && data.running) {
                var stateText = data.state === 'ok' ? '● Running (connected)' :
                                data.state === 'error' ? '● Running (connection error)' :
                                '● Running';
                var stateColor = data.state === 'ok' ? '#28a745' :
                                 data.state === 'error' ? '#ffc107' : '#28a745';
                el.innerHTML = '<span style="color: ' + stateColor + ';">' + stateText + '</span>';
                btn.textContent = 'Stop Bot';
                btn.setAttribute('data-action', 'stop');
            } else {
                el.innerHTML = '<span style="color: #dc3545;">○ Stopped</span>';
                btn.textContent = 'Start Bot';
                btn.setAttribute('data-action', 'start');
            }
            // Show last poll time
            if (lastPoll && data && data.last_poll) {
                var ago = Math.floor(Date.now() / 1000) - data.last_poll;
                lastPoll.textContent = ago < 5 ? 'just now' : ago + 's ago';
            } else if (lastPoll) {
                lastPoll.textContent = '-';
            }
        })
        .catch(function() {
            document.getElementById('tg-status-indicator').textContent = '? Unknown';
        });
}

function saveTelegramConfig() {
    var tokenEl = document.getElementById('tg-token');
    var token = tokenEl.value.trim();
    var maskedToken = tokenEl.getAttribute('data-masked') || '';

    // If token hasn't changed from masked version, send masked (server will skip update)
    var config = {
        enabled: document.getElementById('tg-enabled').checked ? '1' : '0',
        token: token,
        chat_id: document.getElementById('tg-chat-id').value.trim(),
        poll_interval: document.getElementById('tg-poll-interval').value || '30',
        allow_disruptive: document.getElementById('tg-allow-disruptive').checked ? '1' : '0',
        require_confirm: document.getElementById('tg-require-confirm').checked ? '1' : '0'
    };

    if (config.enabled === '1' && (!config.token || config.token === maskedToken) && maskedToken === '') {
        alert('Bot Token is required when bot is enabled.');
        return;
    }
    if (config.enabled === '1' && !config.chat_id) {
        alert('Chat ID is required when bot is enabled.');
        return;
    }

    apiPost('save_telegram_config', config)
        .then(function(data) {
            if (data && data.success) {
                alert('Configuration saved. Bot will restart.');
                setTimeout(checkBotStatus, 3000);
            } else {
                alert('Failed to save: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(function() {
            alert('Network error saving configuration.');
        });
}

function testTelegramBot() {
    var token = document.getElementById('tg-token').value.trim();
    var chatId = document.getElementById('tg-chat-id').value.trim();

    if (!token || !chatId) {
        alert('Please enter Bot Token and Chat ID first.');
        return;
    }

    apiPost('test_telegram', { token: token, chat_id: chatId })
        .then(function(data) {
            if (data && data.success) {
                alert('✅ Test message sent successfully! Check your Telegram.');
            } else {
                alert('❌ Test failed: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(function() {
            alert('Network error during test.');
        });
}

function toggleTelegramBot() {
    var btn = document.getElementById('tg-startstop-btn');
    var action = btn.getAttribute('data-action') || 'start';

    apiPost('telegram_toggle', { action: action })
        .then(function(data) {
            if (data && data.success) {
                setTimeout(checkBotStatus, 2000);
            } else {
                alert('Failed: ' + (data.error || 'Unknown error'));
            }
        })
        .catch(function() {
            alert('Network error.');
        });
}
