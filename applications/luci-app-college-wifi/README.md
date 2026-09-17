# LuCI College WiFi Management

A comprehensive web-based WiFi management system for educational institutions built on OpenWrt/LuCI.

## Features

- **Student Authentication**: Captive portal with College ID and phone number verification
- **Quota Management**: Per-student data quota allocation and enforcement
- **Network Monitoring**: Real-time device tracking and bandwidth monitoring
- **Role-Based Access**: Three permission levels (Administrator, Network Admin, Student)
- **Security Logging**: Comprehensive audit trails and security event tracking

## Installation

### From Source

```bash
# Copy application files to OpenWrt device
scp -r root/* root@192.168.1.1:/
scp -r htdocs/* root@192.168.1.1:/www/

# Run UCI defaults to initialize configuration
ssh root@192.168.1.1 "sh /etc/uci-defaults/80_college-wifi"

# Restart rpcd to load new RPC handlers
ssh root@192.168.1.1 "/etc/init.d/rpcd restart"

# Clear browser cache and reload LuCI
```

### From Package

```bash
opkg update
opkg install luci-app-college-wifi
```

## Configuration

Configuration is managed through:
- UCI: `/etc/config/college-wifi`
- Student Database: `/etc/college-wifi/students.json`
- Device Tracking: `/etc/college-wifi/devices.json`
- Session Management: `/etc/college-wifi/sessions.json`
- Usage Statistics: `/etc/college-wifi/usage.json`

## User Roles

### Administrator
- Full system access
- Student management (CRUD operations)
- Quota management (set/reset)
- Network configuration
- Security logs and reports

### Network Administrator
- Dashboard access
- Device monitoring
- Network statistics
- Read-only student information

### Student
- Personal portal access
- View own quota and usage
- No administrative access

## Development

This application follows LuCI modern development practices:
- Frontend: JavaScript (ES6+) with LuCI.js framework
- Backend: ucode RPC scripts
- Communication: ubus/rpcd
- Configuration: UCI + JSON storage

## API Endpoints

RPC methods available via `college.wifi` namespace:

### Dashboard
- `get_dashboard_stats()` - Overview statistics

### Students
- `list_students(filter, limit, offset)` - List students
- `get_student(college_id)` - Get student details
- `create_student(data)` - Add new student
- `update_student(college_id, data)` - Update student
- `delete_student(college_id)` - Remove student

### Devices
- `list_devices(filter)` - List connected devices
- `get_device(mac_address)` - Get device info

### Usage
- `get_usage_stats(college_id, period)` - Get usage statistics

### Security
- `get_security_events(filter, limit)` - Get security logs

## License

Apache License 2.0

## Support

For issues and questions, refer to project documentation or OpenWrt/LuCI community resources.
