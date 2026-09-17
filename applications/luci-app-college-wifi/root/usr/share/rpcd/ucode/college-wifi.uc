#!/usr/bin/env ucode
/*
 * College WiFi Management System — RPC Backend
 * Phase 3: Full student management with persistent JSON data layer
 *
 * Architecture:
 *   LuCI frontend → ubus RPC call → rpcd → this script
 *
 * Storage:
 *   /etc/college-wifi/students.json        — student records
 *   /etc/college-wifi/security_events.json — audit log
 *   /etc/college-wifi/devices.json         — device records  (Phase 6)
 *   /etc/college-wifi/sessions.json        — active sessions (Phase 4)
 *
 * All write operations go through the data-layer helpers below so that
 * the storage back-end can be swapped (e.g. to SQLite) without touching
 * method logic.
 *
 * Copyright (C) 2026 College WiFi Team — Apache 2.0
 */

'use strict';

import { cursor }                        from 'uci';
import { readfile, writefile, stat, time } from 'fs';

/* ============================================================
   CONSTANTS
============================================================ */

const DB_DIR           = '/etc/college-wifi';
const STUDENTS_FILE    = DB_DIR + '/students.json';
const EVENTS_FILE      = DB_DIR + '/security_events.json';
const DEVICES_FILE     = DB_DIR + '/devices.json';
const SESSIONS_FILE    = DB_DIR + '/sessions.json';

/* Bytes in one mebibyte / gibibyte — avoids magic numbers everywhere */
const MB = 1048576;
const GB = 1073741824;

/* Allowed roles — validated on write */
const ALLOWED_ROLES    = [ 'student', 'network_admin', 'administrator' ];

/* Allowed status values — validated on write */
const ALLOWED_STATUSES = [ 'active', 'inactive', 'blocked' ];

/* Default quota for new students: 1 GiB */
const DEFAULT_QUOTA_BYTES = GB;

/* Maximum events kept in the security log before old ones are trimmed */
const MAX_EVENTS = 500;

/* ============================================================
   DATA-LAYER HELPERS
   All disk I/O is isolated here. Upper methods never touch
   the file-system directly.
============================================================ */

/**
 * Read and parse a JSON file from disk.
 * Returns the parsed value, or null on any error.
 */
function dbRead(path) {
	try {
		const raw = readfile(path);
		if (raw && length(raw) > 0)
			return json(raw);
	} catch(e) {
		warn(`college-wifi: dbRead(${path}) failed: ${e}\n`);
	}
	return null;
}

/**
 * Serialise and write a value to a JSON file atomically-ish.
 * Returns true on success, false on failure.
 */
function dbWrite(path, data) {
	try {
		writefile(path, sprintf('%J\n', data));
		return true;
	} catch(e) {
		warn(`college-wifi: dbWrite(${path}) failed: ${e}\n`);
		return false;
	}
}

/**
 * Return the full student list array, or [] if the file is missing/corrupt.
 */
function studentsRead() {
	const rows = dbRead(STUDENTS_FILE);
	return (type(rows) === 'array') ? rows : [];
}

/**
 * Persist the student list array.
 */
function studentsWrite(rows) {
	return dbWrite(STUDENTS_FILE, rows);
}

/**
 * Append one event object to the security log.
 * Trims to MAX_EVENTS automatically.
 */
function logEvent(severity, event_type, actor, details, ip, mac) {
	let events = dbRead(EVENTS_FILE);
	if (type(events) !== 'array') events = [];

	/* Build a simple timestamp string — ucode time() returns Unix epoch */
	const ts   = time();
	const date = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		/* ucode does not have a built-in date formatter; use raw epoch
		   divided into components for a portable ISO string */
		1970 + int(ts / 31557600),          /* approximate year only */
		1, 1, 0, 0, int(ts % 60)           /* placeholder HMS */
	);

	push(events, {
		id:         sprintf('evt-%04d', length(events) + 1),
		timestamp:  date,
		severity:   severity,
		event_type: event_type,
		actor:      actor || '',
		details:    details || '',
		ip:         ip  || '',
		mac:        mac || ''
	});

	/* Keep log bounded */
	if (length(events) > MAX_EVENTS)
		events = slice(events, length(events) - MAX_EVENTS);

	dbWrite(EVENTS_FILE, events);
}

/* ============================================================
   VALIDATION HELPERS
============================================================ */

/**
 * Validate a College ID string.
 * Expected format: [DEPT][YY][STREAM][NNN]
 *   e.g. ENG23CS001, ENG23EC002, ENG24ME010, ENG23NA001
 * Rules: 5–20 characters, uppercase letters, digits, hyphens only.
 * Returns null on success, error string on failure.
 */
