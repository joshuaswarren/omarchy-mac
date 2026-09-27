# The platform package's own system setup, last so it builds on every other
# leaf (omarchy-lifecycle-dispatch setup-system, see docs/lifecycle-dispatch.md).
# A no-op where the platform registers none. An image's first boot says so:
# there the network may be down, and a boot-file rebuild is asked for rather
# than built, since the deferred setup rebuilds once after its last step.
if [[ ${OMARCHY_IMAGE_DEFERRED_HARDWARE:-} == "1" ]]; then
  omarchy-lifecycle-dispatch setup-system image-first-boot
else
  omarchy-lifecycle-dispatch setup-system
fi
