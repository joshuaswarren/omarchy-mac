# Follow-up: SoC-gated `kmod-ane` after the MLX menu PR

This is a design note for work that must **not** land in the pending
`omacom/omarchy-mac` MLX platform PR (local `add-mlx-omarchy` /
`b18809aa`). That PR keeps one Install > AI row labeled
`MLX (Apple GPU)` and installs user-space mlx-omarchy only. ANE kernel
enablement is platform hardware, not a second AI app.

Canonical packaging plan:
`ane-linux-experiments` `docs/omarchy-ane-out-of-box-plan.md` (`21384d5`).
mlx-omarchy reports ANE/Core ML installed state through `mlx-omarchy-info`
and runs ANE smoke only when `/dev/accel/accel0` exists. It does not
install `kmod-ane`.

## Current installer receipt (read-only on this branch's parent)

Parent commit: `b18809aafc6da6ac30747ee6417b0d8b7ba6b92b`
(`Add MLX (Apple GPU) to the AI install menu`).

| Path | SHA-256 | Bytes |
| --- | --- | --- |
| `bin/omarchy-install-ai-mlx` | `6badc681b7470780c1bafad3d3d7db90bf5b016eddf6e2d0b878f2c2d1321f57` | 744 |
| `default/omarchy/omarchy-menu.jsonc` | `8c369a815514a7bff0b05224b5cd31a13df01bcfa2e630c7d62afa019dd70e41` | 51900 |
| `install/omarchy-base.packages` | `c0cd77ec929818d9bbcad21a7119886766e755ce3287d82569922d3049b70a82` | 1690 |

Observed state:

- Menu label is `MLX (Apple GPU)`. Installed-state key is
  `omarchy-cmd-present mlx-omarchy-demo`. There is no
  `Install > AI > Core ML` row.
- `bin/omarchy-install-ai-mlx` curls
  `joshuaswarren/mlx-omarchy` `install.sh` from `main`. It does not
  inspect FDT, DTB packages, or `/dev/accel/accel0`.
- `bin/omarchy-remove-ai-mlx` does not exist. There is no
  `remove.ai.mlx` menu entry.
- `install/omarchy-base.packages` has no `kmod-ane` and no DKMS ANE
  package. That is required: ANE is SoC-gated, not a base dependency.

Do not rename the menu until the public Parakeet receipt is green.

## Follow-up wiring (after the MLX PR merges)

Keep `omarchy-base.packages` free of `kmod-ane`. Add a hardware leaf
next to `install/hardware/apple/video-decode.sh`:

```text
install/hardware/apple/ane.sh
```

Gate, after the kernel package and its DTBs are present, before any
module load:

```text
if machine is not Apple Silicon:
    do not install kmod-ane
elif live FDT has compatible "apple,t*-ane":
    install kmod-ane for the running packaged kernel
elif this board's packaged DTB has compatible "apple,t*-ane":
    install kmod-ane; update-m1n1 will make it live on the next boot
else:
    do not install kmod-ane
```

Implementation notes:

- Inspect the **board-matched** packaged DTB under
  `/usr/lib/modules/<kernel>/dtbs/`, never an arbitrary other-board DTB.
- Treat an absent or unreadable FDT/DTB as false.
- An absent or unreadable FDT must not fail the rest of Apple setup.
- Do not add a GRUB `devicetree` command or a whole-tree DTB override.
- Do not `insmod` from the AI installer. First boot after `update-m1n1`
  binds the platform device. mlx-omarchy smoke owns `/dev/accel/accel0`.
- `kmod-ane` is kernel-ABI coupled, not DKMS. It owns `ane.ko`,
  modprobe policy, and one udev rule for the accelerator node.
- T6000/T6001 stay GPU-only until the ANE binding is proved.

Reuse the Apple-identity check already used by video-decode and audio:

```bash
compatible="${OMARCHY_APPLE_COMPATIBLE:-/proc/device-tree/compatible}"
[[ $(uname -m) == "aarch64" ]] || return 0
[[ -f $compatible ]] && grep -Faiq 'apple,' "$compatible" || return 0
```

Then look for `apple,t*-ane` (NUL-separated FDT tokens) before calling
`omarchy-pkg-add kmod-ane`. Missing packages on an unsupported board are
a skip, not a broken install.

## MLX menu follow-up (same PR family, still one AI row)

Once mlx-omarchy `install.sh` always ships `mlx-omarchy-info`:

```text
disabled: omarchy-cmd-present mlx-omarchy-info
```

Add `bin/omarchy-remove-ai-mlx` that runs
`bash install.sh --uninstall` (or the pinned commit equivalent) and a
`remove.ai.mlx` menu row keyed on the same command. Do not add
`mlx-omarchy-coreml` as a second Install > AI product.

## Host fixtures before any machine mutation

Exercise the gate with five trees, no live module load:

1. x86 — skip
2. Apple, no ANE node — skip
3. Packaged T8103 ANE DTB — install `kmod-ane`, do not load it
4. Live FDT already has `apple,t8103-ane` — install `kmod-ane`
5. Missing FDT — skip

Record kernel package version, `kmod-ane` version, board DTB,
detected compatible, gate result, and whether mlx-omarchy ran GPU-only
or ANE smoke.
