# Contributing to MasterFabric Cut

<div align="center">

[![Contributors](https://img.shields.io/github/contributors/masterfabric/masterfabric-cut?logo=github)](https://github.com/masterfabric/masterfabric-cut/graphs/contributors)
[![Pull Requests Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)](https://github.com/masterfabric/masterfabric-cut/pulls)

**Thank you for your interest in contributing to MasterFabric Cut! 🎉**

</div>

---

## 🌟 Welcome Contributors!

MasterFabric Cut is a native, lightweight macOS menu bar app for screenshots, annotation and screen recording, written in Swift. Every contribution, no matter how small, helps.

---

## 🤝 Ways to Contribute

- 🐛 **Bug Reports**: Found a bug? Let us know!
- ✨ **Feature Requests**: Have an idea? We'd love to hear it!
- 💻 **Code**: Capture, recording, annotation editor, history, settings
- 🧪 **Testing**: Try on different macOS versions, displays and permission setups
- 📝 **Documentation**: Improve the README, guides and screenshots
- 🎨 **Design**: UI/UX improvements and assets

---

## 🛠️ Development Setup

### Prerequisites

- macOS 14+
- Xcode (with command line tools)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Git

### 🚀 Quick Start

1. **Fork & Clone**
   ```bash
   git clone https://github.com/YOUR_USERNAME/masterfabric-cut.git
   cd masterfabric-cut
   ```

2. **Generate the Xcode project**
   ```bash
   brew install xcodegen          # once
   xcodegen generate              # creates MasterFabricCut.xcodeproj from project.yml
   ```

3. **Build and run**
   ```bash
   xcodebuild -project MasterFabricCut.xcodeproj -scheme MasterFabricCut \
     -configuration Release -derivedDataPath build build
   open "build/Build/Products/Release/MasterFabric Cut.app"
   ```
   You can also open the project in Xcode and press ⌘R.

> Grant **Screen Recording** when asked, then relaunch the app. macOS only applies the permission to a fresh process.

### 📁 Project Structure

```
masterfabric-cut/
├── Sources/
│   ├── App/        # App entry point and lifecycle
│   ├── Modules/    # Feature modules (capture, recording, editor, history, ...)
│   └── Shared/     # Shared utilities
├── Resources/      # Assets and resources
├── docs/           # Documentation and screenshots
└── project.yml     # XcodeGen project definition
```

The `.xcodeproj` is generated from `project.yml`; change targets and settings there, then re-run `xcodegen generate`.

---

## 📋 Contribution Workflow

### 1. 🍴 Fork and Branch

```bash
git checkout -b feature/amazing-feature   # features
git checkout -b fix/bug-description       # bug fixes
git checkout -b docs/improvement          # documentation
```

### 2. 🔧 Make Changes

- Follow the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)
- Match the style of the surrounding code
- Use meaningful names and handle errors properly
- Keep UI code on the main actor
- Never add network calls or telemetry that send user captures anywhere

**Commit messages** use `type: description`:

```bash
feat: add scrolling capture
fix: correct recording pause timing
docs: update installation steps
refactor: simplify annotation rendering
```

**Checklist**
- [ ] The project builds without warnings you introduced
- [ ] Changes verified manually on macOS 14+
- [ ] Documentation and `CHANGELOG.md` updated if needed
- [ ] Commit messages follow the convention

### 3. 🔄 Submit a Pull Request

Use the [Pull Request Template](.github/pull_request_template.md):

1. Create a PR with a descriptive title
2. Fill out the template completely
3. Link related issues (`fixes #123`)
4. Include screenshots or recordings for UI changes
5. Address review feedback promptly

---

## 🐛 Reporting Bugs

```markdown
**Bug Description**
A clear description of what the bug is.

**Steps to Reproduce**
1. ...

**Expected Behavior**
What you expected to happen.

**Environment**
- macOS version: [e.g. 14.5]
- App version: [e.g. 1.2.0]
- Mac model / display setup: [e.g. MacBook Pro 14", external 4K]
- Permissions granted: [Screen Recording / Camera / Microphone / Accessibility]
```

## 🔐 Security Contributions

If you discover a security vulnerability:

1. **DO NOT** create a public issue
2. **Report privately** to `license@masterfabric.co`
3. **Follow** our [Security Policy](SECURITY.md)

---

## 🌍 Community Guidelines

All contributors must follow our [Code of Conduct](CODE_OF_CONDUCT.md): be respectful, constructive, patient with newcomers and collaborative.

- **GitHub Issues**: Bug reports and feature requests
- **Pull Requests**: Code review and collaboration
- **Email**: `license@masterfabric.co` for private matters

---

## ⚖️ Legal Information

### License
This project is licensed under GNU AGPL v3.0. By contributing, you agree that your contributions will be licensed under the same terms.

### Copyright
- **Owner:** MASTERFABRIC Bilişim Teknolojileri A.Ş.
- **Maintainer:** Gürkan Fikret Günak (@gurkanfikretgunak)
- **Contributors:** All contributors retain copyright of their contributions

### Contributor License Agreement (CLA)
By submitting a pull request, you confirm that:
- You have the right to license your contribution to us
- You agree to license your contribution under GNU AGPL v3.0
- Your contribution is your original work

---

**Questions? Reach out!**
- 📧 Email: `license@masterfabric.co`
- 💬 GitHub: [@gurkanfikretgunak](https://github.com/gurkanfikretgunak)
- 🌐 Website: [masterfabric.co](https://masterfabric.co)
