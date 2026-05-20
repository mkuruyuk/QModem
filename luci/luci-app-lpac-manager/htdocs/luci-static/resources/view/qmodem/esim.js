'use strict';
'require view';
'require ui';
'require dom';
'require request';

/*
 * QModem Next - eSIM Manager View
 * 
 * This is a thin wrapper that loads the luci-app-lpac-manager interface
 * inside the qmodem-next tab system. The actual eSIM management logic
 * lives in /luci-static/resources/lpac-esim/js/*.js and communicates
 * with the Lua controller at admin/modem/qmodem/esim/*.
 */

return view.extend({
	render: function() {
		var container = E('div', { 'class': 'cbi-map' });

		// Header
		container.appendChild(E('h2', {}, _('eSIM Manager')));
		container.appendChild(E('div', { 'class': 'cbi-map-descr' },
			_('Manage eSIM profiles via lpac. Supports profile list, switch, download, and delete.')));

		// Connectivity banner
		var bannerDiv = E('div', { 'id': 'esim-connectivity-banner', 'style': 'margin-bottom: 20px;' });
		bannerDiv.appendChild(E('div', { 'id': 'connectivity-checking', 'style': 'padding: 10px; border: 1px solid #ffc107; background: #fff3cd; border-radius: 4px; color: #856404;' },
			E('strong', {}, _('Checking internet connection...'))));
		bannerDiv.appendChild(E('div', { 'id': 'connectivity-online', 'style': 'display: none; padding: 10px; border: 1px solid #28a745; background: #d4edda; border-radius: 4px; color: #155724;' },
			[ E('strong', {}, _('Internet connection available')), ' — ', _('You can manage eSIM profiles') ]));
		bannerDiv.appendChild(E('div', { 'id': 'connectivity-offline', 'style': 'display: none; padding: 10px; border: 1px solid #dc3545; background: #f8d7da; border-radius: 4px; color: #721c24;' },
			[ E('strong', {}, _('No internet connection')), ' — ', _('Local management (switch, reboot) works offline.') ]));
		container.appendChild(bannerDiv);

		// Lock banner
		container.appendChild(E('div', { 'id': 'esim-lock-banner', 'style': 'display: none; margin-bottom: 20px; padding: 10px; border: 1px solid #17a2b8; background: #d1ecf1; border-radius: 4px; color: #0c5460;' },
			[ E('strong', {}, _('Backend is busy')), ' — ', E('span', { 'id': 'lock-status-text' }, _('An operation is in progress...')) ]));

		// Tab menu
		var tabMenu = E('div', { 'class': 'cbi-tabmenu' });
		var tabList = E('ul', {});
		var tabs = [
			{ id: 'info-tab', label: _('eSIM Info') },
			{ id: 'profiles-tab', label: _('Profiles') },
			{ id: 'download-tab', label: _('Download') },
			{ id: 'notifications-tab', label: _('Notifications') },
			{ id: 'config-tab', label: _('Config') },
			{ id: 'telegram-tab', label: _('Telegram Bot') }
		];

		tabs.forEach(function(tab, idx) {
			var li = E('li', { 'class': 'cbi-tab' + (idx === 0 ? ' cbi-tab-active' : '') });
			li.appendChild(E('a', { 'href': '#', 'data-tab': tab.id, 'click': function(ev) {
				ev.preventDefault();
				showEsimTab(tab.id, this);
			}}, tab.label));
			tabList.appendChild(li);
		});
		tabMenu.appendChild(tabList);
		container.appendChild(tabMenu);

		// Tab content container - will be populated by lpac-esim JS
		var tabContainer = E('div', { 'class': 'cbi-tabcontainer', 'id': 'esim-tab-container' });

		tabs.forEach(function(tab, idx) {
			var div = E('div', {
				'id': tab.id,
				'class': 'cbi-tabcontent' + (idx === 0 ? ' cbi-tabcontent-active' : ''),
				'style': idx === 0 ? '' : 'display: none;'
			});
			div.appendChild(E('div', { 'style': 'text-align: center; padding: 20px;' }, _('Loading...')));
			tabContainer.appendChild(div);
		});
		container.appendChild(tabContainer);

		// Load CSS
		var cssLink = document.createElement('link');
		cssLink.rel = 'stylesheet';
		cssLink.href = L.resource('lpac-esim/css/lpac-esim.css');
		document.head.appendChild(cssLink);

		// After DOM is ready, load the eSIM JS modules
		requestAnimationFrame(function() {
			loadEsimModules();
		});

		return container;
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});

// Tab switching
function showEsimTab(tabId, el) {
	// Hide all tabs
	var tabs = document.querySelectorAll('#esim-tab-container .cbi-tabcontent');
	tabs.forEach(function(t) { t.style.display = 'none'; t.classList.remove('cbi-tabcontent-active'); });

	// Deactivate all tab links
	var links = document.querySelectorAll('.cbi-tabmenu li');
	links.forEach(function(l) { l.classList.remove('cbi-tab-active'); });

	// Show selected tab
	var target = document.getElementById(tabId);
	if (target) {
		target.style.display = '';
		target.classList.add('cbi-tabcontent-active');
	}

	// Activate clicked tab
	if (el && el.parentNode) {
		el.parentNode.classList.add('cbi-tab-active');
	}
}

// Dynamically load eSIM JS modules
function loadEsimModules() {
	// Set BASE_URL for lpac-esim JS modules
	// In qmodem-next, L.env.requestpath = '/cgi-bin/luci/admin/modem/qmodem/esim'
	// API endpoints are at: admin/modem/qmodem/esim/{chip,profiles,...}
	var basePath = L.env.requestpath;
	if (!basePath.match(/\/esim\/?$/)) {
		basePath = basePath.replace(/\/+$/, '') + '/esim';
	}
	window.BASE_URL = basePath.replace(/\/+$/, '') + '/';

	// Compatibility: provide apiGet/apiPost that lpac-esim JS expects
	// Use plain fetch with LuCI CSRF token for compatibility
	window.apiGet = function(endpoint) {
		return fetch(window.BASE_URL + endpoint, {
			credentials: 'same-origin',
			headers: { 'X-Requested-With': 'XMLHttpRequest' }
		}).then(function(r) { return r.json(); });
	};

	window.apiPost = function(endpoint, params) {
		var body = new URLSearchParams();
		if (params) {
			Object.keys(params).forEach(function(k) { body.append(k, params[k]); });
		}
		// Add CSRF token if available
		var token = document.querySelector('input[name="token"]');
		if (token) body.append('token', token.value);

		return fetch(window.BASE_URL + endpoint, {
			method: 'POST',
			credentials: 'same-origin',
			headers: {
				'Content-Type': 'application/x-www-form-urlencoded',
				'X-Requested-With': 'XMLHttpRequest'
			},
			body: body.toString()
		}).then(function(r) { return r.json(); });
	};

	// Provide showTab compatibility function
	window.showTab = showEsimTab;

	// Load each module
	var scripts = [
		'lpac-esim/js/lpac-esim-info.js',
		'lpac-esim/js/lpac-esim-profiles.js',
		'lpac-esim/js/lpac-esim-download.js',
		'lpac-esim/js/lpac-esim-notifications.js',
		'lpac-esim/js/lpac-esim-config.js',
		'lpac-esim/js/lpac-esim-telegram.js'
	];

	scripts.forEach(function(src) {
		var script = document.createElement('script');
		script.src = L.resource(src);
		script.async = false;
		document.body.appendChild(script);
	});

	// Check connectivity
	setTimeout(function() { checkConnectivity(); }, 500);
}

function checkConnectivity() {
	if (typeof window.apiGet !== 'function') return;
	var checking = document.getElementById('connectivity-checking');
	var online = document.getElementById('connectivity-online');
	var offline = document.getElementById('connectivity-offline');

	window.apiGet('connectivity')
		.then(function(data) {
			if (checking) checking.style.display = 'none';
			if (data && data.payload && data.payload.data && data.payload.data.online) {
				if (online) online.style.display = 'block';
				if (offline) offline.style.display = 'none';
			} else {
				if (online) online.style.display = 'none';
				if (offline) offline.style.display = 'block';
			}
		})
		.catch(function() {
			if (checking) checking.style.display = 'none';
			if (offline) offline.style.display = 'block';
		});
}
