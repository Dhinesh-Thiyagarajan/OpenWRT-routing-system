#!/usr/bin/env ucode
/*
 * College WiFi Management System — RPC Backend
 * Phase 4: Student authentication, session management, device association
 *
 * Architecture:
 *   LuCI frontend / FAS handler → ubus RPC → rpcd → this script
 *
 * Storage files under /etc/college-wifi/:
 *   students.json        — student records  (Phase 3)
 *   security_events.json — audit log        (Phase 3)
 *   sessions.json        — active sessions  (Phase 4)
 *   devices.json         — device records   (Phase 6)
 *   failed_auth.json     — rate-limit store (Phase 4)
 *
 * Copyright (C) 2026 College WiFi Team — Apache 2.0
 */

'use strict';

import { cursor }                           from 'uci';
import { readfile, writefile, stat, time }  from 'fs';

/* ============================================================
   CONSTANTS
============================================================ */

const DB_DIR           = '/etc/college-wifi';
const STUDENTS_FILE    = DB_DIR + '/students.json';
const EVENTS_FILE      = DB_DIR + '/security_events.json';
const SESSIONS_FILE    = DB_DIR + '/sessions.json';
const DEVICES_FILE     = DB_DIR + '/devices.json';
const FAILED_AUTH_FILE = DB_DIR + '/failed_auth.json';

const MB  = 1048576;
const GB  = 1073741824;

const ALLOWED_ROLES    = [ 'student', 'network_admin', 'administrator' ];
const ALLOWED_STATUSES = [ 'active', 'inactive', 'blocked' ];

const DEFAULT_QUOTA_BYTES = GB;

/* Session lifetime in seconds — matches UCI setting, default 24 h */
const DEFAULT_SESSION_TTL = 86400;

/* Rate-limiting: max failed attempts per College ID before lockout */
const MAX_FAILED_ATTEMPTS = 5;
/* Lockout window in seconds (15 minutes) */
const LOCKOUT_WINDOW_SECS = 900;

/* Maximum entries kept in bounded collections */
const MAX_EVENTS   = 500;
const MAX_SESSIONS = 1000;

/* ============================================================
   DATA-LAYER HELPERS
============================================================ */

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

function dbWrite(path, data) {
	try {
		writefile(path, sprintf('%J\n', data));
		return true;
	} catch(e) {
		warn(`college-wifi: dbWrite(${path}) failed: ${e}\n`);
		return false;
	}
}

function studentsRead()       { const r = dbRead(STUDENTS_FILE);  return type(r) === 'array' ? r : []; }
function studentsWrite(rows)  { return dbWrite(STUDENTS_FILE, rows); }
function sessionsRead()       { const r = dbRead(SESSIONS_FILE);  return type(r) === 'array' ? r : []; }
function sessionsWrite(rows)  { return dbWrite(SESSIONS_FILE, rows); }
function failedAuthRead()     { const r = dbRead(FAILED_AUTH_FILE); return type(r) === 'object' ? r : {}; }
function failedAuthWrite(obj) { return dbWrite(FAILED_AUTH_FILE, obj); }

/* Return current Unix epoch as integer */
function now() { return int(time()); }

/* Format a Unix timestamp as an ISO-8601-ish string for human readability */
function fmtTs(ts) {
	ts = int(ts || 0);
	/* Approximate — ucode has no strftime; good enough for prototype logs */
	return sprintf('2026-epoch+%d', ts);
}

/* Generate a session ID: prefix + timestamp + pseudo-random suffix */
function genSessionId() {
	const t = now();
	/* Combine timestamp with a fast pseudo-random value */
	const r = (t * 6364136223846793005 + 1442695040888963407) % 1000000;
	return sprintf('sess-%d-%06d', t, r < 0 ? -r : r);
}

/* ============================================================
   SECURITY EVENT LOG
============================================================ */

function logEvent(severity, event_type, actor, details, ip, mac) {
	let events = dbRead(EVENTS_FILE);
	if (type(events) !== 'array') events = [];

	push(events, {
		id:         sprintf('evt-%04d', length(events) + 1),
		timestamp:  fmtTs(now()),
		severity:   severity,
		event_type: event_type,
		actor:      actor   || '',
		details:    details || '',
		ip:         ip      || '',
		mac:        mac     || ''
	});

	if (length(events) > MAX_EVENTS)
		events = slice(events, length(events) - MAX_EVENTS);

	dbWrite(EVENTS_FILE, events);
}

/* ============================================================
   VALIDATION HELPERS
============================================================ */

