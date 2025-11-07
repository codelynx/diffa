# Diffa Example Scripts

This directory contains example shell scripts demonstrating common workflows with the `diffa` CLI tool.

## Prerequisites

- `diffa` must be installed and in your PATH
- Bash shell (macOS, Linux)
- Appropriate file system permissions for target directories

## Scripts

### verify-installer.sh

Tests what an installer does to your system by comparing before/after snapshots.

**Usage:**
```bash
./verify-installer.sh /Applications "installer -pkg myapp.pkg -target /"
./verify-installer.sh /usr/local "brew install someapp"
```

**What it does:**
1. Creates a snapshot of the target directory
2. Runs the installer command
3. Creates another snapshot
4. Compares and reports changes

**Use cases:**
- Test installer impact before production deployment
- Verify uninstaller cleanup
- Audit system changes from packages

---

### deploy-with-rollback.sh

Deploys with automatic rollback on failure, using reversible patches.

**Usage:**
```bash
./deploy-with-rollback.sh /var/www /staging/new-version
```

**What it does:**
1. Creates reversible patch between current and new version
2. Shows deployment plan (dry-run)
3. Applies patch after confirmation
4. Validates deployment
5. Automatic rollback on failure

**Features:**
- Safe deployment with rollback support
- Validation before and after
- Keeps patch file for manual rollback
- Interactive confirmation

**Use cases:**
- Production deployments
- Configuration updates
- Software upgrades with safety net

---

### bidirectional-sync.sh

Safely syncs two directories with conflict handling.

**Usage:**
```bash
# Safe mode (abort on conflicts)
./bidirectional-sync.sh /dir-a /dir-b

# Automatic resolution (keep newer)
./bidirectional-sync.sh /dir-a /dir-b newest

# Always prefer A
./bidirectional-sync.sh /dir-a /dir-b source-wins
```

**Conflict strategies:**
- `error` (default) - Abort on conflicts, requires manual resolution
- `newest` - Keep file with most recent modification time
- `source-wins` - Always prefer first directory
- `dest-wins` - Always prefer second directory

**What it does:**
1. Dry-run to detect conflicts
2. Interactive confirmation if using automatic resolution
3. Performs bidirectional sync
4. Verifies directories are identical

**Use cases:**
- Two-way folder synchronization
- Merge changes from multiple sources
- Keep laptop and server in sync

---

### integrity-monitoring.sh

Monitors directories for unauthorized changes using baseline snapshots.

**Usage:**
```bash
# Create initial baseline
./integrity-monitoring.sh init /etc /root/baselines/etc.diffa

# Check for changes
./integrity-monitoring.sh check /etc /root/baselines/etc.diffa

# Update baseline after authorized changes
./integrity-monitoring.sh update /etc /root/baselines/etc.diffa
```

**What it does:**
- `init` - Creates baseline snapshot
- `check` - Verifies directory matches baseline
- `update` - Updates baseline with current state

**Automation with cron:**
```bash
# Check every 30 minutes
*/30 * * * * /usr/local/bin/integrity-monitoring.sh check /etc /root/baselines/etc.diffa || mail -s "System changes detected" admin@example.com

# Daily check with logging
0 0 * * * /usr/local/bin/integrity-monitoring.sh check /var/www /root/baselines/www.diffa >> /var/log/integrity-check.log 2>&1
```

**Use cases:**
- Security monitoring (detect unauthorized changes)
- Compliance auditing
- Configuration drift detection
- Build verification

---

## Integration Examples

### CI/CD Pipeline

```bash
# In your CI pipeline
- name: Verify Build Output
  run: |
    diffa snapshot expected-output/ -o expected.diffa
    make build
    diffa verify build/output/ expected.diffa
```

### Backup Verification

```bash
# Verify backup completeness
diffa snapshot /data -o /backups/data-baseline.diffa
rsync -av /data /backups/data-copy/
diffa verify /backups/data-copy/ /backups/data-baseline.diffa
```

### Configuration Management

```bash
# Detect configuration drift
diffa snapshot /etc -o /baselines/etc-$(date +%Y%m).diffa
# Later...
diffa compare /baselines/etc-202501.diffa /etc
```

## Tips

1. **Use dry-run first**: All scripts that make changes support dry-run mode
2. **Store baselines safely**: Keep baseline snapshots in a secure location
3. **Automate checks**: Use cron for periodic integrity monitoring
4. **Version baselines**: Keep dated backups of baselines for historical comparison
5. **Test rollbacks**: Verify rollback procedures work before production use

## Customization

These scripts are templates - customize them for your needs:

- Add logging
- Integrate with monitoring systems
- Add notification (email, Slack, etc.)
- Customize exclusion patterns
- Add validation steps

## License

These example scripts are provided as-is for demonstration purposes.
