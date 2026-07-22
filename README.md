# LiquidGlassNC

A Theos tweak that adds an edge-only "Liquid Glass" refraction ring to
the Notification Center / Cover Sheet on a jailbroken, pre-iOS 26
device: the middle of the panel stays clear (brightened, undistorted),
while a soft rim near the border warps the content behind it like a
liquid-filled pouch.

## Requirements
- A jailbroken iPhone, rootless (Dopamine 2.x+)
- Theos installed (or built via the GitHub Actions workflow discussed earlier)

## Building
export THEOS=/opt/theos
make package
make install THEOS_DEVICE_IP=<your device's IP>

## The one thing you MUST adjust: class names
See comments at the top of Tweak.xm — `CSCoverSheetView` /
`CSCoverSheetViewController` need to match your target iOS version's
real private class names (class-dump SpringBoard to confirm).

## Debugging
Check /var/mobile/Documents/LiquidGlassNC.log (via Filza or SSH) for
load/attach/warning messages if the effect doesn't appear.
