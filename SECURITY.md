# Security Policy

## 🔒 Security Overview

MasterFabric Cut takes security and privacy seriously. It handles screenshots, screen recordings and camera/microphone input, so we appreciate the security research community's efforts to responsibly disclose vulnerabilities.

## 📋 Supported Versions

Security updates are provided for the latest release only:

| Version | Supported |
| ------- | --------- |
| Latest [release](https://github.com/masterfabric/masterfabric-cut/releases/latest) | ✅ Full support |
| Older releases | ❌ No longer supported |

## 🚨 Reporting a Vulnerability

### 📧 Contact Information

**Primary Contact:**
- **Email:** license@masterfabric.co
- **Secondary Email:** gurkanfikretgunak@masterfabric.co
- **Owner:** Gürkan Fikret Günak (@gurkanfikretgunak)

### 📝 Reporting Process

1. **DO NOT** create a public issue for security vulnerabilities
2. Send a detailed report to `license@masterfabric.co` with:
   - Description of the vulnerability
   - Steps to reproduce the issue
   - macOS version and app version
   - Potential impact assessment
   - Any suggested fixes (if available)
   - Your contact information

### ⏰ Response Timeline

- **Initial Response:** Within 48 hours of receiving the report
- **Status Update:** Within 7 days with our assessment
- **Resolution:** Security fixes are prioritized and released as soon as possible

### 🏆 Recognition

- Researchers are credited in security advisories (unless they prefer to remain anonymous)
- Critical vulnerabilities may be acknowledged in release notes

## 🛡️ Security Best Practices

### For Developers

- **Code Review:** All code changes undergo review, with extra attention to capture, file-writing and permission code
- **Dependencies:** Keep dependencies minimal and updated
- **Privacy:** Never transmit captures, recordings or device data off the machine without explicit user action
- **Permissions:** Request only the macOS permissions a feature needs (Screen Recording, Camera, Microphone, Accessibility)
- **Entitlements:** Keep sandbox and hardened-runtime settings as restrictive as possible

### For Users

- **Keep Updated:** Use the latest release
- **Verify Downloads:** Only download builds from the official [Releases page](https://github.com/masterfabric/masterfabric-cut/releases)
- **Review Permissions:** Periodically review granted permissions in System Settings › Privacy & Security
- **Protect Captures:** Be careful when sharing captures that may contain sensitive information

## 🚫 What NOT to Report

- Issues already reported and acknowledged
- Theoretical vulnerabilities without proof of concept
- Social engineering or physical attacks
- Issues in third-party dependencies (report to the respective maintainers)
- Spam or automated testing results

## ⚖️ Legal Information

This security policy is governed by the terms outlined in our [LICENSE](LICENSE) file.

**Important:** This project is licensed under GNU AGPL v3.0. Any security fixes or contributions are subject to the same license terms.

**Company Information:**
- **Owner:** MASTERFABRIC Bilişim Teknolojileri A.Ş. (MASTERFABRIC Information Technologies Inc.)
- **Website:** https://masterfabric.co
- **Repository:** https://github.com/masterfabric/masterfabric-cut

## 📞 Emergency Contact

For critical security issues that require immediate attention:

- **Emergency Email:** license@masterfabric.co
- **Subject Line:** `[URGENT SECURITY] - [Brief Description]`

## 🔄 Policy Updates

This policy may be updated from time to time. Major changes will be announced through repository announcements and release notes.

---

**Last Updated:** October 2026
