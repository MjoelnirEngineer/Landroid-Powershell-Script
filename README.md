# Landroid PowerShell Script

An interactive PowerShell control script for **Worx Landroid** robotic lawn mowers using the official Worx Cloud API (v2) with MQTT communication.

## Overview

This script provides a command-line interface to manage your Worx Landroid mower from Windows/PowerShell. It communicates with the mower through the Worx Cloud infrastructure via REST API and MQTT [...]

## Features

### Core Functionality

- **Interactive Menu System**: User-friendly terminal interface for controlling your mower
- **Authentication**: Secure credential storage with encrypted local configuration
- **Automatic Token Management**: Refresh tokens automatically to maintain long-running sessions
- **Real-time Status Display**: Live dashboard showing mower status, battery level, and online state

### Mower Control Commands

- **Rain Delay Configuration** (`rd`): Set rain delay timer (prevents mowing in wet conditions)
- **Torque Adjustment** (`tq`): Control cutting motor torque/blade power (0-100%)
- **Firmware Updates**: Check for available firmware updates and OTA status
- **Device Status**: View mower state (mowing, charging, idle, error states, etc.)
- **Start/Stop Operations**: Trigger mowing routines and return-to-base commands
- **Edge Cutting Mode**: Operate in edge-cutting zones
- **Zone Scheduling**: Manage multi-zone mowing configurations (Protocol 1 / Vision series)

### Device Information

- Online/offline status monitoring
- Battery percentage and voltage
- Blade hours tracking
- Error code interpretation
- Device protocol detection (Legacy vs. Vision)
- Firmware version and update availability

## System Requirements

- **PowerShell 4.0+** (Windows 7+, Windows Server 2008 R2+)
- **Internet Connection**: For Worx Cloud API communication
- **Worx Account**: Valid Worx/Positec login credentials
- **Supported Mower Models**: Worx Landroid (all models with Cloud API support)

## Installation & Usage

### Prerequisites: Configure OAuth2 Client ID

Before running the script, you must provide the OAuth2 Client ID required for Worx API authentication. The script supports three methods:

#### Method 1: Environment Variable (Recommended)

Set the environment variable globally:

```powershell
[Environment]::SetEnvironmentVariable("LANDROID_CLIENT_ID", "your-client-id-here", "User")
```

Then restart PowerShell or reload your profile. The script will automatically detect and use this variable.

#### Method 2: Secrets File (Local)

Create a file named `secrets.ps1` in the same directory as `Landroid.ps1` with:

```powershell
$LANDROID_CLIENT_ID = "your-client-id-here"
```

This file is excluded from Git and won't be committed to the repository.

#### Method 3: Direct Assignment (Not Recommended)

Modify the script directly (after line 1439), but **do NOT commit this change** to Git:

```powershell
$ClientId = "your-client-id-here"
```

### Obtaining Your Client ID

Your OAuth2 Client ID can be obtained from:
- Worx Developer Portal (if available for your region)
- Worx API documentation
- Contact Worx support for API access

### First Run

1. Download `Landroid.ps1`
2. Configure the OAuth2 Client ID using one of the methods above
3. Run the script:
   ```powershell
   .\Landroid.ps1
   ```
4. Enter your Worx account credentials (email and password)
5. Select the mower to control (if multiple are in your account)
6. Credentials are encrypted and stored locally in `%LOCALAPPDATA%\Landroid_Config.xml`

### Subsequent Runs

The script loads saved credentials automatically. If needed, you can force re-login through the menu.

## Configuration

### Stored Locally

- Email address
- Encrypted password
- Target mower name (optional)

### Environment Variables

- `LANDROID_CLIENT_ID`: OAuth2 Client ID for Worx API authentication (required)

### API Endpoints

- **OAuth2 Server**: `https://id.worx.com/oauth/token`
- **Device API**: `https://api.worxlandroid.com/api/v2/product-items`
- **MQTT Broker**: Dynamically obtained from device metadata (WSS protocol)

## Technical Details

### Protocol Support

The script supports **two communication protocols**:

- **Protocol 0 (Legacy Landroid)**: Standard mower models (C500, C700, M700)
- **Protocol 1 (Vision Series)**: Newer AI-enabled models with advanced features

### MQTT Communication

Commands are sent via MQTT 3.1.1 over WebSocket (WSS):
- **Port**: 443 (WSS)
- **Authentication**: AWS IoT Custom Authorizer with JWT tokens
- **QoS Levels**: 1 (guaranteed delivery with acknowledgment)
- **Topics**: Device-specific command_in/command_out topics