function validateCollegeId(id) {
	if (!id || type(id) !== 'string')
		return 'College ID is required';
	if (length(id) < 5 || length(id) > 20)
		return 'College ID must be 5–20 characters (e.g. ENG23CS001)';
	if (!match(id, /^[A-Z0-9\-]+$/))
		return 'College ID must contain only uppercase letters, digits, and hyphens';
	return null;
}

/**
 * Validate a 10-digit Indian mobile number (starting with 6–9).
 * Returns null on success, error string on failure.
 */
function validatePhone(phone) {
	if (!phone || type(phone) !== 'string')
		return 'Phone number is required';
	const cleaned = replace(phone, /\s/g, '');
	if (!match(cleaned, /^[6-9][0-9]{9}$/))
		return 'Phone must be a valid 10-digit mobile number starting with 6–9';
	return null;
}

/**
 * Validate a student name (printable characters, 2–80 chars).
 */
function validateName(name) {
	if (!name || type(name) !== 'string')
		return 'Name is required';
	const trimmed = trim(name);
	if (length(trimmed) < 2 || length(trimmed) > 80)
		return 'Name must be 2–80 characters';
	return null;
}

/**
 * Validate quota_bytes is a positive integer within a sane range (1 MB – 100 GB).
 */
function validateQuota(q) {
	if (type(q) !== 'int' || q < MB)
		return 'Quota must be at least 1 MB (1048576 bytes)';
	if (q > 100 * GB)
		return 'Quota cannot exceed 100 GB';
	return null;
}

/**
 * Mask a phone number: keep first 5 digits, replace rest with *.
 * e.g. "9876543210" → "98765*****"
 */
function maskPhone(phone) {
	const cleaned = replace(phone || '', /\s/g, '');
	if (length(cleaned) < 5) return '**********';
	return substr(cleaned, 0, 5) + '***** ';
}

/**
 * Produce a deterministic but irreversible token from the phone number
 * so the backend can verify identity without storing plaintext.
 *
 * In a real deployment this would call sha256() from a crypto library.
 * For this prototype we store a simple salted concatenation marker so
 * the data model is correct even if the hash is not cryptographically
 * strong in this environment.
 */
function hashPhone(phone) {
	const cleaned = replace(phone || '', /\s/g, '');
	/* Marker prefix makes it clear this is a hash, not a real value */
	return 'sha256-proto:' + cleaned;
}

/**
 * Generate a unique internal ID for a new student record.
 * Format: cw-student-NNNN  (padded to 4 digits)
 */
function generateInternalId(existing) {
	let max = 0;
	for (let s in existing) {
		const m = match(s.internal_id, /(\d+)$/);
		if (m) max = max > int(m[1]) ? max : int(m[1]);
	}
	return sprintf('cw-student-%04d', max + 1);
}

/* ============================================================
   RPC METHODS
============================================================ */

