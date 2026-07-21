# LiquidGlassNC

A Theos tweak that gives the Notification Center / Cover Sheet on a
jailbroken, pre-iOS 26 device a "Liquid Glass"-style look: heavier blur,
a soft ambient specular sweep, continuous-corner rounding, and a subtle
stretch/highlight reaction while you drag the shade down.

This is a visual approximation built with UIVisualEffectView +
CAGradientLayer + CALayer corner curves — not Apple's real Liquid
Glass renderer (which uses a private CoreImage/Metal refraction
pipeline). It looks close at a glance but won't refract background
content the way real Liquid Glass does.

## Requirements
- A jailbroken iPhone (rootful or rootless, e.g. Dopamine/palera1n + a
  Substrate-compatible tweak injector)
- Theos installed on macOS/Linux, or in-device with a Theos-on-device setup
- iOS SDK matching your target's firmware (14.0+ recommended)

## Building
export THEOS=/opt/theos   # wherever Theos is installed
make package
make install THEOS_DEVICE_IP=<your device's IP>

This packages a .deb in packages/ and installs + respawns
SpringBoard on your device automatically (see the after-install rule
in the Makefile).

## The one thing you MUST adjust: class names

SpringBoard's private notification-shade classes differ by iOS version
and jailbreak target:

| iOS version | Likely class to hook |
|---|---|
| 14–16 | CSCoverSheetViewController / CSCoverSheetView |
| 13 and earlier | SBDashBoardViewController / SBFluidNotificationContentView |
| 17+ | class names shift again; dump headers to confirm |

To find the right names for your firmware:
1. Grab a .dyld_shared_cache extract or the SpringBoard binary from
   your target firmware.
2. Run class-dump or Hopper/Ghidra against it, or use a tool like
   nm/otool -ov for a quick property/method scan.
3. Search for "CoverSheet", "DashBoard", "NotificationShade", or
   "Fluid" — Apple's internal naming for this component has used all
   of these across versions.
4. Update the two %hook targets and the _updateRevealPercent:
   selector name in Tweak.xm to match what you find (the reveal
   percent method name also varies — sometimes it's driven by a
   UIPanGestureRecognizer action instead of a dedicated method).

## Tuning the look
In Tweak.xm:
- UIBlurEffectStyleSystemUltraThinMaterial → swap for
  UIBlurEffectStyleSystemThinMaterial etc. for a heavier/lighter glass
- cornerRadius (44.0) → match your device's shade corner radius
- The gradient locations/colors in animateSpecularSweep control
  how strong and how fast the ambient highlight sweep looks
- updateForPullProgress: is where you can add more reactive behavior
  (e.g. scale, blur radius change) tied to how far the user has pulled
  the shade down

## Notes
- This tweak only patches visuals; it doesn't touch notification
  handling, so it should be safe to combine with other NC tweaks,
  though visual conflicts (e.g. another tweak also adding a background
  view) are possible.
- Test on a spare/backup-able device first, as with any SpringBoard
  tweak — a bad hook can cause SpringBoard respring loops.
