# Secure College Wi-Fi Management and Network Monitoring System Using OpenWrt

An OpenWrt-based college Wi-Fi management system that provides authenticated, controlled Internet access to students while giving administrators tools to manage users, devices, sessions, usage, permissions, bandwidth, and network security.

The project is designed to run in a virtualized environment, so development and testing can be performed without purchasing a physical router.

---

## Project Overview

The system addresses a practical campus connectivity problem: students may not always have usable mobile Internet for essential academic or communication tasks such as sending documents, accessing online resources, or contacting family.

The proposed system provides limited Internet access after student authentication and gives administrators control over how that access is managed.

### Main goals

- Authenticate students using a College ID and registered phone number.
- Provide controlled Internet access through OpenWrt.
- Use a captive portal for authentication.
- Track student sessions and usage.
- Support per-student Internet quotas.
- Monitor connected devices.
- Provide administrator controls for access and permissions.
- Provide network and security management features.
- Run the entire system virtually for development and demonstration.

---

## Architecture

```text
                 Internet
                    |
              VMware NAT / WAN
                    |
              +-----------+
              |  OpenWrt  |
              |   Router  |
              +-----------+
                    |
                 br-lan
                    |
                 openNDS
                    |
             Captive/FAS Portal
                    |
              +-----------+
              | portal.sh |
              +-----------+
                    |
                  ubus
                    |
             +---------------+
             | college.wifi  |
             | rpcd / ucode  |
             +---------------+
                    |
             Student / Session
                 Data
```

The main authentication flow is:

```text
Client
  -> OpenWrt
  -> openNDS interception
  -> FAS portal
  -> College ID + phone
  -> college.wifi.authenticate_student()
  -> session creation
  -> OpenNDS authentication
  -> Internet access
```

---

## Technology Stack

| Component | Technology |
|---|---|
| Router OS | OpenWrt |
| Web Administration | LuCI |
| RPC Backend | rpcd + ucode |
| RPC Communication | ubus |
| Configuration | UCI |
| Captive Portal | openNDS |
| Portal Backend | POSIX shell |
| Frontend | JavaScript, HTML, CSS |
| Prototype Data | JSON / UCI |
| Development | Git, SSH, VMware |

> OpenWrt 25.12.x uses `apk` for package management. Do not assume `opkg` is available.

---

## Repository Structure

The main application is located at:

```text
applications/
└── luci-app-college-wifi/
    ├── Makefile
    ├── README.md
    └── root/
        ├── etc/
        │   └── config/
        ├── usr/
        │   ├── lib/
        │   └── share/
        │       └── rpcd/
        │           └── ucode/
        │               └── college-wifi.uc
        └── www/
            ├── cw-auth/
            │   └── portal.sh
            └── portal/
                └── index.html
```

Important runtime files:

```text
root/usr/share/rpcd/ucode/college-wifi.uc
root/www/cw-auth/portal.sh
root/www/portal/index.html
```

---

# Supported Development Setups

There are two recommended development arrangements.

## Option A — Windows with One OpenWrt VM

This is the simplest setup and is recommended for developers using Windows.

```text
Windows PC
   |
   +-- VMware Workstation
   |      |
   |      +-- OpenWrt x86_64 VM
   |
   +-- Windows host acts as test client
```

Only one virtual machine is required.

### Network layout

Use two virtual network adapters for the OpenWrt VM:

```text
Adapter 1 -> NAT / Internet (WAN)
Adapter 2 -> Host-only network (LAN)
```

Example LAN:

```text
Network:   192.168.100.0/24
OpenWrt:   192.168.100.254
```

The Windows host can use another address on the same LAN, for example:

```text
Windows:   192.168.100.x
Gateway:   192.168.100.254
```

VMware DHCP on the host-only network should normally be disabled when OpenWrt is providing DHCP.

### OpenWrt image

Use an OpenWrt `x86_64` image on a Windows PC.

Do not use an ARM64 image intended for Apple Silicon Macs.

---

## Option B — macOS with VMware Fusion

On Apple Silicon Macs such as M-series Macs, use an OpenWrt ARM64/ARMv8 image.

Example layout:

```text
Mac
 |
 +-- VMware Fusion
       |
       +-- OpenWrt ARM64 VM
       |
       +-- Optional Windows/Linux client VM
```

Network:

```text
Adapter 1 -> NAT / Internet (WAN)
Adapter 2 -> Host-only LAN / vmnet network
```

For a Mac-only setup, the Mac host can also be used as a client when the network configuration permits it.

---

# Installing OpenWrt

Install OpenWrt in VMware and configure:

