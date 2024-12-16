# Server Management Tools

A comprehensive toolkit for managing Debian-based web servers with PHP, MariaDB, Apache2, and SSL support.

## Features

- Virtual Host Management (Apache2)
- SSL Certificate Management (Let's Encrypt)
- Database Administration (MariaDB)
- SSH/SFTP User Management
- Cron Job Management
- Security Hardening

## Installation

```bash
git clone https://github.com/markus-michalski/server-tools.git
cd server-tools
chmod +x install.sh
sudo ./install.sh
```

The installer will:
1. Create `/root/server-tools/` directory
2. Copy all function scripts
3. Set appropriate permissions
4. Create symlink to `servertools` command

## Usage

Access all functions through the central command:

```bash
servertools
```

### Main Menu Options

1. Virtual Host Management
2. SSL Management
3. Database Management
4. SSH User Management
5. Cron Management

## Workflow Best Practices

### Correct Setup Order

1. First, create SSH user:
   ```bash
   servertools
   # Select SSH User Management
   # Create standard or developer SSH user
   # Set DocRoot to base directory (e.g., /var/www/domain)
   ```

2. Then, create Virtual Host:
   ```bash
   servertools
   # Select Virtual Host Management
   # Create new vHost
   # Use same DocRoot as SSH user
   # Script will automatically:
   # - Create /html subdirectory
   # - Set Apache DocumentRoot to /html
   # - Set correct permissions (775/664)
   ```

Example for Nextcloud setup:
```bash
# 1. Create SSH user
servertools
# SSH User Management
# Create user 'nextcloud-user' with DocRoot '/var/www/nextcloud'

# 2. Create vHost
servertools
# Virtual Host Management
# Create vHost with:
# - Domain: cloud.example.com
# - SSH User: nextcloud-user
# - DocRoot: /var/www/nextcloud
```

This ensures:
- SSH user can manage entire `/var/www/nextcloud` directory
- Apache serves from `/var/www/nextcloud/html`
- Correct permissions throughout the directory structure

## Component Overview

### Virtual Host Management (`vhost-functions.sh`)

Features:
- Create/delete virtual hosts
- Configure PHP versions
- Manage DocumentRoots (with safeguards against recursive file copying)
- Handle domain aliases
- SSL integration

Important Note:
When changing DocumentRoot to a subdirectory of the existing DocumentRoot, file copying will be automatically skipped to prevent recursive copying issues.

### SSL Management (`ssl-functions.sh`)

Features:
- Let's Encrypt certificate management
- Automatic renewal setup
- Certificate deletion
- Status overview

Requirements:
- Certbot
- Python3-certbot-apache

### Database Management (`db-functions.sh`)

Features:
- Create/delete databases
- Create/delete database users
- Secure password generation
- Automatic backup integration
- UTF8MB4 charset default
- Granular operations:
   - Create database with new user
   - Create database for existing user
   - Delete database while keeping user
   - Delete user while keeping databases
   - Show affected users for database operations

Security:
- Credentials stored in `/root/db-credentials/`
- Automatic permission management
- Backup before deletions
- Clear visibility of affected users/databases

Menu Options:
1. Create Database & User
2. Delete Database & User
3. Show Databases & Users
4. Create Database for Existing User
5. Delete Database Only (keep user)
6. Delete User Only

Example Usage:
```bash
# Through main menu:
servertools
# Select Database Management
# Choose from available options

# Creating new database with user:
# - Automatically generates secure password if none provided
# - Creates credentials file
# - Sets up proper permissions

# Deleting database only:
# - Shows which users have access to the database
# - Offers options for credentials file handling
# - Keeps associated users intact

# Deleting user only:
# - Shows which databases the user has access to
# - Indicates if databases still exist
# - Removes user while preserving databases
```

Important Notes:
- All database names and users are validated
- Credentials are automatically backed up
- Clear feedback about existing/non-existing resources
- Safe deletion procedures with confirmation


### SSH User Management (`ssh-functions.sh`)

Features:
- Create standard/developer users
- SSH key management
- DocRoot setup with ACL permissions
- PHP-FPM pools for developers
- Security hardening

Permission Management:
- ACL-based permission system
- Automatic ACL setup for new DocRoots
- ACL repair functionality
- Secure file/directory ownership

User Types:
1. Standard Users:
   - Limited shell access
   - SFTP support
   - Basic commands
   - ACL permissions for DocRoots

2. Developer Users:
   - Full shell access
   - Development tools
   - Custom PHP-FPM pool
   - Git/Composer support
   - Enhanced ACL permissions

### Cron Management (`cron-functions.sh`)

Features:
- List all cron jobs (system-wide and user-specific)
- Add new cron jobs with schedule validation
- Remove existing cron jobs
- Support for both system-wide (/etc/cron.d) and user-specific crontabs
- Interactive menu-driven interface

Example Usage:
```bash
# Through main menu:
servertools
# Select option 5 (Cron Management)
# Choose from available options:
# 1. List cron jobs
# 2. Add new cron job
# 3. Remove cron job
```

Schedule Format:
- Standard cron format (minute hour day month weekday)
- Automatic validation of schedule syntax
- Examples:
   - `0 4 * * *` (Daily at 4 AM)
   - `*/15 * * * *` (Every 15 minutes)
   - `0 0 * * 0` (Weekly on Sunday at midnight)

### Common Functions (`common-functions.sh`)

Shared utilities:
- Root privilege checks
- Certbot installation
- SSH key validation
- Error handling

## Security Features

- Automatic permission management
- Secure password policies
- SSL by default
- User isolation
- Backup integration
- Logging

## File Structure

```
/root/server-tools/
├── common-functions.sh
├── db-functions.sh
├── vhost-functions.sh
├── ssl-functions.sh
├── ssh-functions.sh
├── cron-functions.sh
└── server-tools.sh
```

## Requirements

- Debian 12 (Bookworm)
- Apache2
- MariaDB
- PHP-FPM (8.1, 8.2, 8.3)
- Certbot
- UFW

## Maintenance

- Log files in standard locations
- Automatic backups configured
- Service restarts handled automatically
- Error logging enabled

## Best Practices

1. Always use through `servertools` command
2. Regularly check logs
3. Keep backups of configuration
4. Review user permissions periodically
5. Keep PHP versions updated

## Troubleshooting

Common issues:

1. Permission Errors:
   ```bash
   # Check script permissions
   ls -la /root/server-tools/
   # Should be 700 for all .sh files
   ```

2. Service Failures:
   ```bash
   # Check service status
   systemctl status apache2
   systemctl status mysql
   systemctl status php*-fpm
   ```

3. SSL Issues:
   ```bash
   # View certificates
   certbot certificates
   # Check Apache SSL
   apache2ctl -M | grep ssl
   ```

## Contributing

Guidelines for contributing:
1. Follow existing code structure
2. Add error handling
3. Update documentation
4. Test thoroughly
5. Follow security best practices

## License

MIT License

Copyright (c) 2024 [Markus Michalski]

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.