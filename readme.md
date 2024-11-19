# Server Management Tools

A comprehensive toolkit for managing Debian-based web servers with PHP, MariaDB, Apache2, and SSL support.

## Features

- Virtual Host Management (Apache2)
- SSL Certificate Management (Let's Encrypt)
- Database Administration (MariaDB)
- SSH/SFTP User Management
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

### Main Menu Options

1. Virtual Host Management
2. SSL Management
3. Database Management
4. SSH User Management

## Component Overview

### Virtual Host Management (`vhost-functions.sh`)

Features:
- Create/delete virtual hosts
- Configure PHP versions
- Manage DocumentRoots
- Handle domain aliases
- SSL integration

Example:
```bash
# Through main menu:
servertools
# Select option 1
# Follow interactive prompts
```

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
- User management
- Secure password generation
- Automatic backup integration
- UTF8MB4 charset default

Security:
- Credentials stored in `/root/db-credentials/`
- Automatic permission management
- Backup before deletions

# Server Management Tools

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

## Best Practices

1. Always use through `servertools` command
2. Create SSH users before virtual hosts
3. Use ACL repair function if needed:
   ```bash
   servertools
   # Select SSH User Management
   # Select "ACL-Berechtigungen reparieren"
   # Follow prompts
   ```
4. Keep regular backups
5. Monitor logs

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
# MIT License

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