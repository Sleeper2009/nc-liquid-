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
// Tiny file logger. See /var/mobile/Documents/LiquidGlassNC.log
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
// Adjust the superclass/name here to match whatever class you find via
// class-dump for your target iOS version.
// ---------------------------------------------------------------------
@interface CSCoverSheetView : UIView
@end

@interface CSCoverSheetViewController : UIViewController
@end

// ---------------------------------------------------------------------
// LGGlassView
//
// Architecture (per your requirements):
//  - The background capture + CIGlassDistortion pass is EXPENSIVE, so
//    it only runs: once on attach, once on real size changes, and once
//    every ~1s on a timer (to track the clock etc). It never runs on
//    every pan-gesture tick.
//  - Two pre-rendered layers are kept around:
//      baseLayer  — brightened, UNDISTORTED capture (the "clear middle"
//                   of the glass)
//      edgeLayer  — brightened, DISTORTED capture (only visible near
//                   the border, via a soft ring-shaped mask)
//  - During a pull gesture, updateForPullProgress: only touches cheap
//    CALayer properties (cornerRadius, an overlay's opacity) — pure
//    GPU compositing, so it can run at native display refresh rate.
//  - Liquid Glass lifts the content behind it rather than darkening it,
//    so we boost brightness/saturation slightly instead of tinting
//    with a translucent dark/white overlay.
// ---------------------------------------------------------------------
@interface LGGlassView : UIView
@property (nonatomic, strong) CALayer *baseLayer;
@property (nonatomic, strong) CALayer *edgeLayer;
@property (nonatomic, strong) CALayer *highlightLayer;
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, assign) NSTimeInterval lastRefreshTime;
@property (nonatomic, assign) CGSize lastMaskSize;
@property (nonatomic, assign) CGFloat baseCornerRadius;
@property (nonatomic, assign) CGFloat edgeWidth;
@end

@implementation LGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
	self = [super initWithFrame:frame];
	if (self) {
		self.baseCornerRadius = 30.0; // was 45 — reduced per request
		self.edgeWidth = 28.0;        // width of the "liquid pouch" rim, ~25-30pt
		self.lastMaskSize = CGSizeZero;
		self.lastRefreshTime = 0;

		self.layer.cornerCurve = kCACornerCurveContinuous;
		self.layer.cornerRadius = self.baseCornerRadius;
		self.clipsToBounds = YES;
		self.layer.masksToBounds = YES;
		self.userInteractionEnabled = NO;
		self.backgroundColor = [UIColor clearColor];

		self.baseLayer = [CALayer layer];
		self.baseLayer.frame = self.bounds;
		self.baseLayer.contentsGravity = kCAGravityResizeAspectFill;
		[self.layer addSublayer:self.baseLayer];

		self.edgeLayer = [CALayer layer];
		self.edgeLayer.frame = self.bounds;
		self.edgeLayer.contentsGravity = kCAGravityResizeAspectFill;
		[self.layer addSublayer:self.edgeLayer];

		// Subtle brightening overlay near the rim, strengthened as the
		// user pulls further — "the covered area gets brighter, not
		// darker."
		self.highlightLayer = [CALayer layer];
		self.highlightLayer.frame = self.bounds;
		self.highlightLayer.backgroundColor = [UIColor whiteColor].CGColor;
		self.highlightLayer.opacity = 0.05;
		[self.layer addSublayer:self.highlightLayer];
	}
	return self;
}

- (void)layoutSubviews {
	[super layoutSubviews];
	self.baseLayer.frame = self.bounds;
	self.edgeLayer.frame = self.bounds;
	self.highlightLayer.frame = self.bounds;
}

- (void)didMoveToWindow {
	[super didMoveToWindow];
	if (self.window) {
		[self startRefreshTimer];
		[self refreshGlassBackground];
	} else {
		[self stopRefreshTimer];
	}
}

- (void)startRefreshTimer {
	[self stopRefreshTimer];
	__weak typeof(self) weakSelf = self;
	self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
		[weakSelf refreshGlassBackground];
	}];
}