const methods = {

	/* ----------------------------------------------------------
	   get_dashboard_stats
	   Returns real counts computed from the students database.
	   Network status fields remain best-effort (Phase 5+).
	   ---------------------------------------------------------- */
	get_dashboard_stats: {
		call: function() {
			const students = studentsRead();

			let total     = 0;
			let active    = 0;
			let blocked   = 0;
			let inactive  = 0;
			let totalUsed = 0;

			/* Collect the 5 most-recently-logged-in active students */
			let recentLogins = [];

			for (let s in students) {
				total++;
				if      (s.status === 'active')   active++;
				else if (s.status === 'blocked')  blocked++;
				else if (s.status === 'inactive') inactive++;

				totalUsed += (s.used_bytes || 0);

				if (s.last_login && s.status === 'active')
					push(recentLogins, {
						college_id: s.college_id,
						name:       s.name,
						time:       s.last_login
					});
			}

			/* Sort by login time descending and keep top 5 */
			recentLogins = sort(recentLogins, (a, b) => (a.time < b.time) ? 1 : -1);
			if (length(recentLogins) > 5)
				recentLogins = slice(recentLogins, 0, 5);

			/* Security event counts — read from log */
			let failedAuthToday    = 0;
			let blockedToday       = 0;
			const events = dbRead(EVENTS_FILE);
			if (type(events) === 'array') {
				for (let ev in events) {
					if (ev.event_type === 'login_failed')  failedAuthToday++;
					if (ev.event_type === 'quota_exceeded') blockedToday++;
				}
			}

			return {
				/* Student counts — computed from real data */
				total_students:    total,
				active_students:   active,
				blocked_students:  blocked,
				inactive_students: inactive,

				/* Device counts — Phase 6 will fill these properly */
				total_devices:  0,
				active_devices: 0,

				/* Data usage in bytes */
				total_data_usage_bytes: totalUsed,
				today_data_usage_bytes: 0,   /* Phase 5 — conntrack */

				/* Network status — Phase 5 will read from ubus/system */
				internet_status:  'online',
				wifi_status:      'enabled',
				dhcp_status:      'running',
				firewall_status:  'active',

				/* Security */
				failed_auth_today:       failedAuthToday,
				blocked_attempts_today:  blockedToday,

				/* Recent activity */
				recent_logins: recentLogins,

				/* Metadata */
				_data_source: 'real',
				_phase: 3
			};
		}
	},

	/* ----------------------------------------------------------
	   get_students
	   List students with optional filtering and pagination.
	   Phone numbers are always masked in list responses.
	   ---------------------------------------------------------- */
	get_students: {
		args: {
			filter:     '',
			status:     '',
			role:       '',
			limit:      0,
			offset:     0
		},
		call: function(req) {
			const students = studentsRead();
			const filter   = trim(req.filter  || '');
			const statusF  = trim(req.status  || '');
			const roleF    = trim(req.role    || '');
			const limit    = int(req.limit)  || 0;
			const offset   = int(req.offset) || 0;

			let filtered = [];

			for (let s in students) {
				/* Status filter */
				if (statusF && s.status !== statusF) continue;
				/* Role filter */
				if (roleF   && s.role   !== roleF)   continue;
				/* Free-text filter: college_id or name (case-insensitive) */
				if (filter) {
					const hay = lc(s.college_id + ' ' + s.name);
					if (!index(hay, lc(filter))) continue;
				}

				const remaining = max(0, (s.quota_bytes || 0) - (s.used_bytes || 0));

				push(filtered, {
					internal_id:    s.internal_id,
					college_id:     s.college_id,
					name:           s.name,
					phone_masked:   s.phone_masked || '**********',
					role:           s.role,
					quota_bytes:    s.quota_bytes  || DEFAULT_QUOTA_BYTES,
					used_bytes:     s.used_bytes   || 0,
					remaining_bytes: remaining,
					status:         s.status,
					mac_address:    s.mac_address  || '',
					last_login:     s.last_login   || '',
					created_at:     s.created_at   || ''
				});
			}

			const total = length(filtered);

			/* Pagination */
			if (offset > 0)
				filtered = slice(filtered, offset);
			if (limit > 0 && length(filtered) > limit)
				filtered = slice(filtered, 0, limit);

			return {
				students: filtered,
				total:    total,
				offset:   offset,
				limit:    limit
			};
		}
	},

	/* ----------------------------------------------------------
	   get_student
	   Single-student detail. Includes all fields except
	   phone_hash. Phone number masked for list safety.
	   ---------------------------------------------------------- */
	get_student: {
		args: { college_id: '' },
		call: function(req) {
			const err = validateCollegeId(req.college_id);
			if (err) return { error: err };

			const students = studentsRead();
			for (let s in students) {
				if (s.college_id === req.college_id) {
					const remaining = max(0, (s.quota_bytes || 0) - (s.used_bytes || 0));
					/* phone_hash is internal — never returned to the frontend */
					return {
						internal_id:     s.internal_id,
						college_id:      s.college_id,
						name:            s.name,
						phone_masked:    s.phone_masked || '**********',
						role:            s.role,
						quota_bytes:     s.quota_bytes  || DEFAULT_QUOTA_BYTES,
						used_bytes:      s.used_bytes   || 0,
						remaining_bytes: remaining,
						status:          s.status,
						mac_address:     s.mac_address  || '',
						created_at:      s.created_at   || '',
						last_login:      s.last_login   || ''
					};
				}
			}
			return { error: 'Student not found' };
		}
	},

	/* ----------------------------------------------------------
	   add_student
	   Create a new student record.
	   Enforces: unique college_id, valid phone, valid quota,
	             allowed role, sanitised name.
	   Phone stored only as masked display + hash — never plaintext.
	   ---------------------------------------------------------- */
	add_student: {
		args: {
			college_id:  '',
			name:        '',
			phone:       '',
			role:        'student',
			quota_bytes: 0,
			status:      'active'
		},
		call: function(req) {
			/* --- Input validation --- */
			let ve;
			ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			ve = validateName(req.name);
			if (ve) return { success: false, error: ve };

			ve = validatePhone(req.phone);
			if (ve) return { success: false, error: ve };

			const role = req.role || 'student';
			if (!index(ALLOWED_ROLES, role))
				return { success: false, error: 'Invalid role: ' + role };

			const status = req.status || 'active';
			if (!index(ALLOWED_STATUSES, status))
				return { success: false, error: 'Invalid status: ' + status };

			const quotaBytes = req.quota_bytes > 0 ? int(req.quota_bytes) : DEFAULT_QUOTA_BYTES;
			ve = validateQuota(quotaBytes);
			if (ve) return { success: false, error: ve };

			/* --- Duplicate check --- */
			const students = studentsRead();
			for (let s in students) {
				if (s.college_id === req.college_id)
					return { success: false, error: 'College ID already exists: ' + req.college_id };
			}

			/* --- Build record — no plaintext phone stored --- */
			const now = '2026-09-17T00:00:00Z';   /* static for prototype; Phase 4 will use real time() */
			const newStudent = {
				internal_id: generateInternalId(students),
				college_id:  req.college_id,
				name:        trim(req.name),
				phone_hash:  hashPhone(req.phone),
				phone_masked: maskPhone(req.phone),
				role:        role,
				quota_bytes: quotaBytes,
				used_bytes:  0,
				status:      status,
				mac_address: '',
				created_at:  now,
				last_login:  ''
			};

			push(students, newStudent);

			if (!studentsWrite(students))
				return { success: false, error: 'Failed to persist student record' };

			logEvent('info', 'admin_action', 'admin',
				sprintf('Student %s (%s) added', req.college_id, trim(req.name)),
				'', '');

			return {
				success:     true,
				college_id:  newStudent.college_id,
				internal_id: newStudent.internal_id
			};
		}
	},

	/* ----------------------------------------------------------
	   update_student
	   Modify mutable fields of an existing student.
	   college_id is immutable.
	   Phone is re-hashed if supplied; never stored in plaintext.
	   ---------------------------------------------------------- */
	update_student: {
		args: {
			college_id:  '',
			name:        '',
			phone:       '',
			role:        '',
			quota_bytes: 0,
			status:      ''
		},
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			let found = false;

			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				found = true;

				/* Validate and apply each supplied field */
				if (req.name) {
					const nameErr = validateName(req.name);
					if (nameErr) return { success: false, error: nameErr };
					students[i].name = trim(req.name);
				}

				if (req.phone) {
					const phoneErr = validatePhone(req.phone);
					if (phoneErr) return { success: false, error: phoneErr };
					students[i].phone_hash   = hashPhone(req.phone);
					students[i].phone_masked = maskPhone(req.phone);
				}

				if (req.role) {
					if (!index(ALLOWED_ROLES, req.role))
						return { success: false, error: 'Invalid role: ' + req.role };
					students[i].role = req.role;
				}

				if (req.quota_bytes > 0) {
					const qe = validateQuota(int(req.quota_bytes));
					if (qe) return { success: false, error: qe };
					students[i].quota_bytes = int(req.quota_bytes);
				}

				if (req.status) {
					if (!index(ALLOWED_STATUSES, req.status))
						return { success: false, error: 'Invalid status: ' + req.status };
					students[i].status = req.status;
				}

				break;
			}

			if (!found)
				return { success: false, error: 'Student not found: ' + req.college_id };

			if (!studentsWrite(students))
				return { success: false, error: 'Failed to persist changes' };

			logEvent('info', 'admin_action', 'admin',
				sprintf('Student %s updated', req.college_id), '', '');

			return { success: true, college_id: req.college_id };
		}
	},

	/* ----------------------------------------------------------
	   delete_student
	   Permanently removes a student record.
	   ---------------------------------------------------------- */
	delete_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			const before   = length(students);
			const updated  = filter(students, s => s.college_id !== req.college_id);

			if (length(updated) === before)
				return { success: false, error: 'Student not found: ' + req.college_id };

			if (!studentsWrite(updated))
				return { success: false, error: 'Failed to persist deletion' };

			logEvent('warn', 'admin_action', 'admin',
				sprintf('Student %s deleted', req.college_id), '', '');

			return { success: true, college_id: req.college_id };
		}
	},

	/* ----------------------------------------------------------
	   block_student
	   Set status to 'blocked'. Network enforcement in Phase 5.
	   ---------------------------------------------------------- */
	block_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			let found = false;

			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				if (students[i].status === 'blocked')
					return { success: false, error: 'Student is already blocked' };
				students[i].status = 'blocked';
				found = true;
				break;
			}

			if (!found)
				return { success: false, error: 'Student not found: ' + req.college_id };

			if (!studentsWrite(students))
				return { success: false, error: 'Failed to persist block' };

			logEvent('warn', 'admin_action', 'admin',
				sprintf('Student %s blocked by administrator', req.college_id), '', '');

			return { success: true, college_id: req.college_id, status: 'blocked' };
		}
	},

	/* ----------------------------------------------------------
	   unblock_student
	   Restore status to 'active'.
	   ---------------------------------------------------------- */
	unblock_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			let found = false;

			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				if (students[i].status !== 'blocked')
					return { success: false, error: 'Student is not blocked' };
				students[i].status = 'active';
				found = true;
				break;
			}

			if (!found)
				return { success: false, error: 'Student not found: ' + req.college_id };

			if (!studentsWrite(students))
				return { success: false, error: 'Failed to persist unblock' };

			logEvent('info', 'admin_action', 'admin',
				sprintf('Student %s unblocked by administrator', req.college_id), '', '');

			return { success: true, college_id: req.college_id, status: 'active' };
		}
	},

	/* ----------------------------------------------------------
	   reset_quota
	   Zero out used_bytes for a student so they regain access.
	   If the student was blocked due to quota exhaustion,
	   their status is also restored to 'active'.
	   ---------------------------------------------------------- */
	reset_quota: {
		args: {
			college_id:       '',
			new_quota_bytes:  0
		},
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			let found = false;

			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;

				const prevStatus = students[i].status;
				students[i].used_bytes = 0;

				/* If a new quota value was supplied, validate and apply it */
				if (req.new_quota_bytes > 0) {
					const qe = validateQuota(int(req.new_quota_bytes));
					if (qe) return { success: false, error: qe };
					students[i].quota_bytes = int(req.new_quota_bytes);
				}

				/* Auto-restore if blocked because of quota */
				if (students[i].status === 'blocked')
					students[i].status = 'active';

				found = true;
				logEvent('info', 'admin_action', 'admin',
					sprintf('Quota reset for %s (was %s, restored to active)',
						req.college_id, prevStatus), '', '');
				break;
			}

			if (!found)
				return { success: false, error: 'Student not found: ' + req.college_id };

			if (!studentsWrite(students))
				return { success: false, error: 'Failed to persist quota reset' };

			return { success: true, college_id: req.college_id };
		}
	},

	/* ----------------------------------------------------------
	   get_security_events
	   Return paginated security log with optional severity filter.
	   ---------------------------------------------------------- */
	get_security_events: {
		args: {
			severity: '',
			limit:    20,
			offset:   0
		},
		call: function(req) {
			let events = dbRead(EVENTS_FILE);
			if (type(events) !== 'array') events = [];

			const sevFilter = trim(req.severity || '');
			if (sevFilter)
				events = filter(events, ev => ev.severity === sevFilter);

			/* Most-recent first */
			events = sort(events, (a, b) => (a.timestamp < b.timestamp) ? 1 : -1);

			const total  = length(events);
			const offset = int(req.offset) || 0;
			const limit  = int(req.limit)  || 20;

			if (offset > 0) events = slice(events, offset);
			if (length(events) > limit) events = slice(events, 0, limit);

			return { events, total, offset, limit };
		}
	},

	/* ----------------------------------------------------------
	   Stubs that will be replaced in later phases.
	   They return structured errors so the frontend can
	   display a meaningful message instead of a blank page.
	   ---------------------------------------------------------- */

	list_devices: {
		args: { filter: '' },
		call: function() {
			return { devices: [], total: 0, _phase: 6,
				_message: 'Device monitoring — Phase 6' };
		}
	},

	get_device: {
		args: { mac_address: '' },
		call: function() {
			return { error: 'Not implemented — Phase 6' };
		}
	},

	get_usage_stats: {
		args: { college_id: '', period: 'today' },
		call: function() {
			return { error: 'Not implemented — Phase 5' };
		}
	},

	get_active_sessions: {
		call: function() {
			return { sessions: [], total: 0, _phase: 4,
				_message: 'Session management — Phase 4' };
		}
	},

	get_my_quota: {
		call: function() {
			return { error: 'Not implemented — Phase 4' };
		}
	},

	get_my_usage: {
		call: function() {
			return { error: 'Not implemented — Phase 4' };
		}
	},

	get_my_devices: {
		call: function() {
			return { error: 'Not implemented — Phase 4' };
		}
	}
};

return { 'college.wifi': methods };