### Token Management

- Access tokens are automatically refreshed 5 minutes before expiration
- Refresh tokens enable long-running sessions (24+ hours)
- Credentials are encrypted using Windows DPAPI (user-specific)

## Menu Options

The interactive menu provides:

1. **View Status** - Real-time mower dashboard
2. **Set Rain Delay** - Configure rain prevention timer
3. **Set Torque** - Adjust cutting power
4. **Start Mowing** - Trigger mowing sequence
5. **Return to Base** - Send mower to charging dock
6. **Firmware Check** - View firmware update status
7. **Advanced Settings** - Zone configuration, edge cutting
8. **Re-login** - Clear credentials and log in again
9. **Exit** - Close the application

## Status Codes

### Mower States

- **0**: Waiting
- **1**: In charging station
- **2**: Start sequence
- **3**: Leaving station
- **4**: Following border cable
- **7-8**: Mowing
- **9**: Stuck/stuck timeout
- **10**: Blade blocked
- **30**: Returning home
- **34**: Paused
- **103**: Searching zone
- **110**: Border wire crossed

### Error Codes

- **0**: No error
- **1**: Mower caught
- **2**: Lifted
- **3**: Border cable missing
- **5**: Rain delay active
- **8**: Blade motor blocked
- **9**: Wheel motor blocked
- **12**: Battery empty
- **14**: Charging error
- **100**: Docking error

## Troubleshooting

### Client ID Configuration Error

If you see: *"Die OAuth2 Client-ID konnte nicht geladen werden"* (Client ID could not be loaded):

1. Verify you've set the Client ID using one of the methods above
2. For environment variables, restart PowerShell after setting
3. For `secrets.ps1`, ensure it's in the same directory as `Landroid.ps1`
4. Check that your Client ID is not empty

### Authentication Issues
- Verify Worx credentials are correct
- Delete config file and re-login if credentials changed
- Check account has at least one mower

### MQTT Connection Failures
- Verify mower is online in Worx app
- Check Windows firewall allows WSS (port 443)
- Ensure mower has active WiFi connection

### Command Timeout
- Mower must be online to accept commands
- Commands are queued but require 3-8 second acknowledgment
- Older firmware may not support all parameters

### Firmware Update Issues
- Not all regions/models expose OTA endpoints (fallback to local fields)
- OTA support depends on mower model and firmware version
- Some updates must be triggered in the official Worx app

## Security Considerations

- **Client ID**: Keep your OAuth2 Client ID confidential
- **Credentials**: Encrypted using Windows DPAPI (tied to user account)
- **Access Tokens**: Stored in memory only, never written to disk
- **Config File**: Never share `Landroid_Config.xml` across user accounts
- **Secrets File**: Add `secrets.ps1` to `.gitignore` to prevent accidental commits
- **Auto-login**: Consider disabling auto-login if script runs on shared computers

## Limitations & Known Issues

- **No scheduling**: Script must run to execute commands (no persistent daemon)
- **Single device**: Controls one mower per session (can re-login for others)
- **No status caching**: Each query fetches live data from API
- **Pending config**: cfg values show with `*` until API confirms (3-8 second delay typical)
- **Vision series**: UUID field must be populated for all commands to work

## Advanced Features

### Pending Configuration Tracking

When you change settings (rain delay, torque), the script displays them with an asterisk (`*`) until the API confirms receipt. This prevents confusion about whether settings were actually applied[...]

### Automatic Mower Refresh

The script periodically requests status updates (`cmd = 0`) to ensure fresh data from the mower, especially after sending commands.

### Battery Status Display

Battery percentage is visualized as a bar chart with color coding:
- **Green**: >50% battery
- **Yellow**: 20-50% battery
- **Red**: <20% battery

## Example Workflows

### Set Rain Delay to 120 Minutes
```
Menu → Option 2 → Enter 120 → Confirm
```

### Check Firmware and Install Updates
```
Menu → Option 6 → View status → If OTA available, confirm upgrade
```

### Start Mowing for 30 Minutes
```
Menu → Option 4 → Select duration → Confirm
```

## Support & Development

For issues, feature requests, or contributions, please file an issue in the repository.

---

**License**: See LICENSE file in repository

**Last Updated**: 2026  
**API Version**: Worx Cloud API v2 (pyworxcloud v6 compatible)