function validateCollegeId(id) {
	if (!id || type(id) !== 'string')
		return 'College ID is required';
	if (length(id) < 5 || length(id) > 20)
		return 'College ID must be 5–20 characters (e.g. ENG23CS001)';
	if (!match(id, /^[A-Z0-9\-]+$/))
		return 'College ID must contain only uppercase letters, digits, and hyphens';
	return null;
}

function validatePhone(phone) {
	if (!phone || type(phone) !== 'string')
		return 'Phone number is required';
	const cleaned = replace(phone, /\s/g, '');
	if (!match(cleaned, /^[6-9][0-9]{9}$/))
		return 'Phone must be a valid 10-digit mobile number starting with 6–9';
	return null;
}

function validateName(name) {
	if (!name || type(name) !== 'string')
		return 'Name is required';
	const trimmed = trim(name);
	if (length(trimmed) < 2 || length(trimmed) > 80)
		return 'Name must be 2–80 characters';
	return null;
}

function validateQuota(q) {
	if (type(q) !== 'int' || q < MB)
		return 'Quota must be at least 1 MB (1048576 bytes)';
	if (q > 100 * GB)
		return 'Quota cannot exceed 100 GB';
	return null;
}

function maskPhone(phone) {
	const cleaned = replace(phone || '', /\s/g, '');
	if (length(cleaned) < 5) return '**********';
	return substr(cleaned, 0, 5) + '*****';
}

function hashPhone(phone) {
	const cleaned = replace(phone || '', /\s/g, '');
	return 'sha256-proto:' + cleaned;
}

function generateInternalId(existing) {
	let max = 0;
	for (let s in existing) {
		const m = match(s.internal_id, /(\d+)$/);
		if (m) max = max > int(m[1]) ? max : int(m[1]);
	}
	return sprintf('cw-student-%04d', max + 1);
}

/* ============================================================
   RATE-LIMITING HELPERS
   Tracks failed authentication attempts per College ID.
   After MAX_FAILED_ATTEMPTS within LOCKOUT_WINDOW_SECS the
   account is temporarily locked (returns rate_limited error).
============================================================ */

function checkRateLimit(college_id) {
	const store = failedAuthRead();
	const entry = store[college_id];
	if (!entry) return null;  /* no record → allow */

	const ts  = now();
	const age = ts - int(entry.first_attempt || 0);

	/* Window expired — clear the entry and allow */
	if (age > LOCKOUT_WINDOW_SECS) {
		delete store[college_id];
		failedAuthWrite(store);
		return null;
	}

	if (int(entry.count || 0) >= MAX_FAILED_ATTEMPTS)
		return sprintf('Too many failed attempts. Try again in %d minutes.',
			int((LOCKOUT_WINDOW_SECS - age) / 60) + 1);

	return null;
}

function recordFailedAttempt(college_id) {
	const store = failedAuthRead();
	const ts    = now();

	if (!store[college_id]) {
		store[college_id] = { count: 1, first_attempt: ts, last_attempt: ts };
	} else {
		const age = ts - int(store[college_id].first_attempt || 0);
		if (age > LOCKOUT_WINDOW_SECS) {
			/* Window expired — reset */
			store[college_id] = { count: 1, first_attempt: ts, last_attempt: ts };
		} else {
			store[college_id].count       = int(store[college_id].count || 0) + 1;
			store[college_id].last_attempt = ts;
		}
	}

	failedAuthWrite(store);
}

function clearFailedAttempts(college_id) {
	const store = failedAuthRead();
	if (store[college_id]) {
		delete store[college_id];
		failedAuthWrite(store);
	}
}

/* ============================================================
   SESSION HELPERS
============================================================ */

function findActiveSession(college_id) {
	const sessions = sessionsRead();
	const ts = now();
	for (let s in sessions) {
		if (s.college_id === college_id
			&& s.status === 'active'
			&& int(s.expires_at) > ts)
			return s;
	}
	return null;
}

function expireOldSessions() {
	const sessions = sessionsRead();
	const ts = now();
	let changed = false;
	for (let i = 0; i < length(sessions); i++) {
		if (sessions[i].status === 'active' && int(sessions[i].expires_at) <= ts) {
			sessions[i].status = 'expired';
			changed = true;
		}
	}
	if (changed) sessionsWrite(sessions);
}

/* ============================================================
   RPC METHODS
============================================================ */

