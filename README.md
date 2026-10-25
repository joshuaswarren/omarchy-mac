# Omarchy Mac

Omarchy 4 on Apple Silicon, installed alongside macOS. It uses Asahi Alarm
(Arch Linux ARM) and the Hyprland desktop from Omarchy.

This is Joshua Warren's fork of
[omarchy-mac/omarchy-mac](https://github.com/omarchy-mac/omarchy-mac).
The install commands below use that upstream project and its `quattro` branch.

## Before you install

- Check your model in [Asahi's support table](https://asahilinux.org/fedora/#device-support).
  This install targets M1 and M2 Macs. M3 and newer Macs, Intel Macs and T2
  Macs are not supported by this installer. Touch ID has no Linux driver.
- Back up macOS first. You need internet access and at least 50 GB of free
  internal storage; 100 GB is recommended.
- Root encryption is on by default. The setup moves `/boot` to the EFI
  partition before encrypting the root with LUKS2. Keep the disk passphrase.
- The boot chain is m1n1, U-Boot and GRUB, not the Limine setup used on x86.
  The EFI partition is outside the root filesystem's snapshots.

## Install

### 1. Start from macOS

Run the Asahi Alarm installer in Terminal:

```bash
curl https://asahi-alarm.org/installer-bootstrap.sh | sh
```

Choose `Asahi Alarm Minimal (BTRFS)` and leave at least 50 GB for Linux.
The ext4 Minimal image also works; setup converts it to Btrfs.

### 2. Boot Linux and connect to the network

Log in with username `root` and password `root`, then run:

```bash
nmtui
```

Choose **Activate a connection**, connect, and quit. If the connection fails
just after activation, reboot and try again.

### 3. Run setup

Still as root:

```bash
curl -fsSL https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bin/omarchy-mac-setup | bash
```

Setup asks for encryption, a hostname, a username and a password. It creates
the user and resumes on tty1 after each reboot. You do not need to update
pacman, set a locale or create the user first.

To read the script without running it:

```bash
curl -LO https://raw.githubusercontent.com/omarchy-mac/omarchy-mac/quattro/bin/omarchy-mac-setup
less omarchy-mac-setup
```

If asked to build packages with no known ARM build, leave the answer at no.
Some of those builds take hours and still fail. Setup reports missing packages.
The encryption step rewrites the partition and can take time. An interrupted
run resumes on the next boot.

Encrypted installs log into the desktop after the disk passphrase. Setup locks
the default root password once your user has sudo, unless you opt to keep it.

### Setup options

| Option | Purpose |
|---|---|
| `--encrypt`, `--no-encrypt` | Enable or skip root encryption; on by default |
| `--user <name>`, `--hostname <name>` | Supply names instead of answering prompts |
| `--keymap <name>` | Set the console keymap for the disk passphrase |
| `--repo <owner/repo>`, `--ref <branch>`, `--forge <host>` | Choose a source; defaults are `omarchy-mac/omarchy-mac`, `quattro`, `github.com` |
| `--status` | Show progress |
| `--resume` | Continue an interrupted run |
| `--step <name>` | Run `boot-layout`, `encrypt` or `omarchy` again |
| `--fonts`, `--autologin` | Run the named setup step again |
| `--abort` | Stop setup without undoing changes |
| `--allow-omarchy3` | Allow an explicitly selected Omarchy 3 ref |
| `--keep-root-password` | Keep the image's root password instead of locking it |

For manual installation, disk layout and encryption, see
[the Btrfs guide](docs/btrfs.md). For an existing Omarchy 3 install, use
[the Quattro upgrade guide](docs/upgrade-to-quattro.md).
`quattro` is the Omarchy 4 branch; `main` still contains Omarchy 3.

## Use it

- `Super + Space` opens the Omarchy menu. `Super + Alt + Space` opens apps only.
- `omarchy` is the command-line entry point.
- Use `omarchy update` for updates, migrations and restart checks. Read
  [the update guide](docs/update-process.md) before using pacman directly.
- Find themes under **Style > Theme** or press `Super + Ctrl + Shift + Space`.

The [manual](manual/01-welcome-to-omarchy.md) covers daily use. Installed
Omarchy files live under `/usr/share/omarchy`.

## Mac-specific limits

Screen recording uses `wf-recorder`, not `gpu-screen-recorder`. Video decode
uses the Apple AVD stack in players with a VA-API backend, such as mpv.
Chromium's Arch Linux ARM build cannot use that path.

Speakers remain muted until `speakersafetyd` runs. Setup installs the audio
stack. The [trackpad guide](docs/apple-silicon-trackpad.md) explains the
boot-time HID race and its initramfs fix.

## Troubleshooting

| Problem | What to do |
|---|---|
| SSH stops responding after install | Run `omarchy-setup-security-sshd` to enable SSH and add its firewall rule. The menu also has Setup > Security > SSH. |
| The machine reaches `grub rescue>` | Check [the boot layout](docs/btrfs.md). `/boot` must be on the EFI partition before root encryption. |
| An update breaks the desktop | Use `omarchy snapshot restore`. It offers snapshots, `@fresh` and `@factory`, and warns about missing kernel modules. |
| Slow or failing mirrors | Run `bash fix-mirrors.sh` from the checkout. |
| An old install is stuck on `libaquamarine.so` | Follow [the ARM package recovery guide](docs/arm-package-sources.md). |

## Remove Linux

There is no automatic uninstaller. Removal uses macOS to delete Linux
partitions and grow the macOS container. Follow the
[Asahi partitioning guide](https://asahilinux.org/docs/sw/partitioning-cheatsheet/)
exactly. Deleting the wrong partition can destroy macOS. Ask for help before
changing a partition you cannot identify.

## More documentation

- [Disk layout, snapshots and encryption](docs/btrfs.md)
- [ARM package sources](docs/arm-package-sources.md)
- [Updates](docs/update-process.md)
- [File layout](docs/file-layout.md)
- [Manual](manual/)

Thanks to Asahi Linux and Asahi Alarm for Linux on Apple Silicon, and to DHH
and the Omarchy contributors for the desktop.

You can support the upstream project at [Buy Me a Coffee](https://buymeacoffee.com/malik2015no).
See [LICENSE](LICENSE) for the license.
