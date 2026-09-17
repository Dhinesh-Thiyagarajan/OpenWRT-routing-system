'use strict';
'require view';
'require rpc';
'require ui';

/*
 * Student Profile View — Phase 3
 * Shows full detail for one student, loaded by college_id URL parameter.
 * Phone number remains masked; phone_hash is never returned to frontend.
 */

var callGetStudent = rpc.declare({
	object: 'college.wifi',
	method: 'get_student',
	params: ['college_id'],
	expect: {}
});

var callBlockStudent = rpc.declare({
	object: 'college.wifi',
	method: 'block_student',
	params: ['college_id'],
	expect: {}
});

var callUnblockStudent = rpc.declare({
	object: 'college.wifi',
	method: 'unblock_student',
	params: ['college_id'],
	expect: {}
});

var callResetQuota = rpc.declare({
	object: 'college.wifi',
	method: 'reset_quota',
	params: ['college_id', 'new_quota_bytes'],
	expect: {}
});

var MB = 1048576;
var GB = 1073741824;

return view.extend({

	load: function() {
		/* Read college_id from the URL query string */
		var params    = new URLSearchParams(window.location.search);
		var collegeId = params.get('id') || '';
		if (!collegeId)
			return Promise.resolve({ error: 'No College ID specified in URL (?id=DSU001)' });
		return callGetStudent(collegeId);
	},

	render: function(student) {
		/* Error state */
		if (!student || student.error) {
			return E('div', { 'class': 'cbi-map' }, [
				E('h2', {}, _('Student Profile')),
				E('div', {
					'class': 'alert-message error',
					'style': 'padding:16px;background:#ffebee;border-left:4px solid #F44336;border-radius:4px;'
				}, [
					E('strong', {}, '⚠ '),
					E('span', {}, student ? student.error : _('Student not found')),
					E('div', { 'style': 'margin-top:12px;' }, [
						E('button', {
							'class': 'cbi-button',
							'click': function() { window.history.back(); }
						}, '← ' + _('Back'))
					])
				])
			]);
		}

		var self       = this;
		var pct        = student.quota_bytes > 0
			? Math.min(100, Math.round((student.used_bytes / student.quota_bytes) * 100)) : 0;
		var barColor   = pct >= 100 ? '#F44336' : pct >= 90 ? '#F44336' : pct >= 75 ? '#FF9800' : '#4CAF50';
		var statusColor = student.status === 'active'  ? '#4CAF50'
			: student.status === 'blocked' ? '#F44336' : '#FF9800';

		return E('div', { 'class': 'cbi-map' }, [
			/* Back nav */
			E('div', { 'style': 'margin-bottom:16px;' }, [
				E('button', {
					'class': 'cbi-button',
					'style': 'padding:6px 12px;font-size:13px;',
					'click': function() { window.location.href = L.url('admin/college-wifi/students'); }
				}, '← ' + _('Back to Students'))
			]),

			E('h2', {}, '👤 ' + student.name),

			/* ---- Header card ---- */
			E('div', {
				'style': 'background:#fff;border-radius:10px;border:1px solid #dde2ea;box-shadow:0 2px 8px rgba(0,0,0,.08);'
					+ 'padding:24px;margin-bottom:20px;display:flex;align-items:center;gap:24px;flex-wrap:wrap;'
			}, [
				/* Avatar circle */
				E('div', {
					'style': 'width:72px;height:72px;border-radius:50%;background:#1a2332;color:#fff;'
						+ 'display:flex;align-items:center;justify-content:center;font-size:28px;font-weight:700;flex-shrink:0;'
				}, student.name.charAt(0).toUpperCase()),

				/* Key info */
				E('div', { 'style': 'flex:1;' }, [
					E('div', { 'style': 'font-size:22px;font-weight:800;color:#1a2332;' }, student.name),
					E('div', { 'style': 'font-size:13px;color:#6b7a99;margin-top:4px;' }, [
						E('span', { 'style': 'background:#e3f2fd;color:#1565c0;padding:2px 9px;border-radius:12px;font-size:12px;font-weight:700;margin-right:8px;' }, student.college_id),
						E('span', { 'style': 'background:#f3e5f5;color:#7b1fa2;padding:2px 9px;border-radius:12px;font-size:12px;font-weight:700;margin-right:8px;text-transform:capitalize;' }, student.role),
						E('span', { 'style': 'padding:2px 9px;border-radius:12px;font-size:12px;font-weight:700;color:#fff;background:' + statusColor + ';text-transform:capitalize;' }, student.status)
					]),
					E('div', { 'style': 'margin-top:8px;font-size:12px;color:#6b7a99;' }, [
						E('span', {}, '📅 ' + _('Registered: ') + (student.created_at || '—')),
						E('span', { 'style': 'margin-left:20px;' }, '🕐 ' + _('Last Login: ') + (student.last_login || '—'))
					])
				]),

				/* Action buttons */
				E('div', { 'style': 'display:flex;gap:8px;flex-wrap:wrap;' }, [
					student.status === 'blocked' ?
						E('button', {
							'class': 'cbi-button cbi-button-save',
							'click': ui.createHandlerFn(this, 'doUnblock', student.college_id)
						}, '🔓 ' + _('Unblock')) :
						E('button', {
							'class': 'cbi-button cbi-button-negative',
							'click': ui.createHandlerFn(this, 'doBlock', student.college_id)
						}, '🚫 ' + _('Block')),
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'doResetQuota', student.college_id, student.quota_bytes)
					}, '🔄 ' + _('Reset Quota')),
					E('button', {
						'class': 'cbi-button',
						'click': function() { window.location.href = L.url('admin/college-wifi/students'); }
					}, '✏ ' + _('Edit (in list)'))
				])
			]),

			/* ---- Two-column detail ---- */
			E('div', { 'style': 'display:grid;grid-template-columns:1fr 1fr;gap:16px;margin-bottom:20px;' }, [

				/* Account details */
				this.detailCard('📋 ' + _('Account Details'), [
					[_('Internal ID'),   student.internal_id],
					[_('College ID'),    student.college_id],
					[_('Name'),          student.name],
					[_('Phone'),         student.phone_masked || '**********'],
					[_('Role'),          student.role],
					[_('Status'),        student.status],
					[_('MAC Address'),   student.mac_address  || '—'],
					[_('Registered'),    student.created_at   || '—'],
					[_('Last Login'),    student.last_login   || '—']
				]),

				/* Quota details */
				E('div', { 'style': 'background:#fff;border-radius:10px;border:1px solid #dde2ea;box-shadow:0 2px 8px rgba(0,0,0,.08);' }, [
					E('div', { 'style': 'padding:14px 18px 10px;border-bottom:1px solid #dde2ea;' }, [
						E('h3', { 'style': 'font-size:14px;font-weight:700;margin:0;' }, '📊 ' + _('Data Quota'))
					]),
					E('div', { 'style': 'padding:16px 18px;' }, [
						/* Progress bar */
						E('div', { 'style': 'margin-bottom:16px;' }, [
							E('div', { 'style': 'display:flex;justify-content:space-between;font-size:12px;color:#6b7a99;margin-bottom:6px;' }, [
								E('span', {}, _('Used: ') + self.fmtBytes(student.used_bytes)),
								E('span', {}, pct + '%')
							]),
							E('div', { 'style': 'background:#eee;border-radius:10px;height:12px;overflow:hidden;' }, [
								E('div', { 'style': 'width:' + pct + '%;height:100%;background:' + barColor + ';border-radius:10px;transition:width .6s;' })
							]),
							E('div', { 'style': 'display:flex;justify-content:space-between;font-size:12px;color:#6b7a99;margin-top:6px;' }, [
								E('span', {}, _('Total quota: ') + self.fmtBytes(student.quota_bytes)),
								E('span', { 'style': 'color:' + barColor + ';font-weight:700;' }, _('Remaining: ') + self.fmtBytes(student.remaining_bytes))
							])
						]),

						/* Stat table */
						E('table', { 'style': 'width:100%;font-size:13px;border-collapse:collapse;' }, [
							this.statRow(_('Quota Allocated'),  self.fmtBytes(student.quota_bytes)),
							this.statRow(_('Data Used'),        E('span', { 'style': 'color:' + barColor + ';font-weight:700;' }, self.fmtBytes(student.used_bytes))),
							this.statRow(_('Data Remaining'),   E('span', { 'style': 'color:' + barColor + ';font-weight:700;' }, self.fmtBytes(student.remaining_bytes))),
							this.statRow(_('Usage Percent'),    pct + '%')
						])
					])
				])
			]),

			/* ---- Phase previews ---- */
			E('div', { 'style': 'display:grid;grid-template-columns:1fr 1fr;gap:16px;' }, [
				this.comingSoonCard('🌐 ' + _('Active Sessions'), _('Session tracking will be implemented in Phase 4.')),
				this.comingSoonCard('📡 ' + _('Registered Devices'), _('Device association will be implemented in Phase 6.'))
			])
		]);
	},

	/* ---- action handlers ---- */
	doBlock: function(collegeId) {
		return callBlockStudent(collegeId).then(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, collegeId + _(' blocked. Reloading…')), 'info');
				setTimeout(function() { window.location.reload(); }, 1200);
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown')), 'error');
			}
		});
	},

	doUnblock: function(collegeId) {
		return callUnblockStudent(collegeId).then(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, collegeId + _(' unblocked. Reloading…')), 'info');
				setTimeout(function() { window.location.reload(); }, 1200);
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown')), 'error');
			}
		});
	},

	doResetQuota: function(collegeId, currentQuota) {
		return callResetQuota(collegeId, currentQuota).then(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, _('Quota reset for ') + collegeId + _('. Reloading…')), 'info');
				setTimeout(function() { window.location.reload(); }, 1200);
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown')), 'error');
			}
		});
	},

	/* ---- helpers ---- */
	detailCard: function(title, rows) {
		return E('div', { 'style': 'background:#fff;border-radius:10px;border:1px solid #dde2ea;box-shadow:0 2px 8px rgba(0,0,0,.08);' }, [
			E('div', { 'style': 'padding:14px 18px 10px;border-bottom:1px solid #dde2ea;' }, [
				E('h3', { 'style': 'font-size:14px;font-weight:700;margin:0;' }, title)
			]),
			E('div', { 'style': 'padding:4px 0;' }, [
				E('table', { 'style': 'width:100%;font-size:13px;border-collapse:collapse;' },
					rows.map(function(r) {
						return E('tr', {}, [
							E('td', { 'style': 'padding:9px 18px;color:#6b7a99;font-weight:600;width:45%;border-bottom:1px solid #f0f2f5;' }, r[0]),
							E('td', { 'style': 'padding:9px 18px;border-bottom:1px solid #f0f2f5;word-break:break-all;' }, r[1] || '—')
						]);
					})
				)
			])
		]);
	},

	statRow: function(label, value) {
		return E('tr', {}, [
			E('td', { 'style': 'padding:7px 0;color:#6b7a99;border-top:1px solid #f0f2f5;' }, label),
			E('td', { 'style': 'padding:7px 0;text-align:right;font-weight:700;border-top:1px solid #f0f2f5;' }, value)
		]);
	},

	comingSoonCard: function(title, msg) {
		return E('div', { 'style': 'background:#fafafa;border:2px dashed #dde2ea;border-radius:10px;padding:24px;text-align:center;' }, [
			E('h3', { 'style': 'font-size:14px;font-weight:700;margin:0 0 8px;' }, title),
			E('p',  { 'style': 'font-size:13px;color:#6b7a99;margin:0;' }, msg)
		]);
	},

	fmtBytes: function(b) {
		b = b || 0;
		if (b >= GB)  return (b / GB).toFixed(2)  + ' GB';
		if (b >= MB)  return (b / MB).toFixed(0)  + ' MB';
		if (b >= 1024) return (b / 1024).toFixed(0) + ' KB';
		return b + ' B';
	},

	handleSaveApply: null,
	handleSave:      null,
	handleReset:     null
});