- (void)stopRefreshTimer {
	[self.refreshTimer invalidate];
	self.refreshTimer = nil;
}

// Cheap, called on every pan-gesture tick — no image work here.
- (void)updateForPullProgress:(CGFloat)progress {
	progress = MAX(0.0, MIN(1.0, progress));
	self.layer.cornerRadius = self.baseCornerRadius + (progress * 6.0);
	self.highlightLayer.opacity = 0.05 + (progress * 0.22);
}

+ (CIContext *)sharedContext {
	static CIContext *ctx;
	static dispatch_once_t token;
	dispatch_once(&token, ^{
		ctx = [CIContext contextWithOptions:@{ kCIContextUseSoftwareRenderer: @NO }];
	});
	return ctx;
}

// Soft, cloud-like displacement map for CIGlassDistortion.
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

// Builds a soft "picture frame" ring mask: opaque near the border,
// fading to transparent by `edgeWidth` into the panel. Used so the
// distorted edgeLayer only shows through near the rim while the middle
// reveals the clear (undistorted) baseLayer underneath.
+ (UIImage *)frameMaskImageForSize:(CGSize)size cornerRadius:(CGFloat)cornerRadius edgeWidth:(CGFloat)edgeWidth scale:(CGFloat)scale {
	if (size.width < 1 || size.height < 1) return nil;

	UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
	format.opaque = NO;
	format.scale = scale;
	UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size format:format];

	UIImage *hardRing = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull rendererContext) {
		CGContextRef ctx = rendererContext.CGContext;
		UIBezierPath *outer = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:cornerRadius];
		[[UIColor whiteColor] setFill];
		[outer fill];

		CGRect innerRect = CGRectInset(CGRectMake(0, 0, size.width, size.height), edgeWidth, edgeWidth);
		if (innerRect.size.width > 0 && innerRect.size.height > 0) {
			CGFloat innerRadius = MAX(cornerRadius - edgeWidth, 0);
			UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:innerRect cornerRadius:innerRadius];
			CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);
			[[UIColor blackColor] setFill];
			[inner fill];
			CGContextSetBlendMode(ctx, kCGBlendModeNormal);
		}
	}];

	// Soften the hard ring edge so the transition into the clear middle
	// isn't a visible seam.
	CIImage *ciRing = [CIImage imageWithCGImage:hardRing.CGImage];
	CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
	[blur setValue:ciRing forKey:kCIInputImageKey];
	[blur setValue:@(MAX(edgeWidth * 0.3, 4.0)) forKey:kCIInputRadiusKey];
	CIImage *blurred = blur.outputImage;
	if (!blurred) return hardRing;

	CGRect extent = CGRectMake(0, 0, size.width * scale, size.height * scale);
	CGImageRef cg = [[LGGlassView sharedContext] createCGImage:blurred fromRect:extent];
	if (!cg) return hardRing;
	UIImage *softMask = [UIImage imageWithCGImage:cg scale:scale orientation:UIImageOrientationUp];
	CGImageRelease(cg);
	return softMask;
}

