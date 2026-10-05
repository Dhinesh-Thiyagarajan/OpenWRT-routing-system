'use strict';
'require view';
'require rpc';
'require ui';

/*
 * Session Management View — Phase 4
 * Shows all active sessions with validate/logout actions.
 */

var callActiveSessions = rpc.declare({
	object: 'college.wifi',
	method: 'get_active_sessions',
	expect: {}
});

var callLogout = rpc.declare({
	object: 'college.wifi',
	method: 'logout_student',
	params: ['session_id', 'college_id', 'reason'],
	expect: {}
});

var callValidate = rpc.declare({
	object: 'college.wifi',
	method: 'validate_session',
	params: ['session_id', 'college_id', 'client_mac'],
	expect: {}
});

var MB = 1048576, GB = 1073741824;

return view.extend({

	load: function() {
		return callActiveSessions();
	},

	render: function(data) {
		var sessions = (data && data.sessions) ? data.sessions : [];

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Active Sessions')),

			/* Summary strip */
			E('div', {
				'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));'
					+ 'gap:12px;margin-bottom:20px;'
			}, [
				this.miniCard(_('Total Active'), sessions.length, '#009688'),
				this.miniCard(_('Quota OK'),
					sessions.filter(function(s) { return s.status !== 'quota_exhausted'; }).length, '#4CAF50'),
				this.miniCard(_('Quota Exhausted'),
					sessions.filter(function(s) { return s.status === 'quota_exhausted'; }).length, '#F44336')
			]),

			E('div', { 'class': 'cbi-section', 'style': 'margin-bottom:20px;' }, [
				E('p', { 'style': 'font-size:13px;color:#6b7a99;margin-bottom:12px;' },
					_('Phase 4 — Sessions are managed in /etc/college-wifi/sessions.json. '
					  + 'Real-time network enforcement is added in Phase 5.')),

				sessions.length === 0
					? E('div', {
						'style': 'text-align:center;padding:30px;background:#fafafa;'
							+ 'border:2px dashed #dde2ea;border-radius:10px;color:#6b7a99;'
					}, [
						E('div', { 'style': 'font-size:36px;margin-bottom:8px;' }, '🔗'),
						E('div', { 'style': 'font-size:14px;' }, _('No active sessions'))
					])
					: E('div', { 'style': 'overflow-x:auto;' }, [
						E('table', { 'class': 'table cbi-section-table' }, [
							E('tr', { 'class': 'tr table-titles' }, [
								E('th', { 'class': 'th' }, _('Session ID')),
								E('th', { 'class': 'th' }, _('College ID')),
								E('th', { 'class': 'th' }, _('IP Address')),
								E('th', { 'class': 'th' }, _('MAC Address')),
								E('th', { 'class': 'th' }, _('Login Time')),
								E('th', { 'class': 'th' }, _('Expires')),
								E('th', { 'class': 'th' }, _('Status')),
								E('th', { 'class': 'th' }, _('Actions'))
							])
						].concat(sessions.map(L.bind(function(s) {
							var isExhausted = s.status === 'quota_exhausted';
							var badgeSt = isExhausted
								? 'background:#fff3e0;color:#e65100;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:700;'
								: 'background:#e8f5e9;color:#2e7d32;padding:2px 8px;border-radius:12px;font-size:11px;font-weight:700;';
							return E('tr', { 'class': 'tr' }, [
								E('td', { 'class': 'td',
									'style': 'font-family:monospace;font-size:11px;color:#6b7a99;max-width:130px;overflow:hidden;text-overflow:ellipsis;' },
									s.session_id || '—'),
								E('td', { 'class': 'td' },
									E('span', {
										'style': 'background:#e3f2fd;color:#1565c0;padding:2px 8px;'
											+ 'border-radius:12px;font-size:12px;font-weight:700;'
									}, s.college_id)),
								E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:12px;' },
									s.client_ip || '—'),
								E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:11px;color:#6b7a99;' },
									s.client_mac || '—'),
								E('td', { 'class': 'td', 'style': 'font-size:12px;color:#6b7a99;' },
									(s.login_time || '').replace('T', ' ').replace('Z', '')),
								E('td', { 'class': 'td', 'style': 'font-size:12px;color:#6b7a99;' },
									s.expires_at
										? new Date(parseInt(s.expires_at) * 1000).toLocaleString()
										: '—'),
								E('td', { 'class': 'td' },
									E('span', { 'style': badgeSt },
										isExhausted ? _('Quota Exhausted') : _('Active'))),
								E('td', { 'class': 'td', 'style': 'white-space:nowrap;' }, [
									E('button', {
										'class': 'cbi-button cbi-button-action',
										'style': 'padding:4px 9px;font-size:12px;margin-right:4px;',
										'click': ui.createHandlerFn(this, 'doValidate', s.session_id, s.college_id)
									}, _('Validate')),
									E('button', {
										'class': 'cbi-button cbi-button-negative',
										'style': 'padding:4px 9px;font-size:12px;',
										'click': ui.createHandlerFn(this, 'doLogout', s.session_id, s.college_id)
									}, _('Terminate'))
								])
							]);
						}, this)))
					])
			])
		]);
	},

	miniCard: function(label, value, color) {
		return E('div', {
			'style': 'background:#fff;padding:14px 16px;border-radius:8px;'
				+ 'border-top:3px solid ' + color + ';box-shadow:0 2px 4px rgba(0,0,0,.08);'
		}, [
			E('div', { 'style': 'font-size:11px;color:#6b7a99;font-weight:600;text-transform:uppercase;letter-spacing:.5px;margin-bottom:3px;' }, label),
			E('div', { 'style': 'font-size:24px;font-weight:800;color:' + color + ';' }, String(value))
		]);
	},

	doValidate: function(sessId, collegeId) {
		return callValidate(sessId, collegeId, '').then(function(res) {
			if (res && res.valid) {
				ui.addNotification(null, E('p', {}, _('Session ') + sessId + _(' is valid.')), 'info');
			} else {
				ui.addNotification(null,
					E('p', {}, _('Session invalid or expired: ') + (res.status || res.error || 'unknown')),
					'warning');
			}
		});
	},

	doLogout: function(sessId, collegeId) {
		return callLogout(sessId, collegeId, 'admin_terminate').then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, _('Session for ') + collegeId + _(' terminated.')), 'info');
				return this.load().then(L.bind(function(data) {
					/* Simple page reload to refresh the table */
					window.location.reload();
				}, this));
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'unknown')), 'error');
			}
		}, this));
	},

	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