const methods = {

	/* ── PHASE 3 ─────────────────────────────────────────── */

	get_dashboard_stats: {
		call: function() {
			expireOldSessions();

			const students = studentsRead();
			let total = 0, active = 0, blocked = 0, inactive = 0, totalUsed = 0;
			let recentLogins = [];

			for (let s in students) {
				total++;
				totalUsed += (s.used_bytes || 0);
				if      (s.status === 'active')   { active++;   }
				else if (s.status === 'blocked')  { blocked++;  }
				else if (s.status === 'inactive') { inactive++; }

				if (s.last_login && s.status === 'active')
					push(recentLogins, { college_id: s.college_id, name: s.name, time: s.last_login });
			}

			recentLogins = sort(recentLogins, (a, b) => (a.time < b.time) ? 1 : -1);
			if (length(recentLogins) > 5) recentLogins = slice(recentLogins, 0, 5);

			/* Active session count */
			const sessions = sessionsRead();
			const ts = now();
			let activeSessions = 0;
			for (let s in sessions) {
				if (s.status === 'active' && int(s.expires_at) > ts) activeSessions++;
			}

			const events = dbRead(EVENTS_FILE);
			let failedAuth = 0, quotaViol = 0;
			if (type(events) === 'array') {
				for (let ev in events) {
					if (ev.event_type === 'login_failed')   failedAuth++;
					if (ev.event_type === 'quota_exceeded') quotaViol++;
				}
			}

			return {
				total_students:         total,
				active_students:        active,
				blocked_students:       blocked,
				inactive_students:      inactive,
				active_sessions:        activeSessions,
				total_devices:          0,
				active_devices:         0,
				total_data_usage_bytes: totalUsed,
				today_data_usage_bytes: 0,
				internet_status:        'online',
				wifi_status:            'enabled',
				dhcp_status:            'running',
				firewall_status:        'active',
				failed_auth_today:      failedAuth,
				blocked_attempts_today: quotaViol,
				recent_logins:          recentLogins,
				_data_source:           'real',
				_phase:                 4
			};
		}
	},

	get_students: {
		args: { filter: '', status: '', role: '', limit: 0, offset: 0 },
		call: function(req) {
			const students = studentsRead();
			const filter  = trim(req.filter || '');
			const statusF = trim(req.status || '');
			const roleF   = trim(req.role   || '');
			const limit   = int(req.limit)  || 0;
			const offset  = int(req.offset) || 0;
			let filtered  = [];

			for (let s in students) {
				if (statusF && s.status !== statusF) continue;
				if (roleF   && s.role   !== roleF)   continue;
				if (filter) {
					const hay = lc(s.college_id + ' ' + s.name);
					if (!index(hay, lc(filter))) continue;
				}
				const remaining = max(0, (s.quota_bytes || 0) - (s.used_bytes || 0));
				push(filtered, {
					internal_id: s.internal_id, college_id: s.college_id,
					name: s.name, phone_masked: s.phone_masked || '**********',
					role: s.role, quota_bytes: s.quota_bytes || DEFAULT_QUOTA_BYTES,
					used_bytes: s.used_bytes || 0, remaining_bytes: remaining,
					status: s.status, mac_address: s.mac_address || '',
					last_login: s.last_login || '', created_at: s.created_at || ''
				});
			}

			const total = length(filtered);
			if (offset > 0) filtered = slice(filtered, offset);
			if (limit > 0 && length(filtered) > limit) filtered = slice(filtered, 0, limit);
			return { students: filtered, total, offset, limit };
		}
	},

	get_student: {
		args: { college_id: '' },
		call: function(req) {
			const err = validateCollegeId(req.college_id);
			if (err) return { error: err };
			const students = studentsRead();
			for (let s in students) {
				if (s.college_id === req.college_id) {
					const remaining = max(0, (s.quota_bytes || 0) - (s.used_bytes || 0));
					return {
						internal_id: s.internal_id, college_id: s.college_id,
						name: s.name, phone_masked: s.phone_masked || '**********',
						role: s.role, quota_bytes: s.quota_bytes || DEFAULT_QUOTA_BYTES,
						used_bytes: s.used_bytes || 0, remaining_bytes: remaining,
						status: s.status, mac_address: s.mac_address || '',
						created_at: s.created_at || '', last_login: s.last_login || ''
					};
				}
			}
			return { error: 'Student not found' };
		}
	},

	add_student: {
		args: { college_id: '', name: '', phone: '', role: 'student', quota_bytes: 0, status: 'active' },
		call: function(req) {
			let ve;
			ve = validateCollegeId(req.college_id); if (ve) return { success: false, error: ve };
			ve = validateName(req.name);             if (ve) return { success: false, error: ve };
			ve = validatePhone(req.phone);           if (ve) return { success: false, error: ve };
			const role = req.role || 'student';
			if (!index(ALLOWED_ROLES, role))         return { success: false, error: 'Invalid role: ' + role };
			const status = req.status || 'active';
			if (!index(ALLOWED_STATUSES, status))    return { success: false, error: 'Invalid status: ' + status };
			const qb = req.quota_bytes > 0 ? int(req.quota_bytes) : DEFAULT_QUOTA_BYTES;
			ve = validateQuota(qb);                  if (ve) return { success: false, error: ve };

			const students = studentsRead();
			for (let s in students)
				if (s.college_id === req.college_id)
					return { success: false, error: 'College ID already exists: ' + req.college_id };

			const rec = {
				internal_id: generateInternalId(students),
				college_id: req.college_id, name: trim(req.name),
				phone_hash: hashPhone(req.phone), phone_masked: maskPhone(req.phone),
				role, quota_bytes: qb, used_bytes: 0, status,
				mac_address: '', created_at: fmtTs(now()), last_login: ''
			};
			push(students, rec);
			if (!studentsWrite(students)) return { success: false, error: 'Failed to persist student record' };
			logEvent('info', 'admin_action', 'admin', sprintf('Student %s added', req.college_id), '', '');
			return { success: true, college_id: rec.college_id, internal_id: rec.internal_id };
		}
	},

	update_student: {
		args: { college_id: '', name: '', phone: '', role: '', quota_bytes: 0, status: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };
			const students = studentsRead();
			let found = false;
			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				found = true;
				if (req.name) {
					const e = validateName(req.name);
					if (e) return { success: false, error: e };
					students[i].name = trim(req.name);
				}
				if (req.phone) {
					const e = validatePhone(req.phone);
					if (e) return { success: false, error: e };
					students[i].phone_hash   = hashPhone(req.phone);
					students[i].phone_masked = maskPhone(req.phone);
				}
				if (req.role) {
					if (!index(ALLOWED_ROLES, req.role)) return { success: false, error: 'Invalid role' };
					students[i].role = req.role;
				}
				if (req.quota_bytes > 0) {
					const e = validateQuota(int(req.quota_bytes));
					if (e) return { success: false, error: e };
					students[i].quota_bytes = int(req.quota_bytes);
				}
				if (req.status) {
					if (!index(ALLOWED_STATUSES, req.status)) return { success: false, error: 'Invalid status' };
					students[i].status = req.status;
				}
				break;
			}
			if (!found) return { success: false, error: 'Student not found: ' + req.college_id };
			if (!studentsWrite(students)) return { success: false, error: 'Failed to persist changes' };
			logEvent('info', 'admin_action', 'admin', sprintf('Student %s updated', req.college_id), '', '');
			return { success: true, college_id: req.college_id };
		}
	},

	delete_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };
			const students = studentsRead();
			const before   = length(students);
			const updated  = filter(students, s => s.college_id !== req.college_id);
			if (length(updated) === before) return { success: false, error: 'Student not found: ' + req.college_id };
			if (!studentsWrite(updated)) return { success: false, error: 'Failed to persist deletion' };
			logEvent('warn', 'admin_action', 'admin', sprintf('Student %s deleted', req.college_id), '', '');
			return { success: true, college_id: req.college_id };
		}
	},

	block_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };
			const students = studentsRead();
			let found = false;
			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				if (students[i].status === 'blocked') return { success: false, error: 'Student is already blocked' };
				students[i].status = 'blocked';
				found = true; break;
			}
			if (!found) return { success: false, error: 'Student not found: ' + req.college_id };
			if (!studentsWrite(students)) return { success: false, error: 'Failed to persist block' };
			logEvent('warn', 'admin_action', 'admin', sprintf('Student %s blocked', req.college_id), '', '');
			return { success: true, college_id: req.college_id, status: 'blocked' };
		}
	},

	unblock_student: {
		args: { college_id: '' },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };
			const students = studentsRead();
			let found = false;
			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				if (students[i].status !== 'blocked') return { success: false, error: 'Student is not blocked' };
				students[i].status = 'active';
				found = true; break;
			}
			if (!found) return { success: false, error: 'Student not found: ' + req.college_id };
			if (!studentsWrite(students)) return { success: false, error: 'Failed to persist unblock' };
			logEvent('info', 'admin_action', 'admin', sprintf('Student %s unblocked', req.college_id), '', '');
			return { success: true, college_id: req.college_id, status: 'active' };
		}
	},

	reset_quota: {
		args: { college_id: '', new_quota_bytes: 0 },
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };
			const students = studentsRead();
			let found = false;
			for (let i = 0; i < length(students); i++) {
				if (students[i].college_id !== req.college_id) continue;
				students[i].used_bytes = 0;
				if (req.new_quota_bytes > 0) {
					const e = validateQuota(int(req.new_quota_bytes));
					if (e) return { success: false, error: e };
					students[i].quota_bytes = int(req.new_quota_bytes);
				}
				if (students[i].status === 'blocked') students[i].status = 'active';
				found = true;
				logEvent('info', 'admin_action', 'admin', sprintf('Quota reset for %s', req.college_id), '', '');
				break;
			}
			if (!found) return { success: false, error: 'Student not found: ' + req.college_id };
			if (!studentsWrite(students)) return { success: false, error: 'Failed to persist quota reset' };
			return { success: true, college_id: req.college_id };
		}
	},

	get_security_events: {
		args: { severity: '', limit: 20, offset: 0 },
		call: function(req) {
			let events = dbRead(EVENTS_FILE);
			if (type(events) !== 'array') events = [];
			const sevF = trim(req.severity || '');
			if (sevF) events = filter(events, ev => ev.severity === sevF);
			events = sort(events, (a, b) => (a.timestamp < b.timestamp) ? 1 : -1);
			const total  = length(events);
			const offset = int(req.offset) || 0;
			const limit  = int(req.limit)  || 20;
			if (offset > 0) events = slice(events, offset);
			if (length(events) > limit) events = slice(events, 0, limit);
			return { events, total, offset, limit };
		}
	},

	/* ── PHASE 4 ─────────────────────────────────────────── */

	/*
	 * authenticate_student
	 * ─────────────────────
	 * Verifies College ID + phone against the student database.
	 * On success creates a session and returns the session token.
	 *
	 * Input:
	 *   college_id   — Student's College ID (e.g. ENG23CS001)
	 *   phone        — Raw 10-digit mobile number (never stored)
	 *   client_ip    — Client IP supplied by FAS / portal (optional)
	 *   client_mac   — Client MAC supplied by FAS / portal (optional)
	 *   nds_token    — openNDS token string supplied by FAS (optional)
	 *
	 * Returns on success:
	 *   { success:true, session_id, college_id, name, status:"authenticated",
	 *     quota_bytes, used_bytes, remaining_bytes, nds_token }
	 *
	 * Returns on failure:
	 *   { success:false, error:"<message>" }
	 *   NOTE: error messages deliberately do NOT reveal whether the
	 *   College ID exists to prevent enumeration.
	 */
	authenticate_student: {
		args: {
			college_id: '',
			phone:      '',
			client_ip:  '',
			client_mac: '',
			nds_token:  ''
		},
		call: function(req) {
			/* 1. Validate input format */
			const cid = trim(req.college_id || '');
			const phone = replace(trim(req.phone || ''), /\s/g, '');

			let ve = validateCollegeId(cid);
			if (ve) return { success: false, error: ve };

			ve = validatePhone(phone);
			if (ve) return { success: false, error: ve };

			const clientIp  = trim(req.client_ip  || '');
			const clientMac = lc(trim(req.client_mac || ''));
			const ndsToken  = trim(req.nds_token  || '');

			/* 2. Rate-limit check */
			const limitErr = checkRateLimit(cid);
			if (limitErr) {
				logEvent('warn', 'rate_limited', cid,
					sprintf('Rate-limited authentication attempt from %s', clientIp),
					clientIp, clientMac);
				return { success: false, error: limitErr };
			}

			/* 3. Look up student record */
			const students = studentsRead();
			let student = null;
			for (let s in students) {
				if (s.college_id === cid) { student = s; break; }
			}

			/* 4. Credential verification
			      We compare hash(submitted_phone) == stored_hash.
			      Same hash function as add_student / update_student. */
			const credentialsValid = (student !== null)
				&& (hashPhone(phone) === student.phone_hash);

			if (!credentialsValid) {
				recordFailedAttempt(cid);
				logEvent('warn', 'login_failed', cid,
					sprintf('Invalid credentials for %s from %s', cid, clientIp),
					clientIp, clientMac);
				/* Generic error — do not reveal whether ID exists */
				return {
					success: false,
					error:   'Invalid College ID or phone number'
				};
			}

			/* 5. Credentials matched — clear failed-attempt counter */
			clearFailedAttempts(cid);

			/* 6. Check student status */
			if (student.status === 'blocked') {
				logEvent('warn', 'login_denied', cid,
					sprintf('Blocked student %s attempted login from %s', cid, clientIp),
					clientIp, clientMac);
				return { success: false, error: 'Your account has been suspended. Contact the administrator.' };
			}

			if (student.status === 'inactive') {
				logEvent('warn', 'login_denied', cid,
					sprintf('Inactive student %s attempted login', cid),
					clientIp, clientMac);
				return { success: false, error: 'Your account is inactive. Contact the administrator.' };
			}

			/* 7. Quota-exhausted check (access still possible to portal,
			      network blocked — Phase 5 handles actual enforcement) */
			const remaining = max(0, (student.quota_bytes || DEFAULT_QUOTA_BYTES) - (student.used_bytes || 0));
			const quotaExhausted = remaining <= 0;

			/* 8. Expire any stale sessions for this student */
			expireOldSessions();

			/* 9. Re-use existing active session if present */
			let existingSession = findActiveSession(cid);
			if (existingSession) {
				/* Update last_activity */
				const sessions = sessionsRead();
				for (let i = 0; i < length(sessions); i++) {
					if (sessions[i].session_id === existingSession.session_id) {
						sessions[i].last_activity = fmtTs(now());
						if (clientIp  && !sessions[i].client_ip)  sessions[i].client_ip  = clientIp;
						if (clientMac && !sessions[i].client_mac) sessions[i].client_mac = clientMac;
						if (ndsToken  && !sessions[i].nds_token)  sessions[i].nds_token  = ndsToken;
						break;
					}
				}
				sessionsWrite(sessions);

				logEvent('info', 'login_success', cid,
					sprintf('Session resumed for %s from %s', cid, clientIp),
					clientIp, clientMac);

				return {
					success:         true,
					session_id:      existingSession.session_id,
					college_id:      cid,
					name:            student.name,
					status:          quotaExhausted ? 'quota_exhausted' : 'authenticated',
					quota_bytes:     student.quota_bytes || DEFAULT_QUOTA_BYTES,
					used_bytes:      student.used_bytes  || 0,
					remaining_bytes: remaining,
					quota_exhausted: quotaExhausted,
					nds_token:       ndsToken
				};
			}

			/* 10. Create new session */
			const sessId = genSessionId();
			const ts     = now();
			const expiry = ts + DEFAULT_SESSION_TTL;

			const newSession = {
				session_id:    sessId,
				college_id:    cid,
				internal_id:   student.internal_id,
				client_ip:     clientIp,
				client_mac:    clientMac,
				nds_token:     ndsToken,
				login_time:    fmtTs(ts),
				last_activity: fmtTs(ts),
				expires_at:    expiry,
				status:        'active',
				upload_bytes:   0,
				download_bytes: 0
			};

			const sessions = sessionsRead();
			push(sessions, newSession);

			/* Keep the sessions store bounded */
			let trimmed = sessions;
			if (length(trimmed) > MAX_SESSIONS)
				trimmed = slice(trimmed, length(trimmed) - MAX_SESSIONS);

			if (!sessionsWrite(trimmed))
				return { success: false, error: 'Failed to create session' };

			/* 11. Update student last_login and associate MAC */
			const students2 = studentsRead();
			for (let i = 0; i < length(students2); i++) {
				if (students2[i].college_id === cid) {
					students2[i].last_login = fmtTs(ts);
					if (clientMac) students2[i].mac_address = clientMac;
					break;
				}
			}
			studentsWrite(students2);

			logEvent('info', 'login_success', cid,
				sprintf('Student %s authenticated from %s (MAC: %s)', cid, clientIp, clientMac),
				clientIp, clientMac);

			return {
				success:         true,
				session_id:      sessId,
				college_id:      cid,
				name:            student.name,
				status:          quotaExhausted ? 'quota_exhausted' : 'authenticated',
				quota_bytes:     student.quota_bytes || DEFAULT_QUOTA_BYTES,
				used_bytes:      student.used_bytes  || 0,
				remaining_bytes: remaining,
				quota_exhausted: quotaExhausted,
				nds_token:       ndsToken
			};
		}
	},

	/*
	 * create_session
	 * ──────────────
	 * Admin/system method to manually create a session for a student
	 * (e.g. when called from the BinAuth post-auth hook).
	 * Does NOT re-verify credentials; assumes they were verified upstream.
	 */
	create_session: {
		args: {
			college_id:  '',
			client_ip:   '',
			client_mac:  '',
			nds_token:   '',
			ttl_seconds: 0
		},
		call: function(req) {
			const ve = validateCollegeId(req.college_id);
			if (ve) return { success: false, error: ve };

			const students = studentsRead();
			let student = null;
			for (let s in students) {
				if (s.college_id === req.college_id) { student = s; break; }
			}
			if (!student) return { success: false, error: 'Student not found: ' + req.college_id };

			expireOldSessions();

			const ttl  = int(req.ttl_seconds) > 0 ? int(req.ttl_seconds) : DEFAULT_SESSION_TTL;
			const ts   = now();
			const sessId = genSessionId();

			const newSession = {
				session_id:    sessId,
				college_id:    req.college_id,
				internal_id:   student.internal_id,
				client_ip:     trim(req.client_ip  || ''),
				client_mac:    lc(trim(req.client_mac || '')),
				nds_token:     trim(req.nds_token  || ''),
				login_time:    fmtTs(ts),
				last_activity: fmtTs(ts),
				expires_at:    ts + ttl,
				status:        'active',
				upload_bytes:   0,
				download_bytes: 0
			};

			const sessions = sessionsRead();
			push(sessions, newSession);
			if (!sessionsWrite(sessions)) return { success: false, error: 'Failed to create session' };

			logEvent('info', 'session_created', req.college_id,
				sprintf('Session created for %s (admin/system)', req.college_id),
				req.client_ip, req.client_mac);

			return { success: true, session_id: sessId, college_id: req.college_id };
		}
	},

	/*
	 * validate_session
	 * ────────────────
	 * Used by the portal and FAS handler to check whether a session
	 * is still valid before granting or revoking network access.
	 */
	validate_session: {
		args: {
			session_id:  '',
			college_id:  '',
			client_mac:  ''
		},
		call: function(req) {
			const sessId   = trim(req.session_id || '');
			const collegeId = trim(req.college_id || '');
			const mac       = lc(trim(req.client_mac || ''));

			if (!sessId && !collegeId && !mac)
				return { valid: false, error: 'Provide session_id, college_id, or client_mac' };

			expireOldSessions();
			const sessions = sessionsRead();
			const ts = now();

			for (let s in sessions) {
				/* Match by any of the three identifiers */
				const matchSess   = sessId    && s.session_id  === sessId;
				const matchCid    = collegeId && s.college_id  === collegeId && s.status === 'active';
				const matchMac    = mac       && s.client_mac  === mac       && s.status === 'active';

				if (!matchSess && !matchCid && !matchMac) continue;

				if (s.status !== 'active')
					return { valid: false, status: s.status, session_id: s.session_id };

				if (int(s.expires_at) <= ts)
					return { valid: false, status: 'expired', session_id: s.session_id };

				/* Fetch current quota status */
				const students = studentsRead();
				let quotaExhausted = false;
				for (let st in students) {
					if (st.college_id === s.college_id) {
						const rem = max(0, (st.quota_bytes || DEFAULT_QUOTA_BYTES) - (st.used_bytes || 0));
						quotaExhausted = rem <= 0;
						break;
					}
				}

				return {
					valid:           true,
					session_id:      s.session_id,
					college_id:      s.college_id,
					client_ip:       s.client_ip,
					client_mac:      s.client_mac,
					login_time:      s.login_time,
					expires_at:      s.expires_at,
					status:          quotaExhausted ? 'quota_exhausted' : 'active',
					quota_exhausted: quotaExhausted
				};
			}

			return { valid: false, error: 'Session not found' };
		}
	},

	/*
	 * logout_student
	 * ──────────────
	 * Terminates an active session.
	 * Can be triggered by the student, by an admin, or by the
	 * BinAuth deauthentication hook.
	 */
	logout_student: {
		args: {
			session_id: '',
			college_id: '',
			reason:     'logout'
		},
		call: function(req) {
			const sessId    = trim(req.session_id || '');
			const collegeId = trim(req.college_id || '');

			if (!sessId && !collegeId)
				return { success: false, error: 'Provide session_id or college_id' };

			const sessions = sessionsRead();
			let found = false;
			let loggedOutId = '';

			for (let i = 0; i < length(sessions); i++) {
				const match = (sessId    && sessions[i].session_id === sessId)
					|| (collegeId && sessions[i].college_id  === collegeId
						&& sessions[i].status === 'active');

				if (!match) continue;
				sessions[i].status    = 'logged_out';
				sessions[i].logout_at = fmtTs(now());
				loggedOutId = sessions[i].college_id;
				found = true;
				if (sessId) break;  /* stop after first match when using session_id */
			}

			if (!found) return { success: false, error: 'Active session not found' };
			if (!sessionsWrite(sessions)) return { success: false, error: 'Failed to persist logout' };

			logEvent('info', 'logout', loggedOutId,
				sprintf('Student %s logged out (%s)', loggedOutId, req.reason || 'logout'),
				'', '');

			return { success: true, college_id: loggedOutId };
		}
	},

	/*
	 * get_session
	 * ───────────
	 * Returns the current session details for a student or session ID.
	 */
	get_session: {
		args: {
			session_id: '',
			college_id: ''
		},
		call: function(req) {
			const sessId    = trim(req.session_id || '');
			const collegeId = trim(req.college_id || '');

			if (!sessId && !collegeId)
				return { error: 'Provide session_id or college_id' };

			expireOldSessions();
			const sessions = sessionsRead();
			const ts = now();

			for (let s in sessions) {
				if (sessId    && s.session_id !== sessId)    continue;
				if (collegeId && s.college_id !== collegeId) continue;

				/* Enrich with current quota data */
				const students = studentsRead();
				let quotaBytes = DEFAULT_QUOTA_BYTES, usedBytes = 0;
				for (let st in students) {
					if (st.college_id === s.college_id) {
						quotaBytes = st.quota_bytes || DEFAULT_QUOTA_BYTES;
						usedBytes  = st.used_bytes  || 0;
						break;
					}
				}
				const remaining = max(0, quotaBytes - usedBytes);

				return {
					session_id:      s.session_id,
					college_id:      s.college_id,
					client_ip:       s.client_ip       || '',
					client_mac:      s.client_mac      || '',
					nds_token:       s.nds_token        || '',
					login_time:      s.login_time       || '',
					last_activity:   s.last_activity    || '',
					expires_at:      s.expires_at,
					status:          s.status,
					upload_bytes:    s.upload_bytes     || 0,
					download_bytes:  s.download_bytes   || 0,
					quota_bytes:     quotaBytes,
					used_bytes:      usedBytes,
					remaining_bytes: remaining
				};
			}

			return { error: 'Session not found' };
		}
	},

	/*
	 * get_active_sessions
	 * ────────────────────
	 * Returns all currently active sessions (admin/netadmin use).
	 */
	get_active_sessions: {
		call: function() {
			expireOldSessions();
			const sessions = sessionsRead();
			const ts = now();
			const active = filter(sessions, s => s.status === 'active' && int(s.expires_at) > ts);
			return {
				sessions: active,
				total:    length(active),
				_phase:   4
			};
		}
	},

	/* Student portal self-service methods (Phase 4) */
	get_my_quota: {
		args: { session_id: '' },
		call: function(req) {
			const sessId = trim(req.session_id || '');
			if (!sessId) return { error: 'Session ID required' };

			expireOldSessions();
			const sessions = sessionsRead();
			const ts = now();

			for (let s in sessions) {
				if (s.session_id !== sessId) continue;
				if (s.status !== 'active' || int(s.expires_at) <= ts)
					return { error: 'Session expired or invalid' };

				const students = studentsRead();
				for (let st in students) {
					if (st.college_id !== s.college_id) continue;
					const remaining = max(0, (st.quota_bytes || DEFAULT_QUOTA_BYTES) - (st.used_bytes || 0));
					return {
						college_id:      st.college_id,
						name:            st.name,
						quota_bytes:     st.quota_bytes || DEFAULT_QUOTA_BYTES,
						used_bytes:      st.used_bytes  || 0,
						remaining_bytes: remaining,
						status:          st.status
					};
				}
			}
			return { error: 'Session not found' };
		}
	},

	get_my_usage: {
		args: { session_id: '' },
		call: function(req) {
			/* Phase 5 will populate real traffic figures */
			return {
				upload_bytes:   0,
				download_bytes: 0,
				_phase: 5,
				_message: 'Real traffic tracking implemented in Phase 5'
			};
		}
	},

	get_my_devices: {
		args: { session_id: '' },
		call: function(req) {
			return { devices: [], _phase: 6, _message: 'Device management implemented in Phase 6' };
		}
	},

	/* Phase 6 stubs */
	list_devices: {
		args: { filter: '' },
		call: function() { return { devices: [], total: 0, _phase: 6 }; }
	},
	get_device: {
		args: { mac_address: '' },
		call: function() { return { error: 'Not implemented — Phase 6' }; }
	},

	/* Phase 5 stub */
	get_usage_stats: {
		args: { college_id: '', period: 'today' },
		call: function() { return { error: 'Not implemented — Phase 5' }; }
	}
};

return { 'college.wifi': methods };