- One adapter for WAN/Internet access.
- One adapter for the private LAN used by clients.

Configure the OpenWrt LAN address to a known address, for example:

```text
192.168.100.254/24
```

Verify connectivity from the development machine:

```bash
ping 192.168.100.254
```

Then connect using SSH:

```bash
ssh root@192.168.100.254
```

---

# Installing Required OpenWrt Components

The exact package list may depend on the OpenWrt image.

The project requires, at minimum:

- LuCI
- rpcd
- rpcd ucode support
- ucode modules required by the application
- uhttpd
- openNDS
- DNS/DHCP support

On OpenWrt 25.12.x, package installation uses:

```sh
apk update
apk add <package>
```

For example, the rpcd ucode module may be installed with:

```sh
apk add rpcd-mod-ucode
```

Additional ucode modules required by the project can be installed as needed.

---

# Downloading the Project

Clone the repository:

```bash
git clone https://github.com/Dhinesh-Thiyagarajan/OpenWRT-routing-system.git
cd OpenWRT-routing-system
```

The active development branch is:

```text
main
```

Always pull the latest changes before starting development:

```bash
git pull
```

---

# Deploying the LuCI Application to OpenWrt

For rapid development, the application's `root` directory can be copied directly to the OpenWrt filesystem.

## macOS / Linux

From the repository root:

```bash
tar -C applications/luci-app-college-wifi/root -cf - . | \
ssh root@192.168.100.254 'tar -C / -xf -'
```

## Windows PowerShell

PowerShell can use the same `tar` command on current Windows installations:

```powershell
tar -C applications/luci-app-college-wifi/root -cf - . | ssh root@192.168.100.254 "tar -C / -xf -"
```

If OpenSSH is not enabled on Windows, install/enable the Windows OpenSSH client first.

---

# Restarting Services

After deploying changes, restart only the services affected by the change.

For the RPC backend:

```sh
/etc/init.d/rpcd restart
```

For the web server:

```sh
/etc/init.d/uhttpd restart
```

For captive-portal changes:

```sh
/etc/init.d/opennds restart
```

---

# Verifying the Backend

The LuCI backend must register an ubus object named:

```text
college.wifi
```

Check it with:

```sh
ubus list | grep college
```

Expected:

```text
college.wifi
```

---

# RPC Backend Syntax Check

Before restarting `rpcd`, check the ucode syntax:

```sh
ucode -c /usr/share/rpcd/ucode/college-wifi.uc && echo "Syntax OK"
```

If syntax checking fails, fix the source before restarting services.

---

# Authentication Backend Test

The backend exposes student authentication through ubus.

Example:

```sh
ubus call college.wifi authenticate_student '{
  "college_id":"ENG23CS001",
  "phone":"<REGISTERED_PHONE>",
  "client_ip":"192.168.100.x",
  "client_mac":"<CLIENT_MAC>",
  "nds_token":"test-token"
}'
```

A successful response should contain fields similar to:

```json
{
  "success": true,
  "session_id": "...",
  "college_id": "...",
  "name": "...",
  "status": "authenticated",
  "quota_bytes": 1073741824,
  "used_bytes": 0,
  "remaining_bytes": 1073741824,
  "quota_exhausted": false
}
```

Use only development/test accounts when testing authentication. Do not publish real phone numbers or credentials in the repository.

---

# openNDS Configuration

The project uses openNDS as the captive portal layer.

A typical development configuration includes:

```text
Managed interface: br-lan
MHD:               http://<OPENWRT_LAN_IP>:2050
FAS:               http://<OPENWRT_LAN_IP>:2080/cw-auth/portal.sh
```

Check the current openNDS state with:

```sh
ndsctl status
```

Useful information includes:

- Managed interface
- FAS configuration
- Current clients
- Client state
- Authenticated sessions
- Traffic counters

---

# Testing Captive Portal Interception

From the client device, request an ordinary HTTP site:

```bash
curl -4 -v http://neverssl.com
```

Before authentication, openNDS should intercept the request and redirect the client to the FAS portal.

A successful interception normally looks similar to:

```text
HTTP/1.1 307 Temporary Redirect
Location: http://<OPENWRT_LAN_IP>:2080/cw-auth/portal.sh?fas=...
```

This proves that openNDS is intercepting unauthenticated client traffic.

---

# Current Authentication Architecture

The FAS handler is:

```text
/www/cw-auth/portal.sh
```

The backend is:

```text
/usr/share/rpcd/ucode/college-wifi.uc
```

Authentication is expected to work as:

```text
POST from portal
        |
        v
portal.sh
        |
        v
college.wifi.authenticate_student
        |
        v
session created
        |
        v
ndsctl auth <CLIENT_MAC>
        |
        v
openNDS marks client authenticated
```

---

# Important rpcd/ucode Detail

For rpcd ucode methods, request arguments are accessed through `req.args`.

Correct:

```js
const cid = trim(req.args.college_id || '');
const phone = replace(trim(req.args.phone || ''), /\s/g, '');
const clientIp = trim(req.args.client_ip || '');
const clientMac = lc(trim(req.args.client_mac || ''));
const ndsToken = trim(req.args.nds_token || '');
```

Do not change this to:

```js
req.college_id
req.phone
req.client_ip
req.client_mac
req.nds_token
```

The latter does not correctly access rpcd method arguments.

---

# Current Known Development Issue

The direct ubus authentication test is functional, and openNDS interception is functional.

The remaining integration issue in the current development state is the FAS handler's client-MAC extraction.

The symptom is:

```text
Auth attempt: cid=<ID> ip=<CLIENT_IP> mac=
```

followed by:

```text
ndsctl auth : Failed to authenticate client .
```

Meanwhile, openNDS knows the client's actual MAC address.

This means:

```text
openNDS
  -> FAS request
  -> portal.sh
  -> client MAC parsing
```

is the area that needs to be debugged.

Do not rewrite the authentication architecture just to solve this issue.

First determine why the `clientmac` value is lost between the FAS request and:

```sh
CLIENT_MAC="$(get_param 'clientmac' "$FAS_DECODED")"
```

Then verify that:

```sh
ndsctl auth "$CLIENT_MAC"
```

receives a valid MAC address.

---

# Useful Debugging Commands

Check deployed FAS code:

```sh
sed -n '1,320p' /www/cw-auth/portal.sh
```

Check the deployed ucode backend:

```sh
sed -n '1,800p' /usr/share/rpcd/ucode/college-wifi.uc
```

Search for FAS and authentication logs:

```sh
logread | grep -E 'Auth attempt|Auth FAILED|Auth SUCCESS|ndsctl auth|FAS' | tail -50
```

Check connected clients:

```sh
ndsctl status
```

Check registered ubus objects:

```sh
ubus list | grep college
```

Test backend registration:

```sh
ubus list | grep college
```

---

# Recommended Development Workflow

Always follow this order:

```text
1. Read the existing implementation.
2. Identify the smallest root cause.
3. Change only what is necessary.
4. Deploy the changed file.
5. Verify the deployed file.
6. Run syntax validation.
7. Restart the affected service.
8. Run the smallest direct test.
9. Inspect logs.
10. Test end-to-end behavior.
```

Do not assume that changing the source code automatically changes the OpenWrt VM.

The source and deployed runtime are separate.

Always verify the deployed version.

---

# End-to-End Acceptance Test

The initial integration milestone is considered successful when all of the following work:

### 1. Backend

```sh
ubus list | grep college
```

returns:

```text
college.wifi
```

### 2. Direct authentication

```sh
ubus call college.wifi authenticate_student ...
```

returns:

```json
"success": true
```

### 3. openNDS interception

```bash
curl -4 -v http://neverssl.com
```

redirects to the FAS portal.

### 4. Portal authentication

A valid student can submit credentials and complete authentication.

### 5. openNDS client state

```sh
ndsctl status
```

shows the client as:

```text
State: Authenticated
```

### 6. Internet connectivity

From the authenticated client:

```bash
ping 8.8.8.8
```

and:

```bash
curl -4 http://neverssl.com
```

should demonstrate Internet connectivity.

---

# One-VM Windows Testing

A second virtual machine is not required for basic development.

Recommended arrangement:

```text
Windows Host
   |
   +-- VMware Workstation
   |      |
   |      +-- OpenWrt x86_64
   |
   +-- Browser / PowerShell
          |
          +-- acts as the client
```

This keeps the environment simple:

- OpenWrt = router
- Windows host = client
- VMware NAT = upstream Internet
- VMware Host-only network = student LAN

A second client VM may be added later for multi-device testing, but it is not required for the initial project milestone.

---

# macOS Testing

On Apple Silicon:

```text
Mac
 |
 +-- VMware Fusion
       |
       +-- OpenWrt ARM64
       |
       +-- Optional client VM
```

The same logical topology applies:

```text
NAT -> WAN
Host-only -> LAN
```

Use the OpenWrt LAN address assigned to the VM when accessing LuCI or the FAS portal.

---

# Project Development Scope

The current project is being developed in phases.

Existing foundation:

