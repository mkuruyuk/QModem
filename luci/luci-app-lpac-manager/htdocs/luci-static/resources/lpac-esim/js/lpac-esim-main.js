/* lpac-esim-main.js — v1.3.5 */
'use strict';

var BASE_URL = L.env.scriptname + '/admin/modem/qmodem/esim/';

/* ===== Lazy load tracking ===== */
var tabLoaded = {};

/* ===== Tab switching with lazy load ===== */
function showTab(tabId, el) {
    var tabs = document.querySelectorAll('.cbi-tabcontent');
    for (var i = 0; i < tabs.length; i++) {
        tabs[i].style.display = 'none';
        tabs[i].classList.remove('cbi-tabcontent-active');
    }
    var links = document.querySelectorAll('.cbi-tabmenu li');
    for (var j = 0; j < links.length; j++) {
        links[j].classList.remove('cbi-tab-active');
    }
    var target = document.getElementById(tabId);
    if (target) {
        target.style.display = '';
        target.classList.add('cbi-tabcontent-active');
    }
    if (el && el.parentNode) {
        el.parentNode.classList.add('cbi-tab-active');
    }

    /* Lazy load: fetch data only on first tab activation */
    if (!tabLoaded[tabId]) {
        tabLoaded[tabId] = true;
        switch (tabId) {
            case 'info-tab':          if (typeof loadESIMInfo === 'function') loadESIMInfo(); break;
            case 'profiles-tab':      if (typeof loadProfiles === 'function') loadProfiles(); break;
            case 'notifications-tab': if (typeof loadNotifications === 'function') loadNotifications(); break;
            case 'config-tab':        if (typeof loadConfig === 'function') loadConfig(); break;
            case 'diag-tab':          if (typeof loadSyslog === 'function') loadSyslog(); break;
            case 'telegram-tab':      if (typeof loadTelegramConfig === 'function') { loadTelegramConfig(); checkBotStatus(); } break;
        }
    }
    return false;
}

/* Force reload of a tab (for Refresh buttons) */
function reloadTab(tabId) {
    tabLoaded[tabId] = false;
    showTab(tabId);
}

/* ===== Connectivity check ===== */
function checkConnectivity() {
    var checking = document.getElementById('connectivity-checking');
    var online   = document.getElementById('connectivity-online');
    var offline  = document.getElementById('connectivity-offline');
    if (checking) checking.style.display = 'block';
    if (online)   online.style.display   = 'none';
    if (offline)  offline.style.display  = 'none';

    fetch(BASE_URL + 'connectivity', { credentials: 'same-origin' })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            if (checking) checking.style.display = 'none';
            if (data.connected) {
                if (online) online.style.display = 'block';
            } else {
                if (offline) offline.style.display = 'block';
            }
        })
        .catch(function() {
            if (checking) checking.style.display = 'none';
            if (offline) offline.style.display = 'block';
        });
}

/* ===== Lock status polling ===== */
var lockPollTimer = null;

function checkLockStatus(callback) {
    fetch(BASE_URL + 'lock_status', { credentials: 'same-origin' })
        .then(function(r) { return r.json(); })
        .then(function(data) {
            var banner = document.getElementById('esim-lock-banner');
            if (data && data.payload && data.payload.data && data.payload.data.locked) {
                if (banner) banner.style.display = 'block';
            } else {
                if (banner) banner.style.display = 'none';
                if (callback) callback();
            }
        })
        .catch(function() {
            var banner = document.getElementById('esim-lock-banner');
            if (banner) banner.style.display = 'none';
        });
}

function startLockPolling(onUnlocked) {
    if (lockPollTimer) clearInterval(lockPollTimer);
    var networkLost = false;
    lockPollTimer = setInterval(function() {
        fetch(BASE_URL + 'lock_status', { credentials: 'same-origin' })
            .then(function(r) { return r.json(); })
            .then(function(data) {
                networkLost = false;
                var banner = document.getElementById('esim-lock-banner');
                var bannerText = document.getElementById('esim-lock-text');
                var d = data && data.payload && data.payload.data;
                if (d && d.locked) {
                    if (banner) banner.style.display = 'block';
                    if (bannerText) bannerText.textContent = 'Operation in progress... Please wait.';
                } else {
                    if (banner) banner.style.display = 'none';
                    clearInterval(lockPollTimer);
                    lockPollTimer = null;
                    var result = (d && d.last_result) ? d.last_result : null;
                    if (onUnlocked) onUnlocked(result);
                }
            })
            .catch(function() {
                // Network lost (modem rebooting, interface down)
                networkLost = true;
                var banner = document.getElementById('esim-lock-banner');
                var bannerText = document.getElementById('esim-lock-text');
                if (banner) banner.style.display = 'block';
                if (bannerText) bannerText.textContent = 'Connection lost — modem may be rebooting. Waiting for recovery...';
                // Don't clear interval — keep retrying
            });
    }, 5000);
}

/* ===== Helper: POST ===== */
function apiPost(endpoint, params) {
    var body = new URLSearchParams();
    if (params) {
        Object.keys(params).forEach(function(k) {
            body.append(k, params[k]);
        });
    }
    return fetch(BASE_URL + endpoint, {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: body.toString()
    }).then(function(r) { return r.json(); });
}

/* ===== Helper: GET ===== */
function apiGet(endpoint) {
    return fetch(BASE_URL + endpoint, { credentials: 'same-origin' })
        .then(function(r) { return r.json(); });
}

/* ===== Init ===== */
document.addEventListener('DOMContentLoaded', function() {
    checkConnectivity();
    /* Fetch and display version */
    apiGet('version').then(function(data) {
        if (data && data.payload && data.payload.data) {
            var v = data.payload.data;
            var el = document.getElementById('esim-app-version');
            if (el) el.textContent = 'v' + (v.script_version || '?') + ' / lpac ' + (v.lpac_version || '?') + ' / ' + (v.backend || '?').toUpperCase();
        }
    }).catch(function() {});
    /* Activate first tab — triggers lazy load for Info only */
    var firstTab = document.querySelector('.cbi-tabmenu li a');
    if (firstTab) firstTab.click();
});
