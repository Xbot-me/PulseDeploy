# Contributing to PulseDeploy

Thanks for taking the time to contribute! PulseDeploy is a modular sysadmin automation toolkit and contributions that improve reliability, add distro support, or expand service coverage are very welcome.

---

## 🐛 Reporting Bugs

Before opening an issue, please:
- Check the [existing issues](https://github.com/Xbot-me/PulseDeploy/issues) to avoid duplicates
- Confirm the issue is reproducible on a clean server

When reporting, include:
- Your OS and version (`cat /etc/os-release`)
- Stack/services you selected
- The full error output from `/var/log/server-bootstrap.log`
- Steps to reproduce

Use the **Bug Report** issue template.

---

## 💡 Suggesting Features

Open a **Feature Request** issue with:
- A clear description of the problem it solves
- Which distros/stacks it would affect
- Any implementation ideas you have

---

## 🔧 Submitting Pull Requests

### Setup

```bash
git clone https://github.com/Xbot-me/PulseDeploy.git
cd PulseDeploy
chmod +x bootstrap.sh scripts/**/*.sh
```

### Branch naming

```
feat/your-feature-name
fix/what-you-are-fixing
docs/what-you-are-documenting
```

### Before you push

1. **Run ShellCheck** on any `.sh` files you modified:
   ```bash
   shellcheck -x bootstrap.sh revert.sh
   find scripts/ tests/ -name "*.sh" | xargs shellcheck -x
   ```

2. **Follow the module pattern** — every service or OS module should:
   - Be independently sourceable (no hard dependencies on bootstrap.sh state beyond `$PKG_MANAGER` and `$OS_ID`)
   - Use the `os_pkg_install`, `os_svc_enable`, `os_firewall_cmd` abstractions
   - Use the `log()`, `warn()`, `error()`, `info()`, `section()` helpers from `scripts/lib/common.sh` (source it at the top of every module)
   - Read settings from plain variables with defaults (`${PHP_VER:-8.2}`), and **never prompt** — prompting belongs in `bootstrap.sh`'s wizard so `--non-interactive` never hangs
   - Verify that what you installed really works before logging success
   - Be idempotent: a second run must not duplicate config, overwrite user files, or rotate credentials
   - Edit config with `conf_set` / drop-in files and `backup_file`, never by overwriting package-owned files

3. **Run the unit tests**: `bash tests/run.sh`

4. **Test on a real VM** if possible — at minimum Ubuntu 22.04 or Debian 12. Run your change twice to prove it is idempotent, then `revert.sh` to prove it undoes cleanly.

### PR checklist

- [ ] ShellCheck passes with no errors (`shellcheck -x`)
- [ ] New scripts follow the existing module pattern
- [ ] README updated if new stack/service/distro added
- [ ] Commit messages follow `type: description` format (`feat:`, `fix:`, `docs:`, `chore:`)

---

## 📁 Project Structure Recap

```
scripts/lib/         # Shared helpers: logging, validation, packages, services, config editing
scripts/os/          # One file per distro — handles pkg manager, repos, firewall abstraction
scripts/stacks/      # Stack installers (lemp, lamp, node)
scripts/services/    # Individual service installers (redis, docker, certbot, etc.)
config/              # Config file templates (nginx, apache)
tests/run.sh         # Unit tests (no root/network needed)
```

---

## 📜 License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).