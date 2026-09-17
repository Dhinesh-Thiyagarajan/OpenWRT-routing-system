#!/usr/bin/env ucode
/*
 * College WiFi Management System - RPC Backend
 * Copyright (C) 2026 College WiFi Team
 *
 * This provides ubus RPC methods for the College WiFi Management interface.
 * Phase 2: Returns demo/mock data for initial testing
 * Future phases: Will integrate with actual OpenWrt services
 */

'use strict';

import { cursor } from 'uci';
import { readfile, writefile, stat } from 'fs';

const uci = cursor();

// Helper function to safely read JSON file
function readJSONFile(path) {
	try {
		let content = readfile(path);
		if (content)
			return json(content);
	} catch (e) {
		warn(`Failed to read ${path}: ${e}\n`);
	}
	return null;
}

// Helper function to safely write JSON file
function writeJSONFile(path, data) {
	try {
		writefile(path, sprintf('%J\n', data));
		return true;
	} catch (e) {
		warn(`Failed to write ${path}: ${e}\n`);
		return false;
	}
}

const methods = {
	// Dashboard Statistics
	get_dashboard_stats: {
		call: function() {
			// TODO Phase 3+: Read from actual data sources
			// For Phase 2: Return demo data clearly marked
			const result = {
				// Student statistics
				total_students: 25,
				active_students: 18,
				blocked_students: 2,
				
				// Device statistics
				total_devices: 42,
				active_devices: 35,
				
				// Data usage (in MB)
				total_data_usage: 45678,
				today_data_usage: 3456,
				
				// Network status
				internet_status: 'online',
				wifi_status: 'enabled',
				dhcp_status: 'running',
				firewall_status: 'active',
				
				// Security
				failed_auth_today: 3,
				blocked_attempts_today: 1,
				
				// Recent activity (last 5)
				recent_logins: [
					{ college_id: 'DSU001', name: 'Test Student 1', time: '2026-09-17T10:30:00Z' },
					{ college_id: 'DSU002', name: 'Test Student 2', time: '2026-09-17T10:25:00Z' },
					{ college_id: 'DSU003', name: 'Test Student 3', time: '2026-09-17T10:20:00Z' },
					{ college_id: 'DSU004', name: 'Test Student 4', time: '2026-09-17T10:15:00Z' },
					{ college_id: 'DSU005', name: 'Test Student 5', time: '2026-09-17T10:10:00Z' }
				],
				
				// Demo data indicator
				_demo_data: true,
				_phase: 2
			};
			
			return result;
		}
	},

	// Student Management (Phase 3)
	list_students: {
		args: {
			filter: '',
			limit: 0,
			offset: 0
		},
		call: function(req) {
			// TODO Phase 3: Implement real student database
			return {
				students: [],
				total: 0,
				_demo_data: true,
				_phase: 3,
				_message: 'Student management will be implemented in Phase 3'
			};
		}
	},

	get_student: {
		args: {
			college_id: ''
		},
		call: function(req) {
			// TODO Phase 3: Implement
			return {
				error: 'Not implemented - Phase 3',
				_demo_data: true
			};
		}
	},

	create_student: {
		args: {
			data: {}
		},
		call: function(req) {
			// TODO Phase 3: Implement
			return {
				success: false,
				error: 'Not implemented - Phase 3',
				_demo_data: true
			};
		}
	},

	update_student: {
		args: {
			college_id: '',
			data: {}
		},
		call: function(req) {
			// TODO Phase 3: Implement
			return {
				success: false,
				error: 'Not implemented - Phase 3',
				_demo_data: true
			};
		}
	},

	delete_student: {
		args: {
			college_id: ''
		},
		call: function(req) {
			// TODO Phase 3: Implement
			return {
				success: false,
				error: 'Not implemented - Phase 3',
				_demo_data: true
			};
		}
	},

	// Device Management (Phase 6)
	list_devices: {
		args: {
			filter: ''
		},
		call: function(req) {
			// TODO Phase 6: Read from DHCP leases and device database
			return {
				devices: [],
				total: 0,
				_demo_data: true,
				_phase: 6,
				_message: 'Device monitoring will be implemented in Phase 6'
			};
		}
	},

	get_device: {
		args: {
			mac_address: ''
		},
		call: function(req) {
			// TODO Phase 6: Implement
			return {
				error: 'Not implemented - Phase 6',
				_demo_data: true
			};
		}
	},

	// Usage Statistics (Phase 5)
	get_usage_stats: {
		args: {
			college_id: '',
			period: 'today'
		},
		call: function(req) {
			// TODO Phase 5: Read from conntrack and usage database
			return {
				error: 'Not implemented - Phase 5',
				_demo_data: true
			};
		}
	},

	// Security Events (Phase 7)
	get_security_events: {
		args: {
			filter: '',
			limit: 10
		},
		call: function(req) {
			// TODO Phase 7: Read from security log
			return {
				events: [],
				total: 0,
				_demo_data: true,
				_phase: 7,
				_message: 'Security logging will be implemented in Phase 7'
			};
		}
	},

	// Active Sessions (Phase 4)
	get_active_sessions: {
		call: function() {
			// TODO Phase 4: Read from session database
			return {
				sessions: [],
				total: 0,
				_demo_data: true,
				_phase: 4,
				_message: 'Session management will be implemented in Phase 4'
			};
		}
	},

	// Quota Management (Phase 5)
	set_quota: {
		args: {
			college_id: '',
			quota_mb: 0
		},
		call: function(req) {
			// TODO Phase 5: Implement
			return {
				success: false,
				error: 'Not implemented - Phase 5',
				_demo_data: true
			};
		}
	},

	reset_quota: {
		args: {
			college_id: ''
		},
		call: function(req) {
			// TODO Phase 5: Implement
			return {
				success: false,
				error: 'Not implemented - Phase 5',
				_demo_data: true
			};
		}
	},

	// Student Portal (Phase 4)
	get_my_quota: {
		call: function() {
			// TODO Phase 4: Get quota for authenticated student
			return {
				error: 'Not implemented - Phase 4',
				_demo_data: true
			};
		}
	},

	get_my_usage: {
		call: function() {
			// TODO Phase 4: Get usage for authenticated student
			return {
				error: 'Not implemented - Phase 4',
				_demo_data: true
			};
		}
	},

	get_my_devices: {
		call: function() {
			// TODO Phase 4: Get devices for authenticated student
			return {
				error: 'Not implemented - Phase 4',
				_demo_data: true
			};
		}
	}
};

return { 'college.wifi': methods };
