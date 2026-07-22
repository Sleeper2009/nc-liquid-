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
#import <CoreImage/CoreImage.h>
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
// LGGlassView — real refraction, not just blur.
//
// Technique: same two-stage idea used by open-source glass libraries
// like BarredEwe/LiquidGlass and DnV1eX/LiquidGlassKit (capture what's
// behind the view, then distort/refract that captured image) — but
// reimplemented with CoreImage's built-in CIGlassDistortion filter
// instead of a custom Metal shader. Those libraries compile .metal
// shaders via Xcode's Metal compiler, which isn't available on a Linux
// GitHub Actions runner, so this version trades a little visual
// fidelity for something that actually builds in this CI setup.
//
// Stages:
//   1. Snapshot whatever is behind this view (drawViewHierarchyInRect:)
//   2. Generate a soft, cloud-like displacement/bump texture
//   3. Run CIGlassDistortion(background, bump) to warp the snapshot
//   4. Composite the result as this view's layer contents, then add a
//      tint + ambient specular sweep on top (same as before) for the
//      "polish" pass.
//
// The background is captured once per meaningful layout change rather
// than every frame — full CoreImage passes are too expensive to redo
// on every pan-gesture tick, and the shade's background (wallpaper /
// lock screen) is static anyway, so a static refracted snapshot reads
// as "real" glass without a live per-frame cost.
// ---------------------------------------------------------------------
@interface LGGlassView : UIView
@property (nonatomic, strong) CAGradientLayer *specularLayer;
@property (nonatomic, strong) UIView *tintView;
@end

@implementation LGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.cornerRadius = 44.0;
		self.clipsToBounds = YES;
		self.layer.masksToBounds = YES;
		self.userInteractionEnabled = NO;
		// Fallback color shown before the first snapshot resolves.
		self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.6];

		UIView *tint = [[UIView alloc] initWithFrame:self.bounds];
		tint.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.04];
		tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
		tint.userInteractionEnabled = NO;
		[self addSubview:tint];
		self.tintView = tint;

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
		[self.layer addSublayer:spec];
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

// Shared CoreImage context — expensive to create, so build it once.
+ (CIContext *)sharedContext {
	static CIContext *ctx;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
	});
	return ctx;
}

// A soft, cloud-like grayscale texture used as the displacement map
// for CIGlassDistortion. Random noise, heavily blurred, gives smooth
// "waves" in the refraction rather than sharp/glittery artifacts.
+ (CIImage *)bumpTextureForSize:(CGSize)size {
	CIFilter *random = [CIFilter filterWithName:@"CIRandomGenerator"];
	CIImage *noise = random.outputImage;
	if (!noise) return nil;

	CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
	[blur setValue:noise forKey:kCIInputImageKey];
	[blur setValue:@(28.0) forKey:kCIInputRadiusKey];
	CIImage *blurred = blur.outputImage;
	if (!blurred) return nil;

	return [blurred imageByCroppingToRect:CGRectMake(0, 0, size.width, size.height)];
}

// Captures whatever is behind this view, runs it through
// CIGlassDistortion, and sets the result as this layer's contents.
- (void)refreshGlassBackground {
	UIView *source = self.superview;
	if (!source || self.bounds.size.width < 1 || self.bounds.size.height < 1) return;

	CGRect frameInSource = self.frame;
	BOOL wasHidden = self.hidden;
	self.hidden = YES;

	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
	format.opaque = NO;
	CGFloat scale = format.scale > 0 ? format.scale : [UIScreen mainScreen].scale;
	format.scale = scale;

	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:source.bounds format:format];
	UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
		[source drawViewHierarchyInRect:source.bounds afterScreenUpdates:NO];
	}];
	self.hidden = wasHidden;

	if (!snapshot.CGImage) return;

	// UIKit's origin is top-left; CoreImage's is bottom-left, so flip
	// the crop rect's Y before cropping the captured CIImage.
	CGRect cropRect = CGRectMake(
		frameInSource.origin.x * scale,
		(source.bounds.size.height - frameInSource.origin.y - frameInSource.size.height) * scale,
		frameInSource.size.width * scale,
		frameInSource.size.height * scale
	);

	CIImage *full = [CIImage imageWithCGImage:snapshot.CGImage];
	CIImage *cropped = [full imageByCroppingToRect:cropRect];
	CIImage *bump = [LGGlassView bumpTextureForSize:cropRect.size];
	if (!bump) return;

	CIFilter *distortion = [CIFilter filterWithName:@"CIGlassDistortion"];
	if (!distortion) {
		// CIGlassDistortion unavailable on this iOS version — fall back
		// to a plain (undistorted) blurred snapshot so the tweak still
		// shows *something* rather than a blank layer.
		CIFilter *fallbackBlur = [CIFilter filterWithName:@"CIGaussianBlur"];
		[fallbackBlur setValue:cropped forKey:kCIInputImageKey];
		[fallbackBlur setValue:@(18.0) forKey:kCIInputRadiusKey];
		[self renderCIImage:[fallbackBlur.outputImage imageByCroppingToRect:cropRect] rect:cropRect scale:scale];
		return;
	}

	[distortion setValue:cropped forKey:kCIInputImageKey];
	[distortion setValue:bump forKey:@"inputTexture"];
	[distortion setValue:[CIVector vectorWithX:CGRectGetMidX(cropRect) Y:CGRectGetMidY(cropRect)] forKey:kCIInputCenterKey];
	[distortion setValue:@(55.0) forKey:kCIInputScaleKey]; // distortion strength — raise for a "wavier" look

	[self renderCIImage:distortion.outputImage rect:cropRect scale:scale];
}

- (void)renderCIImage:(CIImage *)image rect:(CGRect)rect scale:(CGFloat)scale {
	if (!image) return;
	CGImageRef output = [[LGGlassView sharedContext] createCGImage:image fromRect:rect];
	if (!output) return;
	self.layer.contents = (__bridge id)output;
	self.layer.contentsScale = scale;
	CGImageRelease(output);
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

		// Defer to the next runloop tick so the view hierarchy has
		// settled before we snapshot + distort what's behind us.
		dispatch_async(dispatch_get_main_queue(), ^{
			[glass refreshGlassBackground];
		});
	}
}

- (void)layoutSubviews {
	%orig;
	LGGlassView *glass = objc_getAssociatedObject(self, &kLGGlassViewKey);
	CGSize previousSize = glass.bounds.size;
	glass.frame = self.bounds;

	// Re-run the (expensive) CoreImage distortion only when the size
	// actually changed — not on every position/alpha update during a
	// pull gesture.
	if (glass && !CGSizeEqualToSize(previousSize, glass.bounds.size)) {
		dispatch_async(dispatch_get_main_queue(), ^{
			[glass refreshGlassBackground];
		});
	}
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