// The expensive pass: capture what's behind this view, brighten it,
// produce both an undistorted and a glass-distorted version, and store
// them as static layer contents for cheap reuse every frame.
- (void)refreshGlassBackground {
	NSTimeInterval now = CACurrentMediaTime();
	if (now - self.lastRefreshTime < 0.1) return; // debounce duplicate calls
	self.lastRefreshTime = now;

	UIView *source = self.superview;
	if (!source || self.bounds.size.width < 1 || self.bounds.size.height < 1) {
		LGLog(@"[LGGlassView] refresh skipped — no superview or zero size");
		return;
	}

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

	if (!snapshot.CGImage) {
		LGLog(@"[LGGlassView] refresh failed — snapshot had no CGImage (likely capturing the wrong window)");
		return;
	}

	CGRect cropRect = CGRectMake(
		frameInSource.origin.x * scale,
		(source.bounds.size.height - frameInSource.origin.y - frameInSource.size.height) * scale,
		frameInSource.size.width * scale,
		frameInSource.size.height * scale
	);

	CIImage *full = [CIImage imageWithCGImage:snapshot.CGImage];
	CIImage *cropped = [full imageByCroppingToRect:cropRect];

	// Liquid Glass LIFTS what's behind it — brighten, don't darken.
	CIFilter *brighten = [CIFilter filterWithName:@"CIColorControls"];
	[brighten setValue:cropped forKey:kCIInputImageKey];
	[brighten setValue:@(0.08) forKey:kCIInputBrightnessKey];
	[brighten setValue:@(1.03) forKey:kCIInputSaturationKey];
	[brighten setValue:@(1.0) forKey:kCIInputContrastKey];
	CIImage *brightened = brighten.outputImage ?: cropped;

	// Base layer: clear middle — brightened, NOT distorted.
	CGImageRef baseCG = [[LGGlassView sharedContext] createCGImage:brightened fromRect:cropRect];
	if (baseCG) {
		self.baseLayer.contents = (__bridge id)baseCG;
		self.baseLayer.contentsScale = scale;
		CGImageRelease(baseCG);
	}

	// Edge layer: same image, glass-distorted — only shown near the rim.
	CIImage *edgeOutput = brightened;
	CIImage *bump = [LGGlassView bumpTextureForSize:cropRect.size];
	if (bump) {
		CIFilter *distortion = [CIFilter filterWithName:@"CIGlassDistortion"];
		if (distortion) {
			[distortion setValue:brightened forKey:kCIInputImageKey];
			[distortion setValue:bump forKey:@"inputTexture"];
			[distortion setValue:[CIVector vectorWithX:CGRectGetMidX(cropRect) Y:CGRectGetMidY(cropRect)] forKey:kCIInputCenterKey];
			[distortion setValue:@(60.0) forKey:kCIInputScaleKey];
			edgeOutput = distortion.outputImage ?: brightened;
		} else {
			LGLog(@"[LGGlassView] CIGlassDistortion unavailable on this iOS version — edge will look clear, not warped");
		}
	}
	CGImageRef edgeCG = [[LGGlassView sharedContext] createCGImage:edgeOutput fromRect:cropRect];
	if (edgeCG) {
		self.edgeLayer.contents = (__bridge id)edgeCG;
		self.edgeLayer.contentsScale = scale;
		CGImageRelease(edgeCG);
	}

	// Rebuild the rim mask only when the size actually changed.
	if (!CGSizeEqualToSize(self.lastMaskSize, self.bounds.size)) {
		UIImage *mask = [LGGlassView frameMaskImageForSize:self.bounds.size
		                                        cornerRadius:self.baseCornerRadius
		                                           edgeWidth:self.edgeWidth
		                                               scale:scale];
		if (mask) {
			CALayer *edgeMask = [CALayer layer];
			edgeMask.frame = self.bounds;
			edgeMask.contents = (__bridge id)mask.CGImage;
			self.edgeLayer.mask = edgeMask;

			CALayer *highlightMask = [CALayer layer];
			highlightMask.frame = self.bounds;
			highlightMask.contents = (__bridge id)mask.CGImage;
			self.highlightLayer.mask = highlightMask;

			self.lastMaskSize = self.bounds.size;
		} else {
			LGLog(@"[LGGlassView] failed to build rim mask");
		}
	}
}

@end

// ---------------------------------------------------------------------
// Hook: inject the glass view behind the notification shade's content,
// and drive updateForPullProgress: from the shade's own pan gesture.
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
	CGSize previousSize = glass.bounds.size;
	glass.frame = self.bounds;
	if (glass && !CGSizeEqualToSize(previousSize, glass.bounds.size)) {
		[glass refreshGlassBackground];
	}
}

%end

// Drive the rim highlight + corner-radius reaction from the shade's own
// pan gesture. This is cheap (see updateForPullProgress: above), so it's
// safe to call on every tick.
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