- LuCI administration interface
- Roles and access control
- Student data
- Device data
- Session management
- Authentication
- Captive portal
- openNDS integration
- FAS handler
- Initial security controls
- Prototype usage/quota data

Future development can include:

- Full network quota enforcement
- Per-client traffic accounting
- Bandwidth shaping
- Automated quota exhaustion handling
- Expanded device controls
- Detailed network monitoring
- Security event management
- Better administrator analytics
- Production-grade authentication and secret handling
- HTTPS/TLS for the portal
- Persistent production database/storage
- Hardware deployment

Do not claim future functionality is complete until it has been implemented and tested.

---

# Security Notes

This repository is a development/prototype project.

Do not put the following into a public repository:

- Real student phone numbers
- Real passwords
- Production API keys
- Production session secrets
- Real administrative credentials
- Private certificates or keys

Development credentials and sample data should be clearly marked as test data.

The FAS configuration and authentication secrets must be changed before any real deployment.

The current portal may use HTTP during local development. A real deployment should use an appropriate secure configuration with HTTPS and properly managed secrets.

---

# Troubleshooting

## `ubus list | grep college` returns nothing

Check that the required rpcd ucode support is installed:

```sh
apk add rpcd-mod-ucode
```

Then restart:

```sh
/etc/init.d/rpcd restart
```

Check the ucode file:

```sh
ucode -c /usr/share/rpcd/ucode/college-wifi.uc
```

---

## Authentication says "College ID is required"

Verify that the rpcd callback uses:

```js
req.args.college_id
```

rather than:

```js
req.college_id
```

Then redeploy the file and restart rpcd.

---

## openNDS does not redirect to the portal

Check:

```sh
ndsctl status
```

Confirm:

- openNDS is running
- `br-lan` is the managed interface
- FAS is enabled
- the FAS URL points to the correct portal
- the client is actually connected through `br-lan`

---

## `ndsctl auth` says client not found

Check:

```sh
ndsctl status
```

Confirm the client's:

- IP address
- MAC address
- current state

The MAC supplied to:

```sh
ndsctl auth <MAC>
```

must be the same MAC that openNDS reports for the connected client.

---

## Direct ubus authentication works but browser authentication fails

This usually means the problem is in the integration layer rather than the student database or RPC backend.

Check:

```sh
logread | grep -E 'Auth attempt|Auth FAILED|Auth SUCCESS|ndsctl auth|FAS' | tail -50
```

Compare the values passed from the FAS request with:

```text
college_id
phone
client_ip
client_mac
nds_token
```

Do not replace the whole authentication system before locating the failed handoff.

---

# Contributing

When extending the project:

1. Work on a separate Git branch.
2. Keep changes focused.
3. Avoid modifying unrelated modules.
4. Test locally before merging.
5. Document new configuration.
6. Update tests when behavior changes.
7. Never commit secrets or real user data.

Example:

```bash
git checkout -b feature/<feature-name>
```

After testing:

```bash
git add .
git commit -m "Describe the change"
git push -u origin feature/<feature-name>
```

---

# AI-Assisted Development

This project may be developed using coding assistants such as Kiro, Cursor, Claude Code, or similar tools.

When using an AI coding assistant, provide it with:

- This README
- The complete `luci-app-college-wifi` source
- The current OpenWrt configuration when relevant
- Logs from the failing test
- The exact command output that demonstrates the issue

Ask the AI to:

```text
1. Understand the existing architecture.
2. Identify the smallest root cause.
3. Avoid unnecessary rewrites.
4. Make one focused change at a time.
5. Explain which file is being changed.
6. Give exact deployment commands.
7. Give exact verification commands.
8. Stop after the requested milestone is proven.
```

A useful instruction is:

> Treat the existing OpenWrt/LuCI project as an established codebase. Do not redesign it unless the existing architecture is demonstrably incapable of meeting the requirement. Prefer the smallest safe change, deploy it, verify the deployed file, test it on OpenWrt, and use real command output to determine the next step.

---

# Development Credentials

The repository may contain seeded development/test students.

Do not publish real credentials.

For a local development environment, inspect the project's seed data/configuration and use only the credentials explicitly provided there.

---

# Status

The project currently has a working foundation for:

```text
OpenWrt
   +
LuCI
   +
rpcd/ucode
   +
ubus
   +
openNDS
   +
FAS captive portal
   +
Student authentication
   +
Session management
```

The initial integration target is:

```text
Student login
      ↓
OpenNDS authentication
      ↓
Authenticated client
      ↓
Internet access
      ↓
Verified end-to-end test
```

Once that milestone is stable, additional project features can be developed independently.

---


