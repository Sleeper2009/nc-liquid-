// LiquidGlassNC — recreates an iOS 26 style "Liquid Glass" look for the
// pre-26 Notification Center / Cover Sheet on jailbroken devices.
//
// IMPORTANT: SpringBoard's private class names for the notification shade
// change between iOS versions (e.g. SBDashBoardViewController,
// CSCoverSheetViewController, CSCoverSheetView on 14–17). You will likely
// need to adjust the %hook target class names below to match the iOS
// version you're building for. Use a class-dump / header dump of the
// installed SpringBoard to confirm the right class + the view that hosts
// the shade's background.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

// ---------------------------------------------------------------------
// Tiny file logger.
//
// Writes timestamped lines to /var/mobile/Documents/LiquidGlassNC.log
// so you can check what happened even without a live syslog session.
// This path lives outside the rootless prefix (/var/jb) so it's
// reachable the same way on both rootful and rootless jailbreaks, and
// is easy to grab with Filza or `scp`.
//
// View it with: tail -f /var/mobile/Documents/LiquidGlassNC.log
// (over SSH), or open it in Filza / a text editor app.
// ---------------------------------------------------------------------
static NSString * const kLGLogPath = @"/var/mobile/Documents/LiquidGlassNC.log";

static void LGLog(NSString *format, ...) {
	va_list args;
	va_start(args, format);
	NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
	va_end(args);

	static NSDateFormatter *formatter;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		formatter = [[NSDateFormatter alloc] init];
		formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	});
	NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [formatter stringFromDate:[NSDate date]], msg];
	NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

	@synchronized (kLGLogPath) {
		if (![[NSFileManager defaultManager] fileExistsAtPath:kLGLogPath]) {
			[[NSFileManager defaultManager] createFileAtPath:kLGLogPath contents:nil attributes:nil];
		}
		NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kLGLogPath];
		if (fh) {
			[fh seekToEndOfFile];
			[fh writeData:data];
			[fh closeFile];
		}
	}
}

// ---------------------------------------------------------------------
// Minimal stub interfaces for SpringBoard's private classes.
//
// We don't have Apple's real private headers for these, so the compiler
// only knows about them as opaque forward-declared types unless we tell
// it what they inherit from. Declaring them here as plain UIView /
// UIViewController subclasses is enough for %hook and %orig to work
// correctly — we're not redefining Apple's real class, just describing
// its public shape (superclass) so Logos can generate valid code
// against it.
//
// Adjust the superclass/name here to match whatever class you found
// via class-dump for your target iOS version.
// ---------------------------------------------------------------------
@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
@end

// ---------------------------------------------------------------------
// Helper: builds the "glass" layer stack — blur, vibrancy tint,
// a moving specular highlight, and a continuous-corner mask.
// ---------------------------------------------------------------------
@interface LGGlassView : UIVisualEffectView
@property (nonatomic, strong) CAGradientLayer *specularLayer;
@end

@implementation LGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
	UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterial];
	self = [super initWithEffect:blur];
	if (self) {
		self.frame = frame;
		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.cornerRadius = 44.0;
		self.clipsToBounds = YES;
		self.layer.masksToBounds = YES;

		UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
		tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
		tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self.contentView addSubview:tint];

		CAGradientLayer *spec = [CAGradientLayer layer];
		spec.frame = self.bounds;
		spec.colors = @[
			(id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor,
			(id)[UIColor colorWithWhite:1.0 alpha:0.22].CGColor,
			(id)[UIColor colorWithWhite:1.0 alpha:0.0].CGColor
		];
		spec.locations = @[@0.35, @0.5, @0.65];
		spec.startPoint = CGPointMake(0.0, 0.0);
		spec.endPoint = CGPointMake(1.0, 1.0);
		[self.contentView.layer addSublayer:spec];
		self.specularLayer = spec;

		[self animateSpecularSweep];
	}
	return self;
}

- (void)animateSpecularSweep {
	CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"locations"];
	anim.fromValue = @[@-0.2, @-0.05, @0.1];
	anim.toValue = @[@0.9, @1.05, @1.2];
	anim.duration = 6.0;
	anim.autoreverses = YES;
	anim.repeatCount = HUGE_VALF;
	anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
	[self.specularLayer addAnimation:anim forKey:@"sweep"];
}

- (void)updateForPullProgress:(CGFloat)progress {
	progress = MAX(0.0, MIN(1.0, progress));
	self.layer.cornerRadius = 44.0 + (progress * 10.0);
	self.specularLayer.opacity = 0.6 + (progress * 0.4);
}

@end

// ---------------------------------------------------------------------
// Hook: inject the glass view behind the notification shade's content,
// and drive updateForPullProgress: from the shade's own pan gesture.
//
// We use an associated object (via objc/runtime.h) instead of a Logos
// %property here. %property needs to generate a real property on the
// hooked class, which runs into trouble when we only have a stub
// @interface (no real private headers) — the associated object
// approach sidesteps that entirely and always compiles.
//
// Replace `CSCoverSheetView` below with the actual class name you find
// via class-dump for your target iOS version.
// ---------------------------------------------------------------------
static char kLGGlassViewKey;

%hook CSCoverSheetView

- (void)didMoveToWindow {
	%orig;
	LGGlassView *existing = objc_getAssociatedObject(self, &kLGGlassViewKey);
	if (self.window && !existing) {
		LGGlassView *glass = [[LGGlassView alloc] initWithFrame:self.bounds];
		glass.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		[self insertSubview:glass atIndex:0];
		objc_setAssociatedObject(self, &kLGGlassViewKey, glass, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
		LGLog(@"[CSCoverSheetView] glass view attached, frame=%@", NSStringFromCGRect(self.bounds));
	}
}

- (void)layoutSubviews {
	%orig;
	LGGlassView *glass = objc_getAssociatedObject(self, &kLGGlassViewKey);
	glass.frame = self.bounds;
}

%end

// Drive the stretch effect from the shade's pan gesture recognizer.
// SBDashBoardViewController (or its 17+ equivalent) typically owns the
// gesture; hook wherever the "percent revealed" value is computed.
%hook CSCoverSheetViewController

- (void)_updateRevealPercent:(CGFloat)percent {
	%orig;
	static BOOL warnedMissingSubview = NO;
	static BOOL warnedMissingGlass = NO;

	UIView *root = [self valueForKey:@"view"];
	BOOL foundAny = NO;
	for (UIView *sub in root.subviews) {
		if ([sub isKindOfClass:%c(CSCoverSheetView)]) {
			foundAny = YES;
			LGGlassView *glass = objc_getAssociatedObject(sub, &kLGGlassViewKey);
			if (!glass) {
				if (!warnedMissingGlass) {
					LGLog(@"[CSCoverSheetViewController] WARNING: found CSCoverSheetView but no glass view attached yet");
					warnedMissingGlass = YES;
				}
				continue;
			}
			[glass updateForPullProgress:percent];
		}
	}
	if (!foundAny && !warnedMissingSubview) {
		LGLog(@"[CSCoverSheetViewController] WARNING: no CSCoverSheetView subview found — check class names for this iOS version");
		warnedMissingSubview = YES;
	}
}

%end

%ctor {
	LGLog(@"LiquidGlassNC loaded into %@", [[NSBundle mainBundle] bundleIdentifier]);
	%init;
}
