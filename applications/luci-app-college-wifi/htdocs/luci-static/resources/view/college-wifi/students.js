'use strict';
'require view';
'require rpc';
'require ui';

/*
 * Student Management View — Phase 3
 * Provides full CRUD, block/unblock, quota reset, and per-student profile
 * navigation backed by real RPC calls to college.wifi.* methods.
 */

/* ---- RPC declarations ---- */
var callGetStudents = rpc.declare({
	object: 'college.wifi',
	method: 'get_students',
	params: ['filter', 'status', 'role', 'limit', 'offset'],
	expect: {}
});

var callAddStudent = rpc.declare({
	object: 'college.wifi',
	method: 'add_student',
	params: ['college_id', 'name', 'phone', 'role', 'quota_bytes', 'status'],
	expect: {}
});

var callUpdateStudent = rpc.declare({
	object: 'college.wifi',
	method: 'update_student',
	params: ['college_id', 'name', 'phone', 'role', 'quota_bytes', 'status'],
	expect: {}
});

var callDeleteStudent = rpc.declare({
	object: 'college.wifi',
	method: 'delete_student',
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

/* ---- Constants ---- */
var MB = 1048576;
var GB = 1073741824;

return view.extend({

	/* ---- initial data load ---- */
	load: function() {
		return callGetStudents('', '', '', 0, 0);
	},

	render: function(data) {
		var result   = data || {};
		var students = result.students || [];

		/* Store for client-side filtering without another RPC call */
		this._allStudents = students;

		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Student Management')),

			/* ---- Summary stat bar ---- */
			this.renderSummaryBar(students),

			/* ---- Toolbar: search + filters + add button ---- */
			this.renderToolbar(),

			/* ---- Student table ---- */
			E('div', { 'id': 'student-table-wrap' },
				this.renderTable(students)
			),

			/* ---- Modals (hidden; shown on demand) ---- */
			this.renderAddModal(),
			this.renderEditModal(),
			this.renderDeleteModal(),
			this.renderQuotaModal()
		]);
	},

	/* ================================================================
	   SUMMARY BAR
	================================================================ */
	renderSummaryBar: function(students) {
		var total    = students.length;
		var active   = students.filter(s => s.status === 'active').length;
		var blocked  = students.filter(s => s.status === 'blocked').length;
		var inactive = students.filter(s => s.status === 'inactive').length;

		var makeCard = function(label, value, color) {
			return E('div', {
				'style': 'background:#fff; border-radius:8px; padding:14px 18px;'
					+ 'border-top:3px solid ' + color + '; box-shadow:0 1px 4px rgba(0,0,0,.08);'
					+ 'min-width:110px;'
			}, [
				E('div', { 'style': 'font-size:11px;color:#6b7a99;font-weight:600;text-transform:uppercase;letter-spacing:.5px;' }, label),
				E('div', { 'style': 'font-size:26px;font-weight:800;color:' + color + ';line-height:1.2;margin-top:4px;' }, String(value))
			]);
		};

		return E('div', {
			'style': 'display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:12px;margin-bottom:20px;'
		}, [
			makeCard(_('Total'),    total,    '#2196F3'),
			makeCard(_('Active'),   active,   '#4CAF50'),
			makeCard(_('Blocked'),  blocked,  '#F44336'),
			makeCard(_('Inactive'), inactive, '#FF9800')
		]);
	},

	/* ================================================================
	   TOOLBAR
	================================================================ */
	renderToolbar: function() {
		return E('div', { 'style': 'display:flex;gap:10px;flex-wrap:wrap;align-items:center;margin-bottom:14px;' }, [

			/* Search input */
			E('div', {
				'style': 'display:flex;align-items:center;gap:8px;background:#fff;border:1px solid #dde2ea;'
					+ 'border-radius:7px;padding:7px 12px;flex:1;min-width:200px;'
			}, [
				E('span', {}, '🔍'),
				E('input', {
					'type':        'text',
					'id':          'cw-search',
					'placeholder': _('Search by College ID or name…'),
					'style':       'border:none;outline:none;background:transparent;font-size:13px;width:100%;',
					'input':       ui.createHandlerFn(this, this.applyFilters)
				})
			]),

			/* Status filter */
			E('select', {
				'id':     'cw-filter-status',
				'change': ui.createHandlerFn(this, this.applyFilters),
				'style':  'background:#fff;border:1px solid #dde2ea;border-radius:7px;padding:7px 12px;font-size:13px;cursor:pointer;outline:none;'
			}, [
				E('option', { 'value': '' },         _('All Status')),
				E('option', { 'value': 'active' },   _('Active')),
				E('option', { 'value': 'blocked' },  _('Blocked')),
				E('option', { 'value': 'inactive' }, _('Inactive'))
			]),

			/* Quota filter */
			E('select', {
				'id':     'cw-filter-quota',
				'change': ui.createHandlerFn(this, this.applyFilters),
				'style':  'background:#fff;border:1px solid #dde2ea;border-radius:7px;padding:7px 12px;font-size:13px;cursor:pointer;outline:none;'
			}, [
				E('option', { 'value': '' },        _('All Quota Usage')),
				E('option', { 'value': 'critical' }, _('Critical (≥90%)')),
				E('option', { 'value': 'warning' },  _('Warning (≥75%)')),
				E('option', { 'value': 'ok' },       _('Healthy (<75%)'))
			]),

			/* Add button */
			E('button', {
				'class': 'cbi-button cbi-button-add',
				'click': ui.createHandlerFn(this, this.openAddModal)
			}, '➕ ' + _('Add Student'))
		]);
	},

	/* ================================================================
	   CLIENT-SIDE FILTERING
	================================================================ */
	applyFilters: function() {
		var q       = (document.getElementById('cw-search')        || {}).value || '';
		var status  = (document.getElementById('cw-filter-status') || {}).value || '';
		var quotaF  = (document.getElementById('cw-filter-quota')  || {}).value || '';

		var filtered = (this._allStudents || []).filter(function(s) {
			/* text search */
			if (q) {
				var hay = (s.college_id + ' ' + s.name).toLowerCase();
				if (hay.indexOf(q.toLowerCase()) === -1) return false;
			}
			/* status filter */
			if (status && s.status !== status) return false;
			/* quota usage filter */
			if (quotaF) {
				var pct = s.quota_bytes > 0 ? (s.used_bytes / s.quota_bytes) : 0;
				if (quotaF === 'critical' && pct < 0.9)  return false;
				if (quotaF === 'warning'  && pct < 0.75) return false;
				if (quotaF === 'ok'       && pct >= 0.75) return false;
			}
			return true;
		});

		var wrap = document.getElementById('student-table-wrap');
		if (wrap) {
			var newTable = this.renderTable(filtered);
			wrap.replaceChild(newTable, wrap.firstChild);
		}
	},

	/* ================================================================
	   TABLE
	================================================================ */
	renderTable: function(students) {
		if (!students || students.length === 0) {
			return E('div', {
				'style': 'background:#fafafa;border:2px dashed #dde2ea;border-radius:10px;'
					+ 'padding:40px;text-align:center;color:#6b7a99;'
			}, [
				E('div', { 'style': 'font-size:36px;margin-bottom:12px;' }, '👥'),
				E('div', { 'style': 'font-size:15px;' }, _('No students found'))
			]);
		}

		var self = this;

		var rows = students.map(function(s) {
			var pct      = s.quota_bytes > 0 ? Math.min(100, Math.round((s.used_bytes / s.quota_bytes) * 100)) : 0;
			var barColor = pct >= 100 ? '#F44336' : pct >= 90 ? '#F44336' : pct >= 75 ? '#FF9800' : '#4CAF50';
			var badgeCSS = s.status === 'active'
				? 'background:#e8f5e9;color:#2e7d32;'
				: s.status === 'blocked'
					? 'background:#ffebee;color:#c62828;'
					: 'background:#fff3e0;color:#6d3200;';

			return E('tr', { 'class': 'tr' }, [
				/* College ID */
				E('td', { 'class': 'td' }, [
					E('span', { 'style': 'background:#e3f2fd;color:#1565c0;padding:2px 8px;border-radius:12px;font-size:12px;font-weight:700;' }, s.college_id)
				]),
				/* Name */
				E('td', { 'class': 'td', 'style': 'font-weight:600;' }, s.name),
				/* Phone (masked) */
				E('td', { 'class': 'td', 'style': 'font-family:monospace;font-size:12px;color:#6b7a99;' }, s.phone_masked || '**********'),
				/* Quota progress */
				E('td', { 'class': 'td', 'style': 'min-width:160px;' }, [
					E('div', { 'style': 'background:#eee;border-radius:10px;height:7px;overflow:hidden;margin-bottom:4px;' }, [
						E('div', { 'style': 'width:' + pct + '%;height:100%;background:' + barColor + ';border-radius:10px;' })
					]),
					E('div', { 'style': 'font-size:11px;color:#6b7a99;' }, self.fmtBytes(s.used_bytes) + ' / ' + self.fmtBytes(s.quota_bytes) + ' (' + pct + '%)')
				]),
				/* Remaining */
				E('td', { 'class': 'td' }, E('span', { 'style': 'font-weight:700;color:' + barColor + ';' }, self.fmtBytes(s.remaining_bytes))),
				/* Status badge */
				E('td', { 'class': 'td' }, [
					E('span', { 'style': 'padding:3px 10px;border-radius:12px;font-size:11px;font-weight:700;' + badgeCSS },
						s.status.charAt(0).toUpperCase() + s.status.slice(1))
				]),
				/* Last login */
				E('td', { 'class': 'td', 'style': 'font-size:12px;color:#6b7a99;white-space:nowrap;' }, s.last_login ? s.last_login.replace('T', ' ').replace('Z', '') : '—'),
				/* Actions */
				E('td', { 'class': 'td', 'style': 'white-space:nowrap;' }, self.renderActions(s))
			]);
		});

		return E('div', { 'class': 'cbi-section', 'style': 'overflow-x:auto;' }, [
			E('table', { 'class': 'table cbi-section-table', 'style': 'width:100%;' }, [
				E('tr', { 'class': 'tr table-titles' }, [
					E('th', { 'class': 'th' }, _('College ID')),
					E('th', { 'class': 'th' }, _('Name')),
					E('th', { 'class': 'th' }, _('Phone')),
					E('th', { 'class': 'th' }, _('Quota Used')),
					E('th', { 'class': 'th' }, _('Remaining')),
					E('th', { 'class': 'th' }, _('Status')),
					E('th', { 'class': 'th' }, _('Last Login')),
					E('th', { 'class': 'th' }, _('Actions'))
				])
			].concat(rows))
		]);
	},

	/* ================================================================
	   ACTION BUTTONS PER ROW
	================================================================ */
	renderActions: function(s) {
		var self = this;
		var btns = [];

		/* View profile */
		btns.push(E('button', {
			'class': 'cbi-button cbi-button-action',
			'style': 'padding:4px 9px;font-size:12px;margin-right:3px;',
			'click': function() { self.openProfile(s.college_id); }
		}, '👁'));

		/* Edit */
		btns.push(E('button', {
			'class': 'cbi-button',
			'style': 'padding:4px 9px;font-size:12px;margin-right:3px;background:#FF9800;color:#fff;border:none;border-radius:4px;cursor:pointer;',
			'click': function() { self.openEditModal(s); }
		}, '✏'));

		/* Reset quota */
		btns.push(E('button', {
			'class': 'cbi-button',
			'style': 'padding:4px 9px;font-size:12px;margin-right:3px;background:#9C27B0;color:#fff;border:none;border-radius:4px;cursor:pointer;',
			'click': function() { self.openQuotaModal(s); }
		}, '🔄'));

		/* Block / Unblock */
		if (s.status === 'blocked') {
			btns.push(E('button', {
				'class': 'cbi-button cbi-button-save',
				'style': 'padding:4px 9px;font-size:12px;margin-right:3px;',
				'click': ui.createHandlerFn(this, 'doUnblock', s.college_id)
			}, _('Unblock')));
		} else {
			btns.push(E('button', {
				'class': 'cbi-button cbi-button-negative',
				'style': 'padding:4px 9px;font-size:12px;margin-right:3px;',
				'click': ui.createHandlerFn(this, 'doBlock', s.college_id)
			}, _('Block')));
		}

		/* Delete */
		btns.push(E('button', {
			'class': 'cbi-button cbi-button-negative',
			'style': 'padding:4px 9px;font-size:12px;',
			'click': function() { self.openDeleteModal(s.college_id, s.name); }
		}, '🗑'));

		return E('span', {}, btns);
	},

	/* ================================================================
	   PROFILE NAVIGATION
	================================================================ */
	openProfile: function(collegeId) {
		window.location.href = L.url('admin/college-wifi/student-profile') + '?id=' + encodeURIComponent(collegeId);
	},

	/* ================================================================
	   ADD MODAL
	================================================================ */
	renderAddModal: function() {
		return E('div', {
			'id':    'cw-modal-add',
			'style': 'display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:1000;align-items:center;justify-content:center;'
		}, [
			E('div', { 'style': 'background:#fff;border-radius:12px;width:460px;max-width:95vw;box-shadow:0 20px 60px rgba(0,0,0,.2);' }, [
				E('div', { 'style': 'padding:18px 22px 14px;border-bottom:1px solid #dde2ea;display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'font-size:16px;font-weight:700;margin:0;' }, '➕ ' + _('Add New Student')),
					E('button', {
						'style': 'border:none;background:none;font-size:20px;cursor:pointer;color:#6b7a99;',
						'click': function() { document.getElementById('cw-modal-add').style.display = 'none'; }
					}, '✕')
				]),
				E('div', { 'style': 'padding:20px 22px;' }, [
					this.formRow('cw-add-college-id', _('College ID *'), 'text', 'e.g. DSU016', true),
					this.formRow('cw-add-name',       _('Full Name *'),  'text', _('Student full name'), true),
					this.formRow('cw-add-phone',      _('Phone Number *'), 'text', '10-digit mobile number', true),
					E('div', { 'style': 'margin-bottom:14px;' }, [
						E('label', { 'style': 'display:block;font-size:12px;font-weight:600;color:#6b7a99;margin-bottom:5px;text-transform:uppercase;' }, _('Role')),
						E('select', {
							'id':    'cw-add-role',
							'style': 'width:100%;border:1px solid #dde2ea;border-radius:6px;padding:8px 12px;font-size:13px;outline:none;'
						}, [
							E('option', { 'value': 'student' },       _('Student')),
							E('option', { 'value': 'network_admin' }, _('Network Administrator')),
							E('option', { 'value': 'administrator' }, _('Administrator'))
						])
					]),
					this.formRow('cw-add-quota-mb', _('Data Quota (MB) *'), 'number', '1024', true),
					E('div', { 'style': 'font-size:11px;color:#6b7a99;margin-top:-10px;margin-bottom:14px;' }, _('Default: 1024 MB = 1 GiB. Enter whole number of MB.'))
				]),
				E('div', { 'style': 'padding:12px 22px 18px;display:flex;gap:10px;justify-content:flex-end;' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function() { document.getElementById('cw-modal-add').style.display = 'none'; }
					}, _('Cancel')),
					E('button', {
						'class': 'cbi-button cbi-button-add',
						'click': ui.createHandlerFn(this, 'submitAdd')
					}, _('Add Student'))
				])
			])
		]);
	},

	openAddModal: function() {
		var m = document.getElementById('cw-modal-add');
		if (m) { m.style.display = 'flex'; }
	},

	submitAdd: function() {
		var cid   = (document.getElementById('cw-add-college-id') || {}).value || '';
		var name  = (document.getElementById('cw-add-name')       || {}).value || '';
		var phone = (document.getElementById('cw-add-phone')      || {}).value || '';
		var role  = (document.getElementById('cw-add-role')       || {}).value || 'student';
		var qmb   = parseInt((document.getElementById('cw-add-quota-mb') || {}).value || '1024', 10);

		/* Client-side pre-validation for UX (server always re-validates) */
		if (!cid.trim())   { ui.addNotification(null, E('p', {}, _('College ID is required.')),   'error'); return; }
		if (!name.trim())  { ui.addNotification(null, E('p', {}, _('Name is required.')),          'error'); return; }
		if (!phone.trim()) { ui.addNotification(null, E('p', {}, _('Phone number is required.')), 'error'); return; }
		if (isNaN(qmb) || qmb < 1) { ui.addNotification(null, E('p', {}, _('Quota must be at least 1 MB.')), 'error'); return; }

		document.getElementById('cw-modal-add').style.display = 'none';

		return callAddStudent(cid.trim().toUpperCase(), name.trim(), phone.trim(), role, qmb * MB, 'active')
			.then(L.bind(function(res) {
				if (res && res.success) {
					ui.addNotification(null,
						E('p', {}, _('Student ') + cid.trim().toUpperCase() + _(' added successfully.')),
						'info');
					return this.load().then(L.bind(function(data) {
						this._allStudents = (data || {}).students || [];
						this.applyFilters();
					}, this));
				} else {
					ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
				}
			}, this));
	},

	/* ================================================================
	   EDIT MODAL
	================================================================ */
	renderEditModal: function() {
		return E('div', {
			'id':    'cw-modal-edit',
			'style': 'display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:1000;align-items:center;justify-content:center;'
		}, [
			E('div', { 'style': 'background:#fff;border-radius:12px;width:460px;max-width:95vw;box-shadow:0 20px 60px rgba(0,0,0,.2);' }, [
				E('div', { 'style': 'padding:18px 22px 14px;border-bottom:1px solid #dde2ea;display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'font-size:16px;font-weight:700;margin:0;' }, '✏ ' + _('Edit Student')),
					E('button', {
						'style': 'border:none;background:none;font-size:20px;cursor:pointer;color:#6b7a99;',
						'click': function() { document.getElementById('cw-modal-edit').style.display = 'none'; }
					}, '✕')
				]),
				E('div', { 'style': 'padding:20px 22px;' }, [
					E('div', { 'style': 'margin-bottom:14px;padding:10px;background:#f0f2f5;border-radius:6px;font-size:12px;color:#6b7a99;' },
						_('College ID cannot be changed as it is the primary institutional identifier.')),
					E('div', { 'style': 'margin-bottom:14px;' }, [
						E('label', { 'style': 'display:block;font-size:12px;font-weight:600;color:#6b7a99;margin-bottom:5px;text-transform:uppercase;' }, _('College ID (read-only)')),
						E('input', { 'id': 'cw-edit-college-id', 'type': 'text', 'readonly': true,
							'style': 'width:100%;border:1px solid #dde2ea;border-radius:6px;padding:8px 12px;font-size:13px;background:#f5f5f5;' })
					]),
					this.formRow('cw-edit-name',  _('Full Name'),     'text', '', false),
					this.formRow('cw-edit-phone', _('Phone Number'),  'text', _('Leave blank to keep existing'), false),
					E('div', { 'style': 'margin-bottom:14px;' }, [
						E('label', { 'style': 'display:block;font-size:12px;font-weight:600;color:#6b7a99;margin-bottom:5px;text-transform:uppercase;' }, _('Role')),
						E('select', {
							'id':    'cw-edit-role',
							'style': 'width:100%;border:1px solid #dde2ea;border-radius:6px;padding:8px 12px;font-size:13px;outline:none;'
						}, [
							E('option', { 'value': 'student' },       _('Student')),
							E('option', { 'value': 'network_admin' }, _('Network Administrator')),
							E('option', { 'value': 'administrator' }, _('Administrator'))
						])
					]),
					E('div', { 'style': 'margin-bottom:14px;' }, [
						E('label', { 'style': 'display:block;font-size:12px;font-weight:600;color:#6b7a99;margin-bottom:5px;text-transform:uppercase;' }, _('Status')),
						E('select', {
							'id':    'cw-edit-status',
							'style': 'width:100%;border:1px solid #dde2ea;border-radius:6px;padding:8px 12px;font-size:13px;outline:none;'
						}, [
							E('option', { 'value': 'active' },   _('Active')),
							E('option', { 'value': 'inactive' }, _('Inactive')),
							E('option', { 'value': 'blocked' },  _('Blocked'))
						])
					]),
					this.formRow('cw-edit-quota-mb', _('Data Quota (MB)'), 'number', '', false)
				]),
				E('div', { 'style': 'padding:12px 22px 18px;display:flex;gap:10px;justify-content:flex-end;' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function() { document.getElementById('cw-modal-edit').style.display = 'none'; }
					}, _('Cancel')),
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'submitEdit')
					}, _('Save Changes'))
				])
			])
		]);
	},

	openEditModal: function(s) {
		var setValue = function(id, val) {
			var el = document.getElementById(id);
			if (el) el.value = val || '';
		};
		setValue('cw-edit-college-id', s.college_id);
		setValue('cw-edit-name',       s.name);
		setValue('cw-edit-phone',      '');
		setValue('cw-edit-quota-mb',   Math.round((s.quota_bytes || GB) / MB));

		var roleEl   = document.getElementById('cw-edit-role');
		var statusEl = document.getElementById('cw-edit-status');
		if (roleEl)   roleEl.value   = s.role   || 'student';
		if (statusEl) statusEl.value = s.status || 'active';

		var m = document.getElementById('cw-modal-edit');
		if (m) m.style.display = 'flex';
	},

	submitEdit: function() {
		var cid    = (document.getElementById('cw-edit-college-id') || {}).value || '';
		var name   = (document.getElementById('cw-edit-name')       || {}).value || '';
		var phone  = (document.getElementById('cw-edit-phone')      || {}).value || '';
		var role   = (document.getElementById('cw-edit-role')       || {}).value || '';
		var status = (document.getElementById('cw-edit-status')     || {}).value || '';
		var qmb    = parseInt((document.getElementById('cw-edit-quota-mb') || {}).value || '0', 10);

		document.getElementById('cw-modal-edit').style.display = 'none';

		return callUpdateStudent(cid, name || '', phone || '', role, qmb > 0 ? qmb * MB : 0, status)
			.then(L.bind(function(res) {
				if (res && res.success) {
					ui.addNotification(null, E('p', {}, _('Student ') + cid + _(' updated.')), 'info');
					return this.load().then(L.bind(function(data) {
						this._allStudents = (data || {}).students || [];
						this.applyFilters();
					}, this));
				} else {
					ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
				}
			}, this));
	},

	/* ================================================================
	   DELETE MODAL
	================================================================ */
	renderDeleteModal: function() {
		return E('div', {
			'id':    'cw-modal-delete',
			'style': 'display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:1000;align-items:center;justify-content:center;'
		}, [
			E('div', { 'style': 'background:#fff;border-radius:12px;width:400px;max-width:95vw;box-shadow:0 20px 60px rgba(0,0,0,.2);' }, [
				E('div', { 'style': 'padding:18px 22px 14px;border-bottom:1px solid #dde2ea;' }, [
					E('h3', { 'style': 'font-size:16px;font-weight:700;margin:0;color:#c62828;' }, '🗑 ' + _('Delete Student'))
				]),
				E('div', { 'style': 'padding:20px 22px;' }, [
					E('p', {}, _('Are you sure you want to permanently delete')),
					E('p', { 'style': 'font-weight:700;font-size:15px;' }, [
						E('span', { 'id': 'cw-delete-name' })
					]),
					E('p', { 'style': 'color:#c62828;font-size:13px;' }, _('This action cannot be undone. All student data will be removed.'))
				]),
				E('div', { 'style': 'padding:12px 22px 18px;display:flex;gap:10px;justify-content:flex-end;' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function() { document.getElementById('cw-modal-delete').style.display = 'none'; }
					}, _('Cancel')),
					E('button', {
						'class': 'cbi-button cbi-button-negative',
						'click': ui.createHandlerFn(this, 'submitDelete')
					}, _('Delete'))
				])
			])
		]);
	},

	openDeleteModal: function(collegeId, name) {
		var el = document.getElementById('cw-delete-name');
		if (el) el.textContent = name + ' (' + collegeId + ')';
		/* Store the id for submitDelete */
		var m = document.getElementById('cw-modal-delete');
		if (m) { m.dataset.collegeId = collegeId; m.style.display = 'flex'; }
	},

	submitDelete: function() {
		var m = document.getElementById('cw-modal-delete');
		var cid = m ? m.dataset.collegeId : '';
		m.style.display = 'none';
		if (!cid) return;

		return callDeleteStudent(cid).then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, _('Student ') + cid + _(' deleted.')), 'info');
				return this.load().then(L.bind(function(data) {
					this._allStudents = (data || {}).students || [];
					this.applyFilters();
				}, this));
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
			}
		}, this));
	},

	/* ================================================================
	   QUOTA MODAL
	================================================================ */
	renderQuotaModal: function() {
		return E('div', {
			'id':    'cw-modal-quota',
			'style': 'display:none;position:fixed;inset:0;background:rgba(0,0,0,.5);z-index:1000;align-items:center;justify-content:center;'
		}, [
			E('div', { 'style': 'background:#fff;border-radius:12px;width:400px;max-width:95vw;box-shadow:0 20px 60px rgba(0,0,0,.2);' }, [
				E('div', { 'style': 'padding:18px 22px 14px;border-bottom:1px solid #dde2ea;display:flex;align-items:center;justify-content:space-between;' }, [
					E('h3', { 'style': 'font-size:16px;font-weight:700;margin:0;' }, '🔄 ' + _('Reset / Set Quota')),
					E('button', {
						'style': 'border:none;background:none;font-size:20px;cursor:pointer;color:#6b7a99;',
						'click': function() { document.getElementById('cw-modal-quota').style.display = 'none'; }
					}, '✕')
				]),
				E('div', { 'style': 'padding:20px 22px;' }, [
					E('div', { 'style': 'margin-bottom:14px;padding:12px;background:#f3e5f5;border-radius:6px;' }, [
						E('div', { 'style': 'font-size:12px;color:#6b7a99;' }, _('Student')),
						E('div', { 'style': 'font-size:15px;font-weight:700;', 'id': 'cw-quota-label' })
					]),
					this.formRow('cw-quota-mb', _('New Quota (MB)'), 'number', '1024', true),
					E('div', { 'style': 'font-size:11px;color:#6b7a99;margin-top:-10px;margin-bottom:14px;' },
						_('Usage will be reset to 0. Student will be unblocked if currently blocked.')),
					E('div', { 'style': 'font-size:12px;padding:10px;background:#e3f2fd;border-radius:6px;' },
						_('Note: Actual network enforcement will be added in Phase 5.'))
				]),
				E('div', { 'style': 'padding:12px 22px 18px;display:flex;gap:10px;justify-content:flex-end;' }, [
					E('button', {
						'class': 'cbi-button',
						'click': function() { document.getElementById('cw-modal-quota').style.display = 'none'; }
					}, _('Cancel')),
					E('button', {
						'class': 'cbi-button cbi-button-apply',
						'click': ui.createHandlerFn(this, 'submitQuota')
					}, _('Reset Quota'))
				])
			])
		]);
	},

	openQuotaModal: function(s) {
		var lbl = document.getElementById('cw-quota-label');
		if (lbl) lbl.textContent = s.name + ' (' + s.college_id + ')';
		var inp = document.getElementById('cw-quota-mb');
		if (inp) inp.value = Math.round((s.quota_bytes || GB) / MB);
		var m = document.getElementById('cw-modal-quota');
		if (m) { m.dataset.collegeId = s.college_id; m.style.display = 'flex'; }
	},

	submitQuota: function() {
		var m   = document.getElementById('cw-modal-quota');
		var cid = m ? m.dataset.collegeId : '';
		var qmb = parseInt((document.getElementById('cw-quota-mb') || {}).value || '1024', 10);
		m.style.display = 'none';
		if (!cid) return;

		return callResetQuota(cid, qmb * MB).then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null,
					E('p', {}, _('Quota for ') + cid + _(' reset to ') + qmb + ' MB.'),
					'info');
				return this.load().then(L.bind(function(data) {
					this._allStudents = (data || {}).students || [];
					this.applyFilters();
				}, this));
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
			}
		}, this));
	},

	/* ================================================================
	   BLOCK / UNBLOCK (direct actions, no confirmation modal)
	================================================================ */
	doBlock: function(collegeId) {
		return callBlockStudent(collegeId).then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, collegeId + _(' blocked.')), 'info');
				return this.load().then(L.bind(function(data) {
					this._allStudents = (data || {}).students || [];
					this.applyFilters();
				}, this));
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
			}
		}, this));
	},

	doUnblock: function(collegeId) {
		return callUnblockStudent(collegeId).then(L.bind(function(res) {
			if (res && res.success) {
				ui.addNotification(null, E('p', {}, collegeId + _(' unblocked.')), 'info');
				return this.load().then(L.bind(function(data) {
					this._allStudents = (data || {}).students || [];
					this.applyFilters();
				}, this));
			} else {
				ui.addNotification(null, E('p', {}, _('Error: ') + (res.error || 'Unknown error')), 'error');
			}
		}, this));
	},

	/* ================================================================
	   HELPERS
	================================================================ */
	formRow: function(id, label, type, placeholder, required) {
		return E('div', { 'style': 'margin-bottom:14px;' }, [
			E('label', { 'style': 'display:block;font-size:12px;font-weight:600;color:#6b7a99;margin-bottom:5px;text-transform:uppercase;' }, label),
			E('input', {
				'id':          id,
				'type':        type,
				'placeholder': placeholder || '',
				'required':    required ? 'required' : null,
				'style':       'width:100%;border:1px solid #dde2ea;border-radius:6px;padding:8px 12px;font-size:13px;outline:none;'
			})
		]);
	},

	/** Format bytes → human-readable string */
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
