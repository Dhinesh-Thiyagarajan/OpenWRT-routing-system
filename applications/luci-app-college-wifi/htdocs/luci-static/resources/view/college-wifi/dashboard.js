'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

/*
 * Dashboard View — Phase 4
 * All statistics come from real RPC calls.
 * Phase 4 adds: active-session count, session table, auth/unauth breakdown.
 */

var callDashboardStats = rpc.declare({
	object: 'college.wifi',
	method: 'get_dashboard_stats',
	expect: {}
});

var callActiveSessions = rpc.declare({
	object: 'college.wifi',
	method: 'get_active_sessions',
	expect: {}
});

var MB = 1048576, GB = 1073741824;

return view.extend({

	load: function() {
		return Promise.all([
			callDashboardStats(),
			callActiveSessions()
		]);
	},

	render: function(data) {
		var stats    = data[0] || {};
		var sessData = data[1] || {};
		var sessions = sessData.sessions || [];

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('College WiFi Management Dashboard')),

			/* Phase 4 live-data banner */
			E('div', {
				'style': 'margin-bottom:16px;padding:9px 14px;background:#e8f5e9;'
					+ 'border-left:4px solid #4caf50;border-radius:4px;font-size:13px;'
			}, [
				E('strong', {}, '✅ '),
				_('Phase 4 — Live data. Student counts, session totals and security events '
				  + 'are computed from the real database. '
				  + 'Network traffic metrics available in Phase 5.')
			]),

			/* ── Stat cards ────────────────────────────────────── */
			E('div', {
				'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));'
					+ 'gap:14px;margin-bottom:20px;'
			}, [
				this.statCard('👥', _('Total Students'),   stats.total_students   || 0, '#2196F3'),
				this.statCard('✅', _('Active Students'),  stats.active_students  || 0, '#4CAF50'),
				this.statCard('🔗', _('Active Sessions'),  stats.active_sessions  || sessions.length || 0, '#009688'),
				this.statCard('📊', _('Total Data Used'),  this.fmtB(stats.total_data_usage_bytes || 0), '#9C27B0'),
				this.statCard('🚫', _('Blocked Students'), stats.blocked_students || 0, '#F44336')
			]),

			/* ── Network status ─────────────────────────────────── */
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('h3', {}, _('Network Status')),
				E('div', {
					'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));'
						+ 'gap:12px;margin-top:12px;'
				}, [
					this.statusItem(_('Internet'),  stats.internet_status  || 'unknown', stats.internet_status  === 'online'),
					this.statusItem(_('Wi-Fi'),     stats.wifi_status      || 'unknown', stats.wifi_status      === 'enabled'),
					this.statusItem(_('DHCP'),      stats.dhcp_status      || 'unknown', stats.dhcp_status      === 'running'),
					this.statusItem(_('Firewall'),  stats.firewall_status  || 'unknown', stats.firewall_status  === 'active')
				])
			]),

			/* ── Active sessions table (Phase 4) ─────────────────── */
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('h3', {}, _('Active Sessions')),
				E('div', { 'style': 'margin-top:10px;overflow-x:auto;' },
					sessions.length > 0
						? E('table', { 'class': 'table cbi-section-table' }, [
							E('tr', { 'class': 'tr table-titles' }, [
								E('th', { 'class': 'th' }, _('College ID')),
								E('th', { 'class': 'th' }, _('IP Address')),
								E('th', { 'class': 'th' }, _('MAC Address')),
								E('th', { 'class': 'th' }, _('Login Time')),
								E('th', { 'class': 'th' }, _('Session Status'))
							])
						].concat(sessions.map(function(s) {
							var isQuota = s.status === 'quota_exhausted';
							var badgeStyle = isQuota
								? 'background:#fff3e0;color:#e65100;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:700;'
								: 'background:#e8f5e9;color:#2e7d32;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:700;';
							return E('tr', { 'class': 'tr' }, [
								E('td', { 'class': 'td' },
									E('span', {
										'style': 'background:#e3f2fd;color:#1565c0;padding:2px 8px;'
											+ 'border-radius:12px;font-size:12px;font-weight:700;'
									}, s.college_id)
								),
								E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:12px;' },
									s.client_ip || '—'),
								E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:11px;color:#6b7a99;' },
									s.client_mac || '—'),
								E('td', { 'class': 'td', 'style': 'font-size:12px;color:#6b7a99;' },
									(s.login_time || '').replace('T', ' ').replace('Z', '')),
								E('td', { 'class': 'td' },
									E('span', { 'style': badgeStyle },
										isQuota ? 'Quota Exhausted' : 'Active'))
							]);
						})))
						: E('p', { 'style': 'color:#999;font-size:13px;' },
							_('No active sessions'))
				)
			]),

			/* ── Data usage summary ─────────────────────────────── */
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('h3', {}, _('Data Usage')),
				E('table', { 'class': 'table', 'style': 'margin-top:10px;' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'style': 'font-weight:bold;width:55%;' }, _('Total Usage (all students)')),
						E('td', { 'class': 'td' }, this.fmtB(stats.total_data_usage_bytes || 0))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'style': 'font-weight:bold;' }, _("Today's Usage")),
						E('td', { 'class': 'td' },
							stats.today_data_usage_bytes
								? this.fmtB(stats.today_data_usage_bytes)
								: E('em', { 'style': 'color:#999;font-size:12px;' }, _('Available in Phase 5')))
					])
				])
			]),

			/* ── Recent logins ──────────────────────────────────── */
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('h3', {}, _('Recent Student Logins')),
				(stats.recent_logins && stats.recent_logins.length > 0)
					? E('table', { 'class': 'table cbi-section-table', 'style': 'margin-top:10px;' }, [
						E('tr', { 'class': 'tr table-titles' }, [
							E('th', { 'class': 'th' }, _('College ID')),
							E('th', { 'class': 'th' }, _('Name')),
							E('th', { 'class': 'th' }, _('Login Time'))
						])
					].concat((stats.recent_logins || []).map(function(l) {
						return E('tr', { 'class': 'tr' }, [
							E('td', { 'class': 'td' },
								E('span', {
									'style': 'background:#e3f2fd;color:#1565c0;padding:2px 8px;'
										+ 'border-radius:12px;font-size:12px;font-weight:700;'
								}, l.college_id)),
							E('td', { 'class': 'td' }, l.name),
							E('td', { 'class': 'td', 'style': 'font-size:12px;color:#6b7a99;' },
								(l.time || '').replace('T', ' ').replace('Z', ''))
						]);
					})))
					: E('p', { 'style': 'color:#999;font-size:13px;margin-top:10px;' }, _('No recent login activity'))
			]),

			/* ── Security overview ──────────────────────────────── */
			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('h3', {}, _('Security Overview')),
				E('table', { 'class': 'table', 'style': 'margin-top:10px;' }, [
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'style': 'font-weight:bold;width:70%;' }, _('Failed Authentication Attempts')),
						E('td', { 'class': 'td',
							'style': (stats.failed_auth_today || 0) > 5
								? 'color:#f44336;font-weight:bold;' : ''
						}, String(stats.failed_auth_today || 0))
					]),
					E('tr', { 'class': 'tr' }, [
						E('td', { 'class': 'td', 'style': 'font-weight:bold;' }, _('Quota Violations')),
						E('td', { 'class': 'td' }, String(stats.blocked_attempts_today || 0))
					])
				])
			]),

			/* ── Quick actions ──────────────────────────────────── */
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Quick Actions')),
				E('div', { 'style': 'margin-top:10px;display:flex;gap:10px;flex-wrap:wrap;' }, [
					E('button', {
						'class': 'cbi-button cbi-button-add',
						'click': function() { window.location.href = L.url('admin/college-wifi/students'); }
					}, '👥 ' + _('Manage Students')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() { window.location.href = L.url('admin/college-wifi/sessions'); }
					}, '🔗 ' + _('View Sessions')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() { window.location.href = L.url('admin/college-wifi/devices'); }
					}, '📱 ' + _('Devices')),
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': function() { window.location.href = L.url('admin/college-wifi/security'); }
					}, '🔐 ' + _('Security Logs'))
				])
			])
		]);
	},

	statCard: function(icon, label, value, color) {
		return E('div', {
			'style': 'background:#fff;padding:16px 18px;border-radius:8px;'
				+ 'border-top:3px solid ' + color
				+ ';box-shadow:0 2px 4px rgba(0,0,0,.08);'
		}, [
			E('div', { 'style': 'font-size:20px;margin-bottom:5px;' }, icon),
			E('div', { 'style': 'font-size:11px;color:#6b7a99;font-weight:600;text-transform:uppercase;letter-spacing:.5px;margin-bottom:3px;' }, label),
			E('div', { 'style': 'font-size:24px;font-weight:800;color:' + color + ';line-height:1;' }, String(value))
		]);
	},

	statusItem: function(label, status, good) {
		var c = good ? '#4CAF50' : '#F44336';
		return E('div', { 'style': 'background:#fff;padding:13px;border-radius:8px;box-shadow:0 2px 4px rgba(0,0,0,.08);' }, [
			E('div', { 'style': 'font-size:12px;color:#6b7a99;margin-bottom:4px;font-weight:600;' }, label),
			E('div', { 'style': 'font-size:14px;font-weight:700;color:' + c + ';text-transform:capitalize;' }, '● ' + status)
		]);
	},

	fmtB: function(b) {
		b = b || 0;
		if (b >= GB)   return (b / GB).toFixed(2)   + ' GB';
		if (b >= MB)   return (b / MB).toFixed(0)   + ' MB';
		if (b >= 1024) return (b / 1024).toFixed(0) + ' KB';
		return b + ' B';
	},

	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
