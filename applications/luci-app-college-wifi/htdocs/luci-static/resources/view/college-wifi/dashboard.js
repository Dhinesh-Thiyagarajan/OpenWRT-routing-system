'use strict';
'require view';
'require rpc';
'require ui';
'require poll';

var callDashboardStats = rpc.declare({
	object: 'college.wifi',
	method: 'get_dashboard_stats',
	expect: {}
});

return view.extend({
	load: function() {
		return Promise.all([
			callDashboardStats()
		]);
	},

	render: function(data) {
		var stats = data[0] || {};
		
		// Create main container
		var view = E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('College WiFi Management Dashboard')),
			
			// Demo data warning
			stats._demo_data ? E('div', { 
				'class': 'alert-message warning',
				'style': 'margin-bottom: 20px; padding: 10px; background: #fff3cd; border-left: 4px solid #ffc107;'
			}, [
				E('strong', {}, '⚠ Phase 2 Demo Mode: '),
				E('span', {}, _('Displaying mock data for testing. Real data integration will be implemented in future phases.'))
			]) : null,
			
			// Statistics Cards Row
			E('div', { 
				'class': 'cbi-section',
				'style': 'display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-bottom: 20px;'
			}, [
				// Total Students Card
				this.renderStatCard('👥 Total Students', stats.total_students || 0, '#2196F3'),
				
				// Active Students Card
				this.renderStatCard('✅ Active Students', stats.active_students || 0, '#4CAF50'),
				
				// Connected Devices Card
				this.renderStatCard('📱 Connected Devices', stats.active_devices || 0, '#FF9800'),
				
				// Total Data Usage Card
				this.renderStatCard('📊 Total Data Usage', this.formatBytes((stats.total_data_usage || 0) * 1024 * 1024), '#9C27B0'),
				
				// Blocked Students Card
				this.renderStatCard('🚫 Blocked Students', stats.blocked_students || 0, '#F44336')
			]),
			
			// Network Status Section
			E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, _('Network Status')),
				E('div', { 
					'style': 'display: grid; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); gap: 15px; margin-top: 10px;'
				}, [
					this.renderStatusItem('Internet', stats.internet_status || 'unknown', stats.internet_status === 'online'),
					this.renderStatusItem('WiFi', stats.wifi_status || 'unknown', stats.wifi_status === 'enabled'),
					this.renderStatusItem('DHCP', stats.dhcp_status || 'unknown', stats.dhcp_status === 'running'),
					this.renderStatusItem('Firewall', stats.firewall_status || 'unknown', stats.firewall_status === 'active')
				])
			]),
			
			// Data Usage Today Section
			E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
				E('h3', {}, _('Data Usage Today')),
				E('div', { 'style': 'margin-top: 10px;' }, [
					E('table', { 'class': 'table' }, [
						E('tr', {}, [
							E('td', { 'style': 'width: 40%; font-weight: bold;' }, _('Today\'s Usage')),
							E('td', {}, this.formatBytes((stats.today_data_usage || 0) * 1024 * 1024))
						]),
						E('tr', {}, [
							E('td', { 'style': 'font-weight: bold;' }, _('Total Usage')),
							E('td', {}, this.formatBytes((stats.total_data_usage || 0) * 1024 * 1024))
						])
					])
				])
			]),
			
			// Recent Activity Section
			E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
				E('h3', {}, _('Recent Student Logins')),
				E('div', { 'style': 'margin-top: 10px;' }, [
					stats.recent_logins && stats.recent_logins.length > 0 ?
						E('table', { 'class': 'table cbi-section-table' }, [
							E('tr', { 'class': 'tr table-titles' }, [
								E('th', { 'class': 'th' }, _('College ID')),
								E('th', { 'class': 'th' }, _('Student Name')),
								E('th', { 'class': 'th' }, _('Login Time'))
							])
						].concat(
							stats.recent_logins.map(login => 
								E('tr', { 'class': 'tr' }, [
									E('td', { 'class': 'td' }, login.college_id),
									E('td', { 'class': 'td' }, login.name),
									E('td', { 'class': 'td' }, this.formatTime(login.time))
								])
							)
						))
						:
						E('p', { 'style': 'color: #666;' }, _('No recent login activity'))
				])
			]),
			
			// Security Overview Section
			E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
				E('h3', {}, _('Security Overview')),
				E('div', { 'style': 'margin-top: 10px;' }, [
					E('table', { 'class': 'table' }, [
						E('tr', {}, [
							E('td', { 'style': 'width: 60%; font-weight: bold;' }, _('Failed Authentication Attempts Today')),
							E('td', { 'style': stats.failed_auth_today > 5 ? 'color: #f44336; font-weight: bold;' : '' }, 
								String(stats.failed_auth_today || 0))
						]),
						E('tr', {}, [
							E('td', { 'style': 'font-weight: bold;' }, _('Blocked Attempts Today')),
							E('td', {}, String(stats.blocked_attempts_today || 0))
						])
					])
				])
			]),
			
			// Quick Actions Section
			E('div', { 'class': 'cbi-section', 'style': 'margin-top: 20px;' }, [
				E('h3', {}, _('Quick Actions')),
				E('div', { 'style': 'margin-top: 10px;' }, [
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							window.location.href = L.url('admin/college-wifi/students');
						}),
						'style': 'margin-right: 10px;'
					}, _('Manage Students')),
					
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							window.location.href = L.url('admin/college-wifi/devices');
						}),
						'style': 'margin-right: 10px;'
					}, _('View Devices')),
					
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							window.location.href = L.url('admin/college-wifi/data-usage');
						}),
						'style': 'margin-right: 10px;'
					}, _('Data Usage')),
					
					E('button', {
						'class': 'cbi-button cbi-button-action',
						'click': ui.createHandlerFn(this, function() {
							window.location.href = L.url('admin/college-wifi/security');
						})
					}, _('Security Logs'))
				])
			])
		]);
		
		// Set up auto-refresh every 30 seconds
		poll.add(L.bind(function() {
			return callDashboardStats().then(L.bind(function(stats) {
				// Update would be implemented here in production
			}, this));
		}, this), 30);
		
		return view;
	},
	
	// Helper function to render stat cards
	renderStatCard: function(title, value, color) {
		return E('div', {
			'style': `background: white; padding: 20px; border-radius: 8px; border-left: 4px solid ${color}; box-shadow: 0 2px 4px rgba(0,0,0,0.1);`
		}, [
			E('div', { 'style': 'font-size: 14px; color: #666; margin-bottom: 8px;' }, title),
			E('div', { 'style': `font-size: 28px; font-weight: bold; color: ${color};` }, String(value))
		]);
	},
	
	// Helper function to render status items
	renderStatusItem: function(label, status, isGood) {
		var statusColor = isGood ? '#4CAF50' : '#F44336';
		var statusIcon = isGood ? '●' : '●';
		
		return E('div', {
			'style': 'background: white; padding: 15px; border-radius: 8px; box-shadow: 0 2px 4px rgba(0,0,0,0.1);'
		}, [
			E('div', { 'style': 'font-size: 14px; color: #666; margin-bottom: 5px;' }, label),
			E('div', { 'style': 'display: flex; align-items: center;' }, [
				E('span', { 
					'style': `color: ${statusColor}; font-size: 20px; margin-right: 8px;`
				}, statusIcon),
				E('span', { 
					'style': `font-size: 16px; font-weight: bold; color: ${statusColor}; text-transform: capitalize;`
				}, status)
			])
		]);
	},
	
	// Helper function to format bytes
	formatBytes: function(bytes) {
		if (bytes === 0) return '0 B';
		var k = 1024;
		var sizes = ['B', 'KB', 'MB', 'GB', 'TB'];
		var i = Math.floor(Math.log(bytes) / Math.log(k));
		return parseFloat((bytes / Math.pow(k, i)).toFixed(2)) + ' ' + sizes[i];
	},
	
	// Helper function to format time
	formatTime: function(timeStr) {
		try {
			var date = new Date(timeStr);
			return date.toLocaleString();
		} catch (e) {
			return timeStr;
		}
	},
	
	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
